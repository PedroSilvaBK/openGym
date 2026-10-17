import Foundation
import WatchConnectivity

/**
 * The phone's end of the Apple Watch link (WatchConnectivity). Started at launch (AppDelegate), not
 * by the page: a message from the watch can wake the app in the background with no WebView loaded,
 * and its Done must still start the rest on the lock screen.
 *
 * Phone → watch: the session snapshot (lib/watch-snapshot.js), as the application context (the
 * watch reads the latest one whenever it wakes) and as a message when the watch is listening now.
 * Watch → phone: events ({ type: 'start' | 'setDone' | 'skipRest' | 'finish', … }), by message when
 * the phone is reachable and by transferUserInfo otherwise (queued, delivered in order).
 */
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    private static let pendingKey = "opengym.watch.pending"

    // Set by WatchPlugin while the page is loaded: a nudge to come and read the queue. Every event
    // waits in UserDefaults until the page says it was applied (ack): a page that is frozen, or an
    // app that iOS ends while suspended, loses nothing done on the wrist.
    var onEvent: (() -> Void)?
    // A recording arrived (WatchPlugin tells the page, to refresh what it shows).
    var onRecording: (() -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var status: [String: Any] {
        guard WCSession.isSupported() else { return ["supported": false] }
        let s = WCSession.default
        return [
            "supported": true,
            "activated": s.activationState == .activated,
            "paired": s.isPaired,
            "installed": s.isWatchAppInstalled,
            "reachable": s.isReachable,
        ]
    }

    func send(snapshot: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        do {
            try s.updateApplicationContext(["snap": snapshot])
        } catch {
            NSLog("openGym watch: context not sent: \(error)")
        }
        if s.isReachable {
            s.sendMessage(["snap": snapshot], replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: - Watch → phone

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { receive(message) }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { receive(userInfo) }

    private func receive(_ payload: [String: Any]) {
        guard let event = payload["event"] as? [String: Any], let type = event["type"] as? String else { return }
        DispatchQueue.main.async {
            // The lock screen follows the wrist at once; the page catches up whenever it runs.
            switch type {
            case "setDone":
                if let ms = event["restEndsAt"] as? Double, ms > 0 {
                    let total = (event["restSec"] as? Double).map { Int($0) } ?? 0
                    Task { await RestControl.startFromWatch(endsAt: Date(timeIntervalSince1970: ms / 1000), totalSec: total) }
                }
            case "skipRest":
                RestControl.unbook()
                Task { if let activity = RestControl.current { await RestControl.endRest(activity) } }
            default:
                break
            }
            self.deliver(event)
        }
    }

    private func deliver(_ event: [String: Any]) {
        var queue = pending
        queue.append(event)
        UserDefaults.standard.set(Array(queue.suffix(100)), forKey: Self.pendingKey)
        onEvent?()
    }

    // In the order they were done on the wrist.
    var pending: [[String: Any]] {
        UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String: Any]] ?? []
    }

    func ack(_ ids: Set<String>) {
        let rest = pending.filter { !ids.contains(($0["id"] as? String) ?? "") }
        UserDefaults.standard.set(rest, forKey: Self.pendingKey)
    }

    // MARK: - Recordings (training data, Watch/SensorRecorder.swift)

    static var recordingsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The file is only ours until this returns: moved out at once.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard (file.metadata?["kind"] as? String) == "recording" else { return }
        let name = (file.metadata?["name"] as? String) ?? file.fileURL.lastPathComponent
        let target = Self.recordingsDirectory.appendingPathComponent((name as NSString).lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: target)
            NSLog("openGym watch: recording received: \(target.lastPathComponent)")
            // Both halves here: straight on to the server, if the page has said where it is.
            Task { await RecordingUploader.shared.run() }
            DispatchQueue.main.async { self.onRecording?() }
        } catch {
            NSLog("openGym watch: recording not kept: \(error)")
        }
    }

    var recordings: [[String: Any]] {
        let dir = Self.recordingsDirectory
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return [
                "name": url.lastPathComponent,
                "uri": url.absoluteString,
                "bytes": values?.fileSize ?? 0,
                "at": ((values?.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000).rounded(),
            ]
        }
    }

    func deleteRecordings() {
        try? FileManager.default.removeItem(at: Self.recordingsDirectory)
    }

    // MARK: - Session lifecycle

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { NSLog("openGym watch: activation failed: \(error)") }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    // A different watch was paired: start over with it.
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
