import HealthKit
import SwiftUI
import WatchKit

@main
struct OpenGymWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @StateObject private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task { @MainActor in
            WatchModel.shared.activate()
            #if DEBUG
            await WatchModel.shared.runDebugScript()
            #endif
        }
    }

    // A session started on the phone (WatchPlugin.startWatchApp): HealthKit opens this app with the
    // workout configuration, and the workout starts here without a tap.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in WatchModel.shared.workout.start(configuration: workoutConfiguration) }
    }
}
