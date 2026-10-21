import Foundation
import HealthKit
import Observation

/// Läser träningsdata från HealthKit. Enda stället i appen som pratar med HKHealthStore.
@MainActor
@Observable
final class HealthKitManager {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Hur långt bak vi hämtar pass.
    static let historyDays = 90

    private(set) var workouts: [WorkoutSummary] = []
    private(set) var metrics: HealthMetrics = .empty
    private(set) var state: LoadState = .idle

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.vo2Max),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
        ]
        if #available(iOS 18.0, *) {
            types.insert(HKQuantityType(.distanceCrossCountrySkiing))
            types.insert(HKQuantityType(.distanceRowing))
        }
        return types
    }

    /// Visar HealthKits behörighetsdialog (bara första gången) och laddar sedan all data.
    func requestAuthorizationAndLoad() async {
        guard isHealthDataAvailable else {
            state = .failed("Hälsodata är inte tillgänglig på den här enheten.")
            return
        }
        state = .loading
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            try await load()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        do {
            try await load()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Hämtning

    private func load() async throws {
        async let workouts = fetchWorkouts()
        async let resting = latestSample(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let hrv = latestSample(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))
        async let vo2 = latestSample(.vo2Max, unit: HKUnit(from: "ml/kg*min"))

        self.workouts = try await workouts
        self.metrics = HealthMetrics(
            restingHeartRate: try await resting,
            heartRateVariability: try await hrv,
            vo2Max: try await vo2
        )
    }

    private func fetchWorkouts() async throws -> [WorkoutSummary] {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -Self.historyDays, to: end) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let result = try await descriptor.result(for: store)
        return result.map(WorkoutSummary.init(workout:))
    }

    private func latestSample(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> MetricSample? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        guard let sample = try await descriptor.result(for: store).first else { return nil }
        return MetricSample(value: sample.quantity.doubleValue(for: unit), date: sample.endDate)
    }
}
