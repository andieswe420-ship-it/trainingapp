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
    let maxHeartRate: Double?
    let distanceMeters: Double?
    let activeEnergyKcal: Double?
    let heartRateRecovery1min: Double?
    /// Sekunder per 10-bpm-intervall, t.ex. ["140": 900].
    let heartRateBuckets: [String: Double]?
    let runningPowerWatts: Double?
    let strideLengthMeters: Double?
    let groundContactMs: Double?
    let verticalOscillationCm: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case activityType = "activity_type"
        case activityName = "activity_name"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case avgHeartRate = "avg_heart_rate"
        case maxHeartRate = "max_heart_rate"
        case distanceMeters = "distance_meters"
        case activeEnergyKcal = "active_energy_kcal"
        case heartRateRecovery1min = "heart_rate_recovery_1min"
        case heartRateBuckets = "heart_rate_buckets"
        case runningPowerWatts = "running_power_watts"
        case strideLengthMeters = "stride_length_meters"
        case groundContactMs = "ground_contact_ms"
        case verticalOscillationCm = "vertical_oscillation_cm"
    }

    init(_ workout: WorkoutSummary) {
        id = workout.id
        activityType = Int(workout.activityType.rawValue)
        activityName = workout.activityName
        startedAt = workout.start
        endedAt = workout.end
        durationSeconds = workout.duration
        avgHeartRate = workout.averageHeartRate
        maxHeartRate = workout.maxHeartRate
        distanceMeters = workout.distanceMeters
        activeEnergyKcal = workout.activeEnergyKcal
        heartRateRecovery1min = workout.heartRateRecovery
        heartRateBuckets = workout.heartRateBuckets.isEmpty
            ? nil
            : Dictionary(uniqueKeysWithValues: workout.heartRateBuckets.map { (String($0.key), $0.value.rounded()) })
        runningPowerWatts = workout.runningPowerWatts
        strideLengthMeters = workout.strideLengthMeters
        groundContactMs = workout.groundContactMs
        verticalOscillationCm = workout.verticalOscillationCm
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

/// Rad i tabellen `daily_metrics`. Primärnyckel (user_id, date).
struct DailyMetricsRecord: Encodable, Sendable {
    let date: String
    let steps: Int?
    let activeEnergyKcal: Double?
    let exerciseMinutes: Double?
    let standHours: Int?
    let sleepTotalMinutes: Double?
    let sleepDeepMinutes: Double?
    let sleepRemMinutes: Double?
    let sleepCoreMinutes: Double?
    let sleepAwakeMinutes: Double?
    let respiratoryRate: Double?
    let wristTemperatureCelsius: Double?

    enum CodingKeys: String, CodingKey {
        case date, steps
        case activeEnergyKcal = "active_energy_kcal"
        case exerciseMinutes = "exercise_minutes"
        case standHours = "stand_hours"
        case sleepTotalMinutes = "sleep_total_minutes"
        case sleepDeepMinutes = "sleep_deep_minutes"
        case sleepRemMinutes = "sleep_rem_minutes"
        case sleepCoreMinutes = "sleep_core_minutes"
        case sleepAwakeMinutes = "sleep_awake_minutes"
        case respiratoryRate = "respiratory_rate"
        case wristTemperatureCelsius = "wrist_temperature_celsius"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(_ day: DailyMetrics) {
        date = Self.dateFormatter.string(from: day.date)
        steps = day.steps.map { Int($0.rounded()) }
        activeEnergyKcal = day.activeEnergyKcal
        exerciseMinutes = day.exerciseMinutes
        standHours = day.standHours
        sleepTotalMinutes = day.sleep?.total
        sleepDeepMinutes = day.sleep?.deep
        sleepRemMinutes = day.sleep?.rem
        sleepCoreMinutes = day.sleep?.core
        sleepAwakeMinutes = day.sleep?.awake
        respiratoryRate = day.respiratoryRate
        wristTemperatureCelsius = day.wristTemperatureCelsius
    }
}
