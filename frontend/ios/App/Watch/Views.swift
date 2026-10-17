import SwiftUI
import WatchKit

private let accent = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)

struct RootView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        if model.active != nil {
            ActiveView()
        } else {
            IdleView()
        }
    }
}

// MARK: - Not training: what to start

struct IdleView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        NavigationStack {
            List {
                if let snap = model.snap {
                    if let today = snap.today {
                        Section("Today") {
                            Button { model.start(ids: today.ids) } label: {
                                Label(today.name, systemImage: "play.fill").foregroundStyle(accent)
                            }
                        }
                    }
                    if !snap.routines.isEmpty {
                        Section("Routines") {
                            ForEach(snap.routines) { r in
                                Button(r.name) { model.start(ids: [r.id]) }
                            }
                        }
                    }
                    Section {
                        Button("Freestyle") { model.start(ids: []) }
                    }
                    Section {
                        Toggle("Record motion", isOn: $model.recordingOn)
                    } footer: {
                        Text("Records this watch's motion during workouts, with a Start and a Done for every set, to train set detection. Sent to your iPhone when the workout ends.")
                    }
                } else {
                    Text("Open openGym on your iPhone once to bring your routines here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("openGym")
        }
    }
}

// MARK: - Training

struct ActiveView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        TabView {
            Group {
                if let rest = model.rest {
                    RestView(rest: rest)
                } else {
                    SetView()
                }
            }
            StatsView()
            ControlsView()
        }
        .tabViewStyle(.verticalPage)
    }
}

struct SetView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        let active = model.active
        let next = active?.next
        VStack(alignment: .leading, spacing: 4) {
            if let next {
                Text(next.exercise)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if model.recording { RecBadge() }
                HStack(spacing: 4) {
                    // Sets ticked here that the phone has not answered yet move the count on.
                    Text("Set \(min(next.sets, next.set + model.unconfirmed)) of \(next.sets)")
                    if next.warmup { Text("· warm-up") }
                    if let side = next.side { Text("· \(side == "L" ? "left" : "right")") }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Text(next.target(unit: model.snap?.unit ?? "kg"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer(minLength: 2)
                if model.recording && model.setStartedAt == nil {
                    // Recording: the set's start is marked too, so the data knows where it began.
                    // Done stays at hand for a set that was started without it.
                    Button(action: model.startSet) {
                        Label("Start", systemImage: "play.fill")
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .tint(accent)
                    .buttonStyle(.borderedProminent)
                    .handGestureShortcut(.primaryAction)
                    Button("Done without start", action: model.done)
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else {
                    if let started = model.setStartedAt {
                        Text(started, style: .timer).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button(action: model.done) {
                        Label("Done", systemImage: "checkmark")
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .tint(accent)
                    .buttonStyle(.borderedProminent)
                    // Series 9 and later: pinch twice to press it without touching the screen.
                    .handGestureShortcut(.primaryAction)
                }
            } else {
                Text("All sets done").font(.headline)
                Text("Finish the workout from the last page or on your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct RestView: View {
    @EnvironmentObject var model: WatchModel
    let rest: Snapshot.Rest

    var body: some View {
        VStack(spacing: 6) {
            Text(rest.kind == "switch" ? "Switch sides" : "Rest")
                .font(.headline)
                .foregroundStyle(accent)
            Group {
                if rest.paused {
                    Text(clock(Int(rest.left)))
                } else {
                    Text(timerInterval: Date()...rest.endDate, countsDown: true)
                }
            }
            .font(.system(size: 44, weight: .semibold).monospacedDigit())
            if let next = model.active?.next {
                Text(next.exercise).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.recording {
                // Recording: the next set starts from here, and its start is what is marked.
                HStack {
                    Button("Skip", action: model.skipRest)
                    Button(action: model.startSet) { Label("Start", systemImage: "play.fill") }
                        .tint(accent)
                        .buttonStyle(.borderedProminent)
                        .handGestureShortcut(.primaryAction)
                }
            } else {
                Button("Skip", action: model.skipRest)
                    .tint(accent)
                    .handGestureShortcut(.primaryAction)
            }
        }
    }
}

struct StatsView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let active = model.active {
                Text(active.name).font(.headline).lineLimit(1)
                Text(active.startDate, style: .timer)
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(accent)
                Text("\(active.done + model.unconfirmed) of \(active.total) sets")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label(model.workout.heartRate > 0 ? "\(Int(model.workout.heartRate))" : "--", systemImage: "heart.fill")
                    .foregroundStyle(.red)
                Spacer()
                Label("\(Int(model.workout.energy)) kcal", systemImage: "flame.fill")
                    .foregroundStyle(.orange)
            }
            .font(.footnote.monospacedDigit())
        }
        .padding(.horizontal, 4)
    }
}

struct ControlsView: View {
    @EnvironmentObject var model: WatchModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                confirming = true
            } label: {
                Label("Finish", systemImage: "flag.checkered").frame(maxWidth: .infinity)
            }
            .tint(.red)
            Text("Saves to Health and asks your iPhone to finish the workout.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .confirmationDialog("Finish the workout?", isPresented: $confirming) {
            Button("Finish", role: .destructive, action: model.finish)
        }
    }
}

// Recording is on for this workout.
struct RecBadge: View {
    var body: some View {
        Label("REC", systemImage: "circle.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.red)
            .labelStyle(.titleAndIcon)
    }
}

private func clock(_ sec: Int) -> String {
    let s = max(0, sec)
    return String(format: "%d:%02d", s / 60, s % 60)
}
