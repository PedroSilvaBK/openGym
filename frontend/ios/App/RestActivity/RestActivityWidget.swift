import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct RestActivityBundle: WidgetBundle {
    var body: some Widget { RestActivityWidget() }
}

// The workout in the Dynamic Island and on the lock screen: the session's running time, or the
// rest countdown while a rest runs. Both clocks are the system's own (Text(timerInterval:) and
// .timer), so they keep time with the app suspended; the app only updates the activity when what
// is shown changes (a rest starting, pause, ±15 s, skip). A rest that simply runs out needs no
// update at all: the activity goes stale at its end and the views fall back to the session.
struct RestActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color(red: 12 / 255, green: 14 / 255, blue: 18 / 255).opacity(0.9))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            let accent = Color(argb: s.accent)
            let mode = Mode(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(mode == .rest ? s.title : (s.workoutTitle ?? ""), systemImage: mode.icon(paused: s.paused))
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(accent)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Clock(state: s, mode: mode, over: context.attributes.over)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if let line = mode.line(s, over: context.attributes.over) {
                            Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if mode == .rest {
                            RestProgress(state: s).tint(accent)
                            Controls(state: s, attributes: context.attributes, accent: accent, ink: Color(argb: s.ink))
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: mode.icon(paused: s.paused)).foregroundStyle(accent)
            } compactTrailing: {
                Clock(state: s, mode: mode, over: "0:00")
                    .monospacedDigit()
                    .frame(maxWidth: mode == .rest ? 52 : 64)
                    .foregroundStyle(accent)
            } minimal: {
                Image(systemName: mode.icon(paused: s.paused)).foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }
}

// What the activity shows right now.
private enum Mode {
    case rest      // a rest is counting down (or held)
    case workout   // the session's running time
    case over      // a rest ran out with no session behind it

    init(_ context: ActivityViewContext<RestActivityAttributes>) {
        let s = context.state
        let restLive = s.resting && (s.paused || (!context.isStale && s.endsAt > Date()))
        if restLive { self = .rest } else if s.workoutStart != nil { self = .workout } else { self = .over }
    }

    func icon(paused: Bool) -> String {
        switch self {
        case .rest: return paused ? "pause.fill" : "timer"
        case .workout, .over: return "dumbbell.fill"
        }
    }

    // The line under the clock: the next set during a rest, "Next set!" once a rest has run out.
    func line(_ s: RestActivityAttributes.ContentState, over: String) -> String? {
        switch self {
        case .rest: return s.detail
        case .workout: return s.resting ? [over, s.detail].compactMap { $0 }.joined(separator: " · ") : nil
        case .over: return s.detail
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RestActivityAttributes>

    var body: some View {
        let s = context.state
        let accent = Color(argb: s.accent)
        let mode = Mode(context)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(mode == .rest ? s.title : (s.workoutTitle ?? context.attributes.over), systemImage: mode.icon(paused: s.paused))
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(accent)
                    if let line = mode.line(s, over: context.attributes.over) {
                        Text(line).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                Spacer()
                Clock(state: s, mode: mode, over: context.attributes.over)
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
            }
            if mode == .rest {
                RestProgress(state: s).tint(accent)
                Controls(state: s, attributes: context.attributes, accent: accent, ink: Color(argb: s.ink))
            }
        }
        .padding(16)
    }
}

// The rest's time left (live, or the held figure while paused), the session's running time, or
// the "rest's over" line.
private struct Clock: View {
    let state: RestActivityAttributes.ContentState
    let mode: Mode
    let over: String

    var body: some View {
        switch mode {
        case .rest:
            if state.paused {
                Text(clock(state.leftSec))
            } else {
                Text(timerInterval: Date()...state.endsAt, countsDown: true)
            }
        case .workout:
            if let start = state.workoutStart {
                Text(start, style: .timer)
            }
        case .over:
            Text(over)
        }
    }
}

private struct RestProgress: View {
    let state: RestActivityAttributes.ContentState

    var body: some View {
        let total = TimeInterval(max(1, state.totalSec))
        if state.paused {
            ProgressView(value: Double(state.leftSec), total: total)
        } else {
            ProgressView(timerInterval: state.endsAt.addingTimeInterval(-total)...state.endsAt, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
        }
    }
}

private struct Controls: View {
    let state: RestActivityAttributes.ContentState
    let attributes: RestActivityAttributes
    let accent: Color
    let ink: Color

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: RestAdjustIntent("minus")) { Text("−15s").frame(maxWidth: .infinity) }
            Button(intent: RestAdjustIntent(state.paused ? "resume" : "pause")) {
                Image(systemName: state.paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(state.paused ? attributes.resume : attributes.pause)
            }
            Button(intent: RestAdjustIntent("plus")) { Text("+15s").frame(maxWidth: .infinity) }
            Button(intent: RestAdjustIntent("skip")) {
                Text(attributes.skip).frame(maxWidth: .infinity).foregroundStyle(ink)
            }
            .tint(accent)
            .buttonStyle(.borderedProminent)
        }
        .buttonStyle(.bordered)
        .font(.subheadline.weight(.semibold))
        .tint(.white)
    }
}

private func clock(_ sec: Int) -> String {
    let s = max(0, sec)
    return String(format: "%d:%02d", s / 60, s % 60)
}

extension Color {
    init(argb: Int) {
        let v = UInt32(truncatingIfNeeded: argb)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }
}
