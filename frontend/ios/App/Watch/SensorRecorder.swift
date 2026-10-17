import CoreMotion
import Foundation
import WatchKit

// Training data for set detection (ml/README.md): the watch's motion at 100 Hz for a whole
// workout, plus what happened when — set starts and ends as you marked them, heart rate, the
// session. Only while recording is switched on (WatchModel.recordingOn).
//
// Two files per workout, sent to the phone when it ends (WatchModel → WatchLink):
//   <name>.motion  rows of 14 little-endian float32, no header:
//                  t, userAccel x y z (g), gravity x y z (g), rotationRate x y z (rad/s),
//                  attitude quaternion x y z w — t in seconds since the recording started
//   <name>.json    the manifest: columns, start time, labels (`events`), heart rate, session
final class SensorRecorder {
    static let columns = ["t", "ax", "ay", "az", "gx", "gy", "gz", "rx", "ry", "rz", "qx", "qy", "qz", "qw"]
    static let rate = 100.0

    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    // Touched only on `queue`.
    private var buffer = Data()
    private var handle: FileHandle?
    private var rows = 0

    // Touched only on the main thread.
    private var events: [[String: Any]] = []
    private var heartRate: [[Double]] = []
    private var bootStart: TimeInterval = 0
    private var wallStart = Date()
    private var session: [String: Any] = [:]
    private var name = ""
    private(set) var recording = false

    static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var available: Bool { motion.isDeviceMotionAvailable || fakeMotion }

    #if DEBUG
    // The simulator has no motion sensors: OG_FAKE_MOTION=1 writes a synthetic 100 Hz signal (a
    // 0.5 Hz "rep" wave) so the files, labels and transfer can be tested end to end.
    private let fakeMotion = ProcessInfo.processInfo.environment["OG_FAKE_MOTION"] != nil
    private var fakeTimer: DispatchSourceTimer?
    #else
    private let fakeMotion = false
    #endif

    func begin(session: [String: Any]) {
        guard !recording, available else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        name = "opengym-\(stamp.string(from: Date()))"
        let url = Self.directory.appendingPathComponent("\(name).motion")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }

        self.session = session
        events = []
        heartRate = []
        wallStart = Date()
        bootStart = ProcessInfo.processInfo.systemUptime
        recording = true
        let start = bootStart
        queue.addOperation { [weak self] in
            self?.handle = handle
            self?.buffer = Data()
            self?.rows = 0
        }

        #if DEBUG
        if fakeMotion && !motion.isDeviceMotionAvailable {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now(), repeating: 1 / Self.rate)
            timer.setEventHandler { [weak self] in
                let t = ProcessInfo.processInfo.systemUptime - start
                let w = Float(sin(t * .pi))
                let row: [Float] = [Float(t), w * 0.4, 0, w * 0.1, 0, -1, 0, w * 2, 0, 0, 0, 0, 0, 1]
                self?.queue.addOperation { [weak self] in
                    guard let self else { return }
                    row.withUnsafeBufferPointer { self.buffer.append(Data(buffer: $0)) }
                    self.rows += 1
                    if self.buffer.count >= 56 * 500 { self.flush() }
                }
            }
            fakeTimer = timer
            timer.resume()
            return
        }
        #endif
        motion.deviceMotionUpdateInterval = 1 / Self.rate
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            let a = m.userAcceleration, g = m.gravity, r = m.rotationRate, q = m.attitude.quaternion
            let row: [Float] = [
                Float(m.timestamp - start),
                Float(a.x), Float(a.y), Float(a.z),
                Float(g.x), Float(g.y), Float(g.z),
                Float(r.x), Float(r.y), Float(r.z),
                Float(q.x), Float(q.y), Float(q.z), Float(q.w),
            ]
            row.withUnsafeBufferPointer { self.buffer.append(Data(buffer: $0)) }
            self.rows += 1
            // About five seconds at a time.
            if self.buffer.count >= 56 * 500 { self.flush() }
        }
    }

    // On `queue` only.
    private func flush() {
        guard !buffer.isEmpty, let handle else { return }
        try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime - bootStart }

    // A label: setStart, setEnd, restSkip, … `at` is the wall clock in epoch ms, the same value
    // the phone stores on the set (Workout.jsx onWatchTick), so a label joins its logged set.
    func mark(_ type: String, at date: Date = Date(), _ info: [String: Any] = [:]) {
        guard recording else { return }
        var event = info
        event["type"] = type
        event["t"] = date.timeIntervalSince(wallStart)
        event["at"] = (date.timeIntervalSince1970 * 1000).rounded()
        events.append(event)
    }

    func heartRate(_ bpm: Double) {
        guard recording, bpm > 0 else { return }
        heartRate.append([now, bpm])
    }

    // Stops, writes the manifest, and returns both files. `session` fills in what was not known
    // yet when recording began (a workout started on the wrist before the phone answered).
    func finish(session latest: [String: Any] = [:]) -> [URL] {
        guard recording else { return [] }
        for (key, value) in latest where (session[key] as? String ?? "").isEmpty { session[key] = value }
        recording = false
        motion.stopDeviceMotionUpdates()
        #if DEBUG
        fakeTimer?.cancel()
        fakeTimer = nil
        #endif
        var rows = 0
        queue.addOperation { [weak self] in
            guard let self else { return }
            self.flush()
            try? self.handle?.close()
            self.handle = nil
            rows = self.rows
        }
        queue.waitUntilAllOperationsAreFinished()

        let device = WKInterfaceDevice.current()
        let manifest: [String: Any] = [
            "format": "opengym-watch-motion",
            "version": 1,
            "rate": Self.rate,
            "columns": Self.columns,
            "dtype": "<f4",
            "rows": rows,
            "start": (wallStart.timeIntervalSince1970 * 1000).rounded(),
            "end": (Date().timeIntervalSince1970 * 1000).rounded(),
            "device": ["model": device.model, "system": "\(device.systemName) \(device.systemVersion)", "wrist": device.wristLocation == .left ? "left" : "right", "crown": device.crownOrientation == .left ? "left" : "right"],
            "session": session,
            "events": events,
            "heartRate": heartRate,
        ]
        let motionURL = Self.directory.appendingPathComponent("\(name).motion")
        let manifestURL = Self.directory.appendingPathComponent("\(name).json")
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: manifestURL)
        }
        return [motionURL, manifestURL]
    }
}
