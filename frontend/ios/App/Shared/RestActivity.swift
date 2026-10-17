import ActivityKit
import AppIntents
import Foundation
import UserNotifications

// The workout as a Live Activity: Dynamic Island + lock screen. It shows the session's running
// time, and the rest countdown while a rest runs; once that rest is over or skipped it goes back to
// the session's time. Compiled into both the app (RestAlertPlugin starts, changes and ends it) and
// the RestActivity widget extension (draws it).
// The island's buttons are LiveActivityIntents, which iOS runs in the app's process, so the
// rest-over notification can be moved with them and the page told what changed.
struct RestActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        // The live session (useStore S.active): its start and name. nil for a rest with no session
        // behind it, which ends with the rest.
        var workoutStart: Date?
        var workoutTitle: String?
        // A rest is on: the fields below are the countdown. Off, they are left from the last rest.
        var resting: Bool
        var endsAt: Date
        var totalSec: Int
        // What is left while paused; a running countdown reads endsAt instead.
        var leftSec: Int
        var paused: Bool
        // "Rest" or "Switch sides".
        var title: String
        // "Next: Bench Press · Set 3/5", or nil when the page did not send one.
        var detail: String?
        // ARGB, as lib/rest-alert.js accentColors sends them.
        var accent: Int
        var ink: Int
    }

    // Translated by the page (lib/i18n), fixed for the life of the activity.
    var over: String
    var pause: String
    var resume: String
    var skip: String
}

// A change made from the island, for the page to mirror (useUI bindNativeRest): the same event
// shape the Android notification's buttons send.
struct RestEvent: Codable {
    var type: String
    var endsAt: Double
    var totalMs: Double
    var leftMs: Double
    var paused: Bool

    var json: [String: Any] { ["type": type, "endsAt": endsAt, "totalMs": totalMs, "leftMs": leftMs, "paused": paused] }
}

enum RestControl {
    static let notificationId = "opengym-rest-over"
    // useUI addRest: +15 s stops at the wheel's 15:00.
    static let maxSec = 15 * 60
    private static let notifKey = "opengym.rest.notification"
    private static let pendingKey = "opengym.rest.pendingEvent"

    // Set by RestAlertPlugin while the page is loaded. An intent that runs with no page (the app
    // woken in the background just for it) parks its event instead, and the plugin hands it over
    // on load.
    nonisolated(unsafe) static var onEvent: ((RestEvent) -> Void)?

    static var current: Activity<RestActivityAttributes>? { Activity<RestActivityAttributes>.activities.first }

    // The rest is over (skipped, cancelled): back to the session's time, or gone without a session.
    static func endRest(_ activity: Activity<RestActivityAttributes>) async {
        var s = activity.content.state
        guard s.workoutStart != nil else {
            await activity.end(nil, dismissalPolicy: .immediate)
            return
        }
        guard s.resting else { return }
        s.resting = false
        s.paused = false
        await activity.update(ActivityContent(state: s, staleDate: nil))
    }

    // MARK: - The rest-over notification

    struct Notice: Codable { var title: String; var sound: Bool }

    // Kept so a resume or ±15 s from the island can book the end again with the same words.
    static func remember(_ notice: Notice) {
        if let data = try? JSONEncoder().encode(notice) { UserDefaults.standard.set(data, forKey: notifKey) }
    }

    static func book(at endsAt: Date) {
        let saved = UserDefaults.standard.data(forKey: notifKey).flatMap { try? JSONDecoder().decode(Notice.self, from: $0) }
        let notice = saved ?? Notice(title: "Rest’s over. Next set!", sound: true)
        let content = UNMutableNotificationContent()
        content.title = notice.title
        if notice.sound { content.sound = .default }
        content.interruptionLevel = .timeSensitive
        let secs = max(1, endsAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        center.add(UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger))
    }

    static func unbook() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        center.removeDeliveredNotifications(withIdentifiers: [notificationId])
    }

    // A set done on the watch while the page is not running (the phone locked in a pocket): the
    // rest it earned goes on the island and its end is booked now. The page catches up later
    // (lib/watch.js) and moves the same rest, never a second one.
    static func startFromWatch(endsAt: Date, totalSec: Int) async {
        guard endsAt > Date() else { return }
        book(at: endsAt)
        guard let activity = current else { return }
        var s = activity.content.state
        s.resting = true
        s.paused = false
        s.endsAt = endsAt
        s.totalSec = max(1, totalSec, Int(ceil(endsAt.timeIntervalSinceNow)))
        s.leftSec = Int(ceil(endsAt.timeIntervalSinceNow))
        if s.title.isEmpty { s.title = "Rest" }
        s.detail = nil
        await activity.update(ActivityContent(state: s, staleDate: endsAt))
    }

    // MARK: - The island's buttons

    static func apply(_ action: String) async {
        guard let activity = current, activity.content.state.resting else { return }
        var s = activity.content.state
        let now = Date()
        let leftNow = s.paused ? s.leftSec : Int(ceil(s.endsAt.timeIntervalSince(now)))

        switch action {
        case "pause":
            guard !s.paused else { return }
            s.leftSec = max(1, leftNow)
            s.paused = true
        case "resume":
            guard s.paused else { return }
            s.endsAt = now.addingTimeInterval(TimeInterval(s.leftSec))
            s.paused = false
        case "minus", "plus":
            let delta = action == "plus" ? min(15, max(0, maxSec - leftNow)) : -15
            let left = leftNow + delta
            if left <= 0 { await skip(activity); return }
            if s.paused { s.leftSec = left } else { s.endsAt = s.endsAt.addingTimeInterval(TimeInterval(delta)) }
            s.totalSec = max(s.totalSec, left)
        default:
            await skip(activity)
            return
        }

        // The island first: it is what the finger is waiting on. Moving the notification and telling
        // the page can follow.
        await activity.update(ActivityContent(state: s, staleDate: s.paused ? nil : s.endsAt))
        let left = s.paused ? s.leftSec : Int(ceil(s.endsAt.timeIntervalSince(now)))
        emit(RestEvent(type: action, endsAt: s.endsAt.timeIntervalSince1970 * 1000, totalMs: Double(s.totalSec * 1000), leftMs: Double(max(0, left) * 1000), paused: s.paused))
        if s.paused { unbook() } else { book(at: s.endsAt) }
    }

    private static func skip(_ activity: Activity<RestActivityAttributes>) async {
        await endRest(activity)
        emit(RestEvent(type: "skip", endsAt: 0, totalMs: 0, leftMs: 0, paused: false))
        unbook()
    }

    private static func emit(_ event: RestEvent) {
        if let onEvent {
            onEvent(event)
        } else if let data = try? JSONEncoder().encode(event) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }

    // The last change the page has not seen, at most one: each one carries the whole countdown.
    static func takePending() -> RestEvent? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        return try? JSONDecoder().decode(RestEvent.self, from: data)
    }
}

struct RestAdjustIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Adjust rest"
    static let isDiscoverable = false

    @Parameter(title: "Action") var action: String

    init() {}
    init(_ action: String) { self.action = action }

    func perform() async throws -> some IntentResult {
        #if DEBUG
        let started = Date()
        defer { print("⚡️  RestAdjustIntent \(action): \(Int(Date().timeIntervalSince(started) * 1000)) ms in the app") }
        #endif
        await RestControl.apply(action)
        return .result()
    }
}
