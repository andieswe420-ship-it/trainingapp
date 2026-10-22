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

    /// Hur långt bak vi hämtar data (6 månader för trenderna).
    static let historyDays = 180

    private(set) var workouts: [WorkoutSummary] = []
    private(set) var metrics: HealthMetrics = .empty
    /// Mätningshistorik (vilopuls, HRV, VO2 max) för samma period som passen.
    private(set) var samples: [HealthSample] = []
    /// Sömn, aktivitet, andning och handledstemperatur per dag.
    private(set) var dailyMetrics: [DailyMetrics] = []
    private(set) var state: LoadState = .idle

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    @ObservationIgnored private var workoutObserver: HKObserverQuery?
    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.heartRateRecoveryOneMinute),
            HKQuantityType(.vo2Max),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.stepCount),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.appleSleepingWristTemperature),
            HKQuantityType(.runningPower),
            HKQuantityType(.runningStrideLength),
            HKQuantityType(.runningGroundContactTime),
            HKQuantityType(.runningVerticalOscillation),
            HKCategoryType(.sleepAnalysis),
            HKCategoryType(.appleStandHour),
        ]
        if #available(iOS 18.0, *) {
            types.insert(HKQuantityType(.distanceCrossCountrySkiing))
            types.insert(HKQuantityType(.distanceRowing))
        }
        return types
    }

    /// Visar HealthKits behörighetsdialog (bara för typer som inte frågats om tidigare) och laddar all data.
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

    /// Väcker appen – även i bakgrunden – när ett nytt pass sparas i Hälsa. Anropas vid start
    /// så att frågan finns registrerad när iOS startar appen för att leverera nya data.
    func observeNewWorkouts(_ onUpdate: @escaping @MainActor () async -> Void) {
        guard isHealthDataAvailable, workoutObserver == nil else { return }
        let query = HKObserverQuery(sampleType: HKObjectType.workoutType(), predicate: nil) { _, completionHandler, error in
            guard error == nil else {
                completionHandler()
                return
            }
            Task { @MainActor in
                await onUpdate()
                completionHandler()
            }
        }
        store.execute(query)
        workoutObserver = query
        store.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate) { _, _ in }
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
        async let daily = fetchDailyMetrics()

        self.workouts = try await workouts
        self.metrics = HealthMetrics(
            restingHeartRate: try await resting,
            heartRateVariability: try await hrv,
            vo2Max: try await vo2
        )
        self.samples = try await restingHistory + hrvHistory + vo2History
        self.dailyMetrics = await daily
    }

    private var historyStart: Date {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -Self.historyDays, to: Date()) ?? Date()
        return calendar.startOfDay(for: start)
    }

    private var historyPredicate: NSPredicate {
        HKQuery.predicateForSamples(withStart: historyStart, end: Date())
    }

    private func fetchWorkouts() async throws -> [WorkoutSummary] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(historyPredicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let workouts = try await descriptor.result(for: store)
        let recoveries = (try? await fetchQuantitySamples(.heartRateRecoveryOneMinute)) ?? []

        var result: [WorkoutSummary] = []
        for workout in workouts {
            let buckets = (try? await heartRateBuckets(for: workout)) ?? [:]
            // Klockan mäter pulsåterhämtningen strax efter att passet avslutats.
            let recovery = recoveries.first {
                $0.startDate >= workout.endDate.addingTimeInterval(-300)
                    && $0.startDate <= workout.endDate.addingTimeInterval(1800)
            }?.quantity.doubleValue(for: Self.bpm)
            result.append(WorkoutSummary(workout: workout, heartRateBuckets: buckets, heartRateRecovery: recovery))
        }
        return result
    }

    /// Tid i varje 10-bpm-intervall under passet.
    private func heartRateBuckets(for workout: HKWorkout) async throws -> [Int: Double] {
        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)

        var buckets: [Int: Double] = [:]
        for (index, sample) in samples.enumerated() {
            let value = sample.quantity.doubleValue(for: Self.bpm)
            let span = sample.endDate.timeIntervalSince(sample.startDate)
            let next = index + 1 < samples.count ? samples[index + 1].startDate : workout.endDate
            // Enskilda mätpunkter saknar längd – räkna tiden fram till nästa (högst 30 s).
            let duration = span > 0 ? span : min(next.timeIntervalSince(sample.startDate), 30)
            guard duration > 0 else { continue }
            buckets[Int(value / 10) * 10, default: 0] += duration
        }
        return buckets
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
        try await fetchQuantitySamples(kind.quantityType).map { sample in
            HealthSample(
                id: sample.uuid,
                kind: kind,
                value: sample.quantity.doubleValue(for: kind.unit),
                date: sample.endDate
            )
        }
    }

    private func fetchQuantitySamples(_ identifier: HKQuantityTypeIdentifier) async throws -> [HKQuantitySample] {
        try await fetchQuantitySamples(HKQuantityType(identifier))
    }

    private func fetchQuantitySamples(_ type: HKQuantityType) async throws -> [HKQuantitySample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: historyPredicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)]
        )
        return try await descriptor.result(for: store)
    }

    // MARK: - Dagsvärden

    /// Varje del hämtas för sig; saknas behörighet eller data blir den delen bara tom.
    private func fetchDailyMetrics() async -> [DailyMetrics] {
        let start = historyStart
        async let steps = dailyStatistics(.stepCount, options: .cumulativeSum, unit: .count(), from: start)
        async let energy = dailyStatistics(.activeEnergyBurned, options: .cumulativeSum, unit: .kilocalorie(), from: start)
        async let exercise = dailyStatistics(.appleExerciseTime, options: .cumulativeSum, unit: .minute(), from: start)
        async let respiratory = nightlyAverage(.respiratoryRate, unit: Self.bpm)
        async let temperature = nightlyAverage(.appleSleepingWristTemperature, unit: .degreeCelsius())
        async let stand = standHours()
        async let sleep = sleepNights()

        var days: [Date: DailyMetrics] = [:]
        func update(_ values: [Date: Double]?, _ apply: (inout DailyMetrics, Double) -> Void) {
            for (date, value) in values ?? [:] {
                var day = days[date] ?? DailyMetrics(date: date)
                apply(&day, value)
                days[date] = day
            }
        }
        update(try? await steps) { $0.steps = $1 }
        update(try? await energy) { $0.activeEnergyKcal = $1 }
        update(try? await exercise) { $0.exerciseMinutes = $1 }
        update(try? await respiratory) { $0.respiratoryRate = $1 }
        update(try? await temperature) { $0.wristTemperatureCelsius = $1 }
        update((try? await stand)?.mapValues { Double($0) }) { $0.standHours = Int($1) }
        for (date, night) in (try? await sleep) ?? [:] {
            var day = days[date] ?? DailyMetrics(date: date)
            day.sleep = night
            days[date] = day
        }
        return days.values.sorted { $0.date < $1.date }
    }

    /// Summa eller snitt per dygn.
    private func dailyStatistics(
        _ identifier: HKQuantityTypeIdentifier,
        options: HKStatisticsOptions,
        unit: HKUnit,
        from start: Date
    ) async throws -> [Date: Double] {
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(identifier),
                predicate: HKQuery.predicateForSamples(withStart: start, end: nil)
            ),
            options: options,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)
        var values: [Date: Double] = [:]
        collection.enumerateStatistics(from: start, to: Date()) { statistics, _ in
            let quantity = options.contains(.cumulativeSum) ? statistics.sumQuantity() : statistics.averageQuantity()
            if let quantity {
                values[statistics.startDate] = quantity.doubleValue(for: unit)
            }
        }
        return values
    }

    /// Snitt per natt för värden som mäts under sömnen, räknat till dagen man vaknar.
    private func nightlyAverage(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> [Date: Double] {
        var byNight: [Date: [Double]] = [:]
        for sample in try await fetchQuantitySamples(identifier) {
            byNight[Self.nightKey(for: sample.endDate), default: []].append(sample.quantity.doubleValue(for: unit))
        }
        return byNight.mapValues { $0.reduce(0, +) / Double($0.count) }
    }

    private func standHours() async throws -> [Date: Int] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.appleStandHour), predicate: historyPredicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        var hours: [Date: Int] = [:]
        for sample in try await descriptor.result(for: store)
        where sample.value == HKCategoryValueAppleStandHour.stood.rawValue {
            hours[Calendar.current.startOfDay(for: sample.startDate), default: 0] += 1
        }
        return hours
    }

    /// Sömn per natt. Flera källor (t.ex. klocka och sömnapp) kan registrera samma natt – då
    /// används den källa som registrerat mest sömn, så att inget räknas dubbelt.
    private func sleepNights() async throws -> [Date: SleepNight] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: historyPredicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        var bySource: [Date: [String: SleepNight]] = [:]
        for sample in try await descriptor.result(for: store) {
            guard let stage = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }
            let night = Self.nightKey(for: sample.endDate)
            let source = sample.sourceRevision.source.bundleIdentifier
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60
            var entry = bySource[night]?[source] ?? SleepNight()
            switch stage {
            case .asleepDeep: entry.deep += minutes
            case .asleepREM: entry.rem += minutes
            case .asleepCore: entry.core += minutes
            case .asleepUnspecified: entry.unspecified += minutes
            case .awake: entry.awake += minutes
            default: continue // I sängen men inte sovande.
            }
            bySource[night, default: [:]][source] = entry
        }
        return bySource.compactMapValues { sources in
            sources.values.max { $0.total < $1.total }
        }
    }

    /// Dagen man vaknar: sömn som slutar efter kl. 18 räknas till nästa dag.
    private static func nightKey(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date.addingTimeInterval(6 * 3600))
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
