import Foundation

/// Rad i tabellen `workouts`. `user_id` sätts av databasen (default auth.uid()).
struct WorkoutRecord: Encodable, Sendable {
    let id: UUID
    let activityType: Int
    let activityName: String
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Double
    let avgHeartRate: Double?
    let distanceMeters: Double?
    let activeEnergyKcal: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case activityType = "activity_type"
        case activityName = "activity_name"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case avgHeartRate = "avg_heart_rate"
        case distanceMeters = "distance_meters"
        case activeEnergyKcal = "active_energy_kcal"
    }

    init(_ workout: WorkoutSummary) {
        id = workout.id
        activityType = Int(workout.activityType.rawValue)
        activityName = workout.activityName
        startedAt = workout.start
        endedAt = workout.end
        durationSeconds = workout.duration
        avgHeartRate = workout.averageHeartRate
        distanceMeters = workout.distanceMeters
        activeEnergyKcal = workout.activeEnergyKcal
    }
}

/// Rad i tabellen `health_samples`.
struct HealthSampleRecord: Encodable, Sendable {
    let id: UUID
    let kind: String
    let value: Double
    let unit: String
    let measuredAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, value, unit
        case measuredAt = "measured_at"
    }

    init(_ sample: HealthSample) {
        id = sample.id
        kind = sample.kind.rawValue
        value = sample.value
        unit = sample.kind.unitSymbol
        measuredAt = sample.date
    }
}
