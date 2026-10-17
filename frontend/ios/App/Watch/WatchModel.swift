import Combine
import Foundation
import WatchConnectivity
import WatchKit

// The watch's side of the link to the phone (the phone's is ios/App/App/WatchLink.swift).
//
// The phone is the source of truth: it sends a snapshot of the session whenever it changes, and
// the watch draws it. The wrist only asks (start, set done, skip, finish). But the phone is
// usually locked in a pocket with its page frozen, so a Done here must not wait for an answer: the
// watch starts the rest that set earned itself (snapshot.next.restAfter), taps the wrist when it
// is over, and counts the sets the phone has not caught up with yet. The phone's own rest, once its
// snapshot carries one, replaces the guess.
@MainActor
final class WatchModel: NSObject, ObservableObject {
    static let shared = WatchModel()

    @Published private(set) var snap: Snapshot?
    // A rest started on the wrist that the phone has not confirmed yet.
    @Published private(set) var localRest: Snapshot.Rest?
    // Sets ticked here since the last snapshot: the phone has them queued.
    @Published private(set) var unconfirmed = 0

    let workout = WorkoutManager()
    let recorder = SensorRecorder()
    // Recording training data (SensorRecorder): this watch's own switch, off until turned on.
    @Published var recordingOn: Bool = UserDefaults.standard.bool(forKey: "og.recording") {
        didSet {
            UserDefaults.standard.set(recordingOn, forKey: "og.recording")
            // Switched on mid-workout: from now on.
            if recordingOn, workout.running, !recorder.recording { beginRecording() }
        }
    }

    private func beginRecording() {
        recorder.begin(session: ["id": snap?.active?.id ?? "", "name": snap?.active?.name ?? "", "unit": snap?.unit ?? "kg"])
        objectWillChange.send()
    }
    // While recording, a set has a Start as well as a Done; this is when it was started.
    @Published private(set) var setStartedAt: Date?
    private var cancellables = Set<AnyCancellable>()
    // The last live session the phone described, for the recording's manifest once it is over.
    private var lastActive: Snapshot.Active?
    private var restEndTask: Task<Void, Never>?
    private var lastSnapAt = Date.distantPast
    // Finished here; the phone may still show it live until it wakes and asks to confirm.
    private var finishedId: String?

    // MARK: - What the views read

    var active: Snapshot.Active? { snap?.active.flatMap { $0.id == finishedId ? nil : $0 } }

    // The rest to show: the phone's if it has one, else the one started here.
    var rest: Snapshot.Rest? {
        let r = snap?.rest ?? localRest
        guard let r, r.paused || r.endDate > Date() else { return nil }
        return r
    }

    // MARK: - Link

    var recording: Bool { recorder.recording }

    func activate() {
        // The recorder follows the workout: on as it starts (when switched on), off and sent to
        // the phone as it ends. Heart rate goes along as the workout reads it.
        workout.$running.removeDuplicates().sink { [weak self] running in
            guard let self else { return }
            if running, self.recordingOn {
                self.beginRecording()
            } else if !running {
                self.setStartedAt = nil
                let session: [String: Any] = ["id": self.lastActive?.id ?? "", "name": self.lastActive?.name ?? "", "unit": self.snap?.unit ?? "kg"]
                self.sendRecording(self.recorder.finish(session: session))
            }
            self.objectWillChange.send()
        }.store(in: &cancellables)
        workout.$heartRate.sink { [weak self] bpm in self?.recorder.heartRate(bpm) }.store(in: &cancellables)

        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        #if DEBUG
        // Simulator runs driven by a script cannot answer the Health sheet (runDebugScript).
        if ProcessInfo.processInfo.environment["OG_NO_HEALTH"] != nil { return }
        #endif
        Task { await workout.requestAuthorization() }
    }

