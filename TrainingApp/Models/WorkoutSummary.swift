import Foundation
import HealthKit

/// Appens egen, HealthKit-oberoende representation av ett träningspass.
/// Denna struktur är också tänkt att bli payload vid synk till Supabase (fas 2).
struct WorkoutSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let activityType: HKWorkoutActivityType
    let start: Date
    let end: Date
    let duration: TimeInterval
    /// Snittpuls i slag/min, om pulsdata finns.
    let averageHeartRate: Double?
    /// Total distans i meter, om relevant.
    let distanceMeters: Double?
    /// Aktiv energi i kcal.
    let activeEnergyKcal: Double?

    var activityName: String { activityType.swedishName }
    var symbolName: String { activityType.symbolName }
}

extension WorkoutSummary {
    init(workout: HKWorkout) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let heartRate = workout.statistics(for: HKQuantityType(.heartRate))?
            .averageQuantity()?
            .doubleValue(for: bpm)

        let distanceType: HKQuantityType? = switch workout.workoutActivityType {
        case .running, .walking, .hiking: HKQuantityType(.distanceWalkingRunning)
        case .cycling: HKQuantityType(.distanceCycling)
        case .swimming: HKQuantityType(.distanceSwimming)
        case .crossCountrySkiing: HKQuantityType(.distanceCrossCountrySkiing)
        case .rowing: HKQuantityType(.distanceRowing)
        default: nil
        }
        let distance = distanceType.flatMap { workout.statistics(for: $0)?.sumQuantity() }?
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
            averageHeartRate: heartRate,
            distanceMeters: distance,
            activeEnergyKcal: energy
        )
    }
}
