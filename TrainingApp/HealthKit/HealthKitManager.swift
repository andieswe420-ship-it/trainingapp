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
    /// Mätningshistorik (vilopuls, HRV, VO2 max) för samma period som passen.
    private(set) var samples: [HealthSample] = []
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
        async let resting = latestSample(.restingHeartRate)
        async let hrv = latestSample(.heartRateVariability)
        async let vo2 = latestSample(.vo2Max)
        async let restingHistory = fetchSamples(.restingHeartRate)
        async let hrvHistory = fetchSamples(.heartRateVariability)
        async let vo2History = fetchSamples(.vo2Max)

        self.workouts = try await workouts
        self.metrics = HealthMetrics(
            restingHeartRate: try await resting,
            heartRateVariability: try await hrv,
            vo2Max: try await vo2
        )
        self.samples = try await restingHistory + hrvHistory + vo2History
    }

    private var historyPredicate: NSPredicate {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -Self.historyDays, to: end) ?? end
        return HKQuery.predicateForSamples(withStart: start, end: end)
    }

    private func fetchWorkouts() async throws -> [WorkoutSummary] {
        let predicate = historyPredicate
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let result = try await descriptor.result(for: store)
        return result.map(WorkoutSummary.init(workout:))
    }

    private func latestSample(_ kind: HealthSample.Kind) async throws -> MetricSample? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: kind.quantityType)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        guard let sample = try await descriptor.result(for: store).first else { return nil }
        return MetricSample(value: sample.quantity.doubleValue(for: kind.unit), date: sample.endDate)
    }

    private func fetchSamples(_ kind: HealthSample.Kind) async throws -> [HealthSample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: kind.quantityType, predicate: historyPredicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)]
        )
        return try await descriptor.result(for: store).map { sample in
            HealthSample(
                id: sample.uuid,
                kind: kind,
                value: sample.quantity.doubleValue(for: kind.unit),
                date: sample.endDate
            )
        }
    }
}

private extension HealthSample.Kind {
    var quantityType: HKQuantityType {
        switch self {
        case .restingHeartRate: HKQuantityType(.restingHeartRate)
        case .heartRateVariability: HKQuantityType(.heartRateVariabilitySDNN)
        case .vo2Max: HKQuantityType(.vo2Max)
        }
    }

    var unit: HKUnit {
        switch self {
        case .restingHeartRate: HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariability: .secondUnit(with: .milli)
        case .vo2Max: HKUnit(from: "ml/kg*min")
        }
    }
}