    #if DEBUG
    // Simulator testing without taps, like the phone's OG_EVAL:
    //   SIMCTL_CHILD_OG_WATCH="wait 4; today; wait 6; done; wait 3; skip" xcrun simctl launch <watch> <id>
    // Steps: wait <s> · today · start <routine id> · record [off] · begin (a set's Start) · done ·
    // skip · finish. Each logs what it saw.
    func runDebugScript() async {
        guard let script = ProcessInfo.processInfo.environment["OG_WATCH"] else { return }
        for step in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts.first {
            case "wait": try? await Task.sleep(for: .seconds(Double(parts.last ?? "1") ?? 1))
            case "today": if let ids = snap?.today?.ids { start(ids: ids) }
            case "start": start(ids: parts.count > 1 ? [parts[1]] : [])
            case "routine": if let r = snap?.routines.first { start(ids: [r.id]) }
            case "done": done()
            case "begin": startSet()
            case "skip": skipRest()
            case "finish": finish()
            case "record": recordingOn = parts.last != "off"
            default: break
            }
            let next = active?.next.map { "\($0.exercise) set \($0.set)/\($0.sets) rest \(Int($0.restAfter))s" } ?? "-"
            let restLeft = rest.map { Int($0.endDate.timeIntervalSinceNow) }
            print("OGWATCH \(step): rec=\(recorder.recording) active=\(active?.name ?? "-") next=\(next) rest=\(restLeft.map(String.init) ?? "-") unconfirmed=\(unconfirmed) running=\(workout.running) today=\(snap?.today?.name ?? "-")")
        }
    }
    #endif

    private func apply(_ new: Snapshot) {
        // The same snapshot again (the context redelivered as the link comes up) says nothing new,
        // and must not count the phone as having caught up with Done it has not seen.
        guard new != snap else { return }
        let wasActive = snap?.active?.id
        snap = new
        lastSnapAt = Date()
        if let active = new.active { lastActive = active }
        // The phone has caught up with every Done sent before this snapshot.
        unconfirmed = 0
        if new.rest != nil { localRest = nil }
        if let active = new.active, active.id != finishedId {
            if !workout.running { workout.start(at: min(Date(), active.startDate)) }
        } else if wasActive != nil || workout.running {
            // Finished or thrown away on the phone: the wrist's workout ends and is saved.
            localRest = nil
            workout.end()
        }
        scheduleRestEnd()
    }

    private func send(_ event: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var event = event
        if event["id"] == nil { event["id"] = UUID().uuidString }
        let payload: [String: Any] = ["event": event]
        if session.isReachable {
            // Falls back to the queue when the phone stops listening mid-send.
            session.sendMessage(payload, replyHandler: nil) { _ in session.transferUserInfo(payload) }
        } else {
            session.transferUserInfo(payload)
        }
    }

    // MARK: - Actions

    func start(ids: [String]) {
        send(["type": "start", "ids": ids, "at": Date().timeIntervalSince1970 * 1000])
        workout.start()
    }

    // What a label says about the set it marks.
    private func label(_ next: Snapshot.Next, _ active: Snapshot.Active) -> [String: Any] {
        [
            "session": active.id, "exId": next.exId ?? "", "exercise": next.exercise,
            "idx": next.idx, "i": next.i, "set": next.set, "sets": next.sets, "mode": next.mode,
            "reps": next.reps, "w": next.w, "sec": next.sec, "warmup": next.warmup,
            "side": next.side ?? "", "unconfirmed": unconfirmed,
        ]
    }

    // Recording only: the set begins now. A rest still running is over.
    func startSet() {
        guard let active, let next = active.next else { return }
        let now = Date()
        if rest != nil { skipRest() }
        setStartedAt = now
        recorder.mark("setStart", at: now, label(next, active))
        WKInterfaceDevice.current().play(.start)
    }

    func done() {
        guard let active, let next = active.next else { return }
        let now = Date()
        var info = label(next, active)
        info["started"] = setStartedAt != nil
        recorder.mark("setEnd", at: now, info)
        setStartedAt = nil
        // Only the first Done since the snapshot knows which set it is; the phone ticks the next
        // open one for the others, in order (lib/watch.js). Their rest is a guess too: the same as
        // the set the snapshot named, which is right while the exercise goes on.
        let restSec = next.restAfter
        let endsAt = restSec > 0 ? now.addingTimeInterval(restSec) : nil
        var event: [String: Any] = [
            "type": "setDone",
            "id": UUID().uuidString,
            "activeId": active.id,
            "at": now.timeIntervalSince1970 * 1000,
            "restSec": restSec,
            "restEndsAt": (endsAt?.timeIntervalSince1970 ?? 0) * 1000,
        ]
        if unconfirmed == 0 {
            event["idx"] = next.idx
            event["i"] = next.i
        }
        send(event)
        unconfirmed += 1
        WKInterfaceDevice.current().play(.success)
        if let endsAt {
            localRest = Snapshot.Rest(endsAt: endsAt.timeIntervalSince1970 * 1000, total: restSec, paused: false, left: restSec, kind: "rest")
        }
        scheduleRestEnd()
    }

    func skipRest() {
        recorder.mark("restSkip")
        localRest = nil
        if var s = snap { s.rest = nil; snap = s }
        send(["type": "skipRest", "at": Date().timeIntervalSince1970 * 1000])
        scheduleRestEnd()
    }

    func finish() {
        finishedId = active?.id
        send(["type": "finish", "at": Date().timeIntervalSince1970 * 1000])
        localRest = nil
        workout.end()
    }

    // The two files of a finished recording, to the phone (WatchLink saves them there). Deleted
    // here once each has arrived (didFinish fileTransfer below).
    private func sendRecording(_ files: [URL]) {
        guard !files.isEmpty, WCSession.isSupported() else { return }
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            NSLog("openGym watch: sending recording \(url.lastPathComponent) (\(bytes) bytes)")
            WCSession.default.transferFile(url, metadata: ["kind": "recording", "name": url.lastPathComponent])
        }
    }

    // The wrist tap at the end of a rest. The workout session keeps the app running with the
    // screen down, so a plain sleeping task is enough.
    private func scheduleRestEnd() {
        restEndTask?.cancel()
        guard let rest, !rest.paused else { return }
        let delay = rest.endDate.timeIntervalSinceNow
        restEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            WKInterfaceDevice.current().play(.notification)
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            WKInterfaceDevice.current().play(.start)
            self?.objectWillChange.send()
        }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            if let snap = Snapshot.decode(context["snap"]) { self.apply(snap) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let snap = Snapshot.decode(applicationContext["snap"])
        Task { @MainActor in if let snap { self.apply(snap) } }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if let error {
            NSLog("openGym watch: recording not sent, kept for the next try: \(error)")
            return
        }
        NSLog("openGym watch: recording delivered: \(fileTransfer.file.fileURL.lastPathComponent)")
        #if DEBUG
        // Simulator testing: keep the watch's copy to inspect (file transfers between simulators
        // are unreliable).
        if ProcessInfo.processInfo.environment["OG_KEEP_RECORDING"] != nil { return }
        #endif
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let snap = Snapshot.decode(message["snap"])
        Task { @MainActor in if let snap { self.apply(snap) } }
    }
}
