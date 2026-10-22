import Foundation
import HealthKit

/// Appens egen, HealthKit-oberoende representation av ett träningspass.
/// Denna struktur är också payload vid synk till Supabase.
struct WorkoutSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let activityType: HKWorkoutActivityType
    let start: Date
    let end: Date
    let duration: TimeInterval
    /// Snittpuls i slag/min, om pulsdata finns.
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    /// Total distans i meter, om relevant.
    let distanceMeters: Double?
    /// Aktiv energi i kcal.
    let activeEnergyKcal: Double?
    /// Pulsens fall första minuten efter passet (slag), om klockan mätt det.
    let heartRateRecovery: Double?
    /// Sekunder per 10-bpm-intervall, nyckel = intervallets nedre gräns (t.ex. 140 = 140-149).
    let heartRateBuckets: [Int: Double]
    // Löpdynamik (snitt), bara för löppass med Apple Watch.
    let runningPowerWatts: Double?
    let strideLengthMeters: Double?
    let groundContactMs: Double?
    let verticalOscillationCm: Double?

    var activityName: String { activityType.swedishName }
    var symbolName: String { activityType.symbolName }
}

extension WorkoutSummary {
    init(workout: HKWorkout, heartRateBuckets: [Int: Double], heartRateRecovery: Double?) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let heartRate = workout.statistics(for: HKQuantityType(.heartRate))

        func average(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
            workout.statistics(for: HKQuantityType(identifier))?.averageQuantity()?.doubleValue(for: unit)
        }

        let distance = Self.distanceType(for: workout.workoutActivityType).flatMap { workout.statistics(for: $0)?.sumQuantity() }?
            .doubleValue(for: .meter())

        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie())

        self.init(
            id: workout.uuid,
            activityType: workout.workoutActivityType,
            start: workout.startDate,
            end: workout.endDate,
            duration: workout.duration,
            averageHeartRate: heartRate?.averageQuantity()?.doubleValue(for: bpm),
            maxHeartRate: heartRate?.maximumQuantity()?.doubleValue(for: bpm),
            distanceMeters: distance,
            activeEnergyKcal: energy,
            heartRateRecovery: heartRateRecovery,
            heartRateBuckets: heartRateBuckets,
            runningPowerWatts: average(.runningPower, .watt()),
            strideLengthMeters: average(.runningStrideLength, .meter()),
            groundContactMs: average(.runningGroundContactTime, .secondUnit(with: .milli)),
            verticalOscillationCm: average(.runningVerticalOscillation, .meterUnit(with: .centi))
        )
    }

    /// Distanstypen som hör till en aktivitet. Längdskidor och rodd har egna typer först i iOS 18.
    private static func distanceType(for activity: HKWorkoutActivityType) -> HKQuantityType? {
        switch activity {
        case .running, .walking, .hiking:
            return HKQuantityType(.distanceWalkingRunning)
        case .cycling:
            return HKQuantityType(.distanceCycling)
        case .swimming:
            return HKQuantityType(.distanceSwimming)
        case .crossCountrySkiing:
            if #available(iOS 18.0, *) { return HKQuantityType(.distanceCrossCountrySkiing) }
            return nil
        case .rowing:
            if #available(iOS 18.0, *) { return HKQuantityType(.distanceRowing) }
            return nil
        default:
            return nil
        }
    }
}
