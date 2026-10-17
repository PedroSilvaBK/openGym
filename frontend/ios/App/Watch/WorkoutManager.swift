import Foundation
import HealthKit

// The watch's own HealthKit workout for an openGym session: it keeps the app running on the wrist
// with the screen down (so the rest countdown and its haptic still happen), reads heart rate and
// active energy live, and saves a strength workout to Health when the session ends.
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var heartRate: Double = 0
    @Published private(set) var energy: Double = 0

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    static let strength: HKWorkoutConfiguration = {
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        return config
    }()

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned), HKQuantityType(.heartRate)]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
        try? await store.requestAuthorization(toShare: share, read: read)
    }

    func start(configuration: HKWorkoutConfiguration = WorkoutManager.strength, at date: Date = Date()) {
        guard session == nil else { return }
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            session.startActivity(with: date)
            builder.beginCollection(withStart: date) { _, error in
                if let error { NSLog("openGym watch: beginCollection: \(error)") }
            }
            running = true
        } catch {
            NSLog("openGym watch: workout not started: \(error)")
        }
    }

    // Saved to Health once the session reports .ended (the delegate below).
    func end() {
        session?.end()
    }

    private func finish(at date: Date) {
        guard let builder else { return reset() }
        builder.endCollection(withEnd: date) { [weak self] _, _ in
            builder.finishWorkout { _, error in
                if let error { NSLog("openGym watch: workout not saved: \(error)") }
                Task { @MainActor in self?.reset() }
            }
        }
    }

    private func reset() {
        session = nil
        builder = nil
        running = false
        heartRate = 0
        energy = 0
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        Task { @MainActor in self.finish(at: date) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        NSLog("openGym watch: workout session failed: \(error)")
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm = workoutBuilder.statistics(for: HKQuantityType(.heartRate))?
            .mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let kcal = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
        Task { @MainActor in
            if let bpm { self.heartRate = bpm }
            if let kcal { self.energy = kcal }
        }
    }
}
