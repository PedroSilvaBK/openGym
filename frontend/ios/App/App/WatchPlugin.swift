import Capacitor
import Foundation
import HealthKit

/**
 * lib/watch.js's bridge to the Apple Watch (WatchLink.swift).
 *
 *   update({ snapshot })  what the watch shows (lib/watch-snapshot.js)
 *   status()              { supported, paired, installed, reachable, … }
 *   startWatchApp()       a session started on the phone opens the watch app with its workout running
 *   pending()             what was done on the wrist, not yet applied: start, setDone, skipRest, finish
 *   ack({ ids })          applied; off the queue
 *   recordings()          { files: [{ name, uri, bytes, at }] } — training data from the watch
 *   uploadRecordings({ base, headers, chunkBytes })  to the paired server (RecordingUploader)
 *   deleteRecordings()
 *   'watch' events        a nudge: something new is waiting in pending()
 */
@objc(WatchPlugin)
public class WatchPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "WatchPlugin"
    public let jsName = "Watch"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startWatchApp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pending", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "ack", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "recordings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteRecordings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "uploadRecordings", returnType: CAPPluginReturnPromise)
    ]

    private let health = HKHealthStore()

    override public func load() {
        WatchLink.shared.onEvent = { [weak self] in
            self?.notifyListeners("watch", data: [:], retainUntilConsumed: true)
        }
        WatchLink.shared.onRecording = { [weak self] in
            self?.notifyListeners("recording", data: [:])
        }
    }

    @objc func pending(_ call: CAPPluginCall) {
        call.resolve(["events": WatchLink.shared.pending])
    }

    @objc func ack(_ call: CAPPluginCall) {
        let ids = (call.getArray("ids") as? [String]) ?? []
        WatchLink.shared.ack(Set(ids))
        call.resolve()
    }

    @objc func recordings(_ call: CAPPluginCall) {
        call.resolve(["files": WatchLink.shared.recordings])
    }

    // Configures the upload (kept in memory only) and runs it now.
    @objc func uploadRecordings(_ call: CAPPluginCall) {
        guard let base = call.getString("base"), !base.isEmpty else { return call.reject("base is required") }
        var headers: [String: String] = [:]
        for (k, v) in call.getObject("headers") ?? [:] { if let s = v as? String { headers[k] = s } }
        let chunk = min(max(call.getInt("chunkBytes") ?? 4 * 1024 * 1024, 64 * 1024), 4 * 1024 * 1024)
        Task {
            await RecordingUploader.shared.configure(.init(base: base, headers: headers, chunkBytes: chunk))
            let result = await RecordingUploader.shared.run()
            call.resolve(result)
        }
    }

    @objc func deleteRecordings(_ call: CAPPluginCall) {
        WatchLink.shared.deleteRecordings()
        call.resolve()
    }

    @objc func update(_ call: CAPPluginCall) {
        guard let snapshot = call.getObject("snapshot") else { return call.reject("snapshot is required") }
        WatchLink.shared.send(snapshot: snapshot)
        call.resolve()
    }

    @objc func status(_ call: CAPPluginCall) {
        call.resolve(WatchLink.shared.status)
    }

    // HealthKit launches the watch app straight into a strength workout (OpenGymWatchApp's
    // handle(_ workoutConfiguration:)). Asks once for permission to save workouts, which that
    // launch needs.
    @objc func startWatchApp(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else { return call.resolve(["started": false]) }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { [weak self] _, _ in
            self?.health.startWatchApp(with: config) { started, error in
                if let error { NSLog("openGym watch: startWatchApp: \(error)") }
                call.resolve(["started": started])
            }
        }
    }
}
