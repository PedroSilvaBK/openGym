import ActivityKit
import Capacitor
import Foundation
import UserNotifications

/**
 * The iOS side of lib/rest-alert.js: the same plugin name and calls as Android's RestAlert, so the
 * page books a rest the same way on both. Where Android posts a countdown notification and an
 * alarm, iOS shows a Live Activity (Dynamic Island + lock screen, ../Shared/RestActivity.swift)
 * and books a local notification for the end of the rest.
 *
 * iOS only: workout / endWorkout keep the same Live Activity up for the whole live session, showing
 * its running time between rests (lib/rest-alert.js showWorkoutActivity).
 *
 * Not here: buzz and tone (an alarm-strength vibration and a ducking end tone). The page's
 * own vibration and chime are what iOS gets; rest-alert.js does not call them on iOS.
 */
@objc(RestAlertPlugin)
public class RestAlertPlugin: CAPPlugin, CAPBridgedPlugin, NotificationHandlerProtocol {
    public let identifier = "RestAlertPlugin"
    public let jsName = "RestAlert"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "schedule", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hold", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setAccent", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "workout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "endWorkout", returnType: CAPPluginReturnPromise)
    ]

    // @capacitor/local-notifications' handler, which every other notification still goes to.
    private weak var nextHandler: NotificationHandlerProtocol?

    override public func load() {
        RestControl.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.notifyListeners("rest", data: event.json, retainUntilConsumed: true) }
        }
        // A button pressed while the page was not loaded: hand it over once a listener is there.
        if let pending = RestControl.takePending() {
            notifyListeners("rest", data: pending.json, retainUntilConsumed: true)
        }
        if let router = bridge?.notificationRouter {
            nextHandler = router.localNotificationHandler
            router.localNotificationHandler = self
        }
    }

    // MARK: - Calls from lib/rest-alert.js

    @objc func schedule(_ call: CAPPluginCall) {
        guard let at = call.getDouble("at") else { return call.reject("at is required") }
        let endsAt = Date(timeIntervalSince1970: at / 1000)
        guard endsAt > Date() else { return call.reject("at must be in the future") }
        let totalSec = max(1, Int(((call.getDouble("totalMs") ?? 0) / 1000).rounded()))

        RestControl.remember(.init(title: call.getString("title") ?? "Rest’s over. Next set!", sound: call.getBool("sound") ?? true))
        RestControl.book(at: endsAt)

        let session = Self.session(call)
        let state = RestActivityAttributes.ContentState(
            workoutStart: session?.start,
            workoutTitle: session?.title,
            resting: true,
            endsAt: endsAt,
            totalSec: max(totalSec, Int(ceil(endsAt.timeIntervalSinceNow))),
            leftSec: Int(ceil(endsAt.timeIntervalSinceNow)),
            paused: false,
            title: call.getString("countdownTitle") ?? "Rest",
            detail: call.getString("detail").flatMap { $0.isEmpty ? nil : $0 },
            accent: call.getInt("accent") ?? Int(bitPattern: 0xFF30D158),
            ink: call.getInt("ink") ?? Int(bitPattern: 0xFF0C0E12)
        )
        Task {
            await Self.show(state, Self.attributes(call))
            call.resolve()
        }
    }

    // The live session's time between rests. A rest already on screen keeps its countdown; only the
    // session's start, name and colours are brought up to date.
    @objc func workout(_ call: CAPPluginCall) {
        guard let session = Self.session(call) else { return call.reject("start is required") }
        Task {
            if let activity = RestControl.current {
                var s = activity.content.state
                s.workoutStart = session.start
                s.workoutTitle = session.title
                s.accent = call.getInt("accent") ?? s.accent
                s.ink = call.getInt("ink") ?? s.ink
                await activity.update(ActivityContent(state: s, staleDate: s.resting && !s.paused ? s.endsAt : nil))
            } else {
                let now = Date()
                let state = RestActivityAttributes.ContentState(
                    workoutStart: session.start, workoutTitle: session.title, resting: false,
                    endsAt: now, totalSec: 1, leftSec: 0, paused: false, title: "", detail: nil,
                    accent: call.getInt("accent") ?? Int(bitPattern: 0xFF30D158),
                    ink: call.getInt("ink") ?? Int(bitPattern: 0xFF0C0E12))
                await Self.show(state, Self.attributes(call))
            }
            call.resolve()
        }
    }

    // The session finished or was thrown away.
    @objc func endWorkout(_ call: CAPPluginCall) {
        RestControl.unbook()
        Task {
            for activity in Activity<RestActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            call.resolve()
        }
    }

    private static func session(_ call: CAPPluginCall) -> (start: Date, title: String?)? {
        guard let ms = call.getDouble("workoutStart"), ms > 0 else { return nil }
        let title = call.getString("workoutTitle").flatMap { $0.isEmpty ? nil : $0 }
        return (Date(timeIntervalSince1970: ms / 1000), title)
    }

    private static func attributes(_ call: CAPPluginCall) -> RestActivityAttributes {
        RestActivityAttributes(
            over: call.getString("overLabel") ?? "Rest’s over. Next set!",
            pause: call.getString("pause") ?? "Pause",
            resume: call.getString("resume") ?? "Resume",
            skip: call.getString("skip") ?? "Skip"
        )
    }

    // Paused in the app: the island holds the figure, and the end is no longer booked.
    @objc func hold(_ call: CAPPluginCall) {
        let leftSec = max(1, Int(((call.getDouble("leftMs") ?? 1000) / 1000).rounded(.up)))
        let totalSec = max(leftSec, Int(((call.getDouble("totalMs") ?? 0) / 1000).rounded()))
        RestControl.unbook()
        Task {
            if let activity = RestControl.current, activity.content.state.resting {
                var s = activity.content.state
                s.paused = true
                s.leftSec = leftSec
                s.totalSec = totalSec
                await activity.update(ActivityContent(state: s, staleDate: nil))
            }
            call.resolve()
        }
    }

    // Skip, Dismiss, a new rest replacing this one, "rest off": back to the session's time.
    @objc func cancel(_ call: CAPPluginCall) {
        RestControl.unbook()
        Task {
            if let activity = RestControl.current { await RestControl.endRest(activity) }
            call.resolve()
        }
    }

    @objc func setAccent(_ call: CAPPluginCall) {
        Task {
            if let activity = RestControl.current, let accent = call.getInt("accent") {
                var s = activity.content.state
                s.accent = accent
                s.ink = call.getInt("ink") ?? s.ink
                await activity.update(ActivityContent(state: s, staleDate: activity.content.staleDate))
            }
            call.resolve()
        }
    }

    // One activity at a time: a running one is moved to the new state rather than replaced, so the
    // island does not collapse and reopen between two sets. A rest arriving without a session keeps
    // the session already on screen. Live Activities switched off in Settings only lose the island;
    // the notification is booked either way.
    private static func show(_ state: RestActivityAttributes.ContentState, _ attributes: RestActivityAttributes) async {
        var state = state
        if state.workoutStart == nil, let s = RestControl.current?.content.state {
            state.workoutStart = s.workoutStart
            state.workoutTitle = s.workoutTitle
        }
        let content = ActivityContent(state: state, staleDate: state.resting ? state.endsAt : nil)
        if let activity = RestControl.current, activity.attributes == attributes {
            await activity.update(content)
            return
        }
        for activity in Activity<RestActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            CAPLog.print("⚡️  RestAlert: Live Activities are switched off")
            return
        }
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            #if DEBUG
            CAPLog.print("⚡️  RestAlert: started \(activity.id) resting=\(state.resting) workout=\(state.workoutStart != nil)")
            #endif
        } catch {
            CAPLog.print("⚡️  RestAlert: Live Activity not started: \(error)")
        }
    }

    // MARK: - Notifications

    // With the app in front the page plays the end itself (useUI runRest); a banner on top of it
    // would announce the same thing twice.
    public func willPresent(notification: UNNotification) -> UNNotificationPresentationOptions {
        if notification.request.identifier == RestControl.notificationId { return [] }
        return nextHandler?.willPresent(notification: notification) ?? []
    }

    public func didReceive(response: UNNotificationResponse) {
        if response.notification.request.identifier == RestControl.notificationId { return }
        nextHandler?.didReceive(response: response)
    }
}
