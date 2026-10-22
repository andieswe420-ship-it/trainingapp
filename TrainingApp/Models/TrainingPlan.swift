import Foundation

/// En rad i tabellen `training_plans`. Skapas av Edge Function `plan-week`.
struct TrainingPlan: Decodable, Identifiable, Hashable, Sendable {
    enum Status: String, Decodable, Sendable {
        case pending, ready, failed
    }

    let id: UUID
    let status: Status
    let startDate: String
    let endDate: String
    let notes: String?
    let plan: PlanContent?
    let error: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status, notes, plan, error
        case startDate = "start_date"
        case endDate = "end_date"
        case createdAt = "created_at"
    }

    /// Alla dagar i perioden (YYYY-MM-DD), även vilodagar.
    var days: [String] {
        guard let start = PlanDate.date(from: startDate), let end = PlanDate.date(from: endDate) else { return [] }
        var result: [String] = []
        var day = start
        while day <= end {
            result.append(PlanDate.string(from: day))
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

/// Planens innehåll – formatet är gjort för att översättas till WorkoutKit (fas 4).
struct PlanContent: Decodable, Hashable, Sendable {
    enum Readiness: String, Decodable, Sendable {
        case recover, maintain, build

        var label: String {
            switch self {
            case .recover: "Återhämtning"
            case .maintain: "Bibehåll"
            case .build: "Bygg"
            }
        }

        var symbolName: String {
            switch self {
            case .recover: "battery.25percent"
            case .maintain: "battery.75percent"
            case .build: "arrow.up.right.circle"
            }
        }
    }

    let summary: String
    let readiness: Readiness
    let readinessExplanation: String
    let weeklyFocus: String
    let workouts: [PlannedWorkout]
    let restDayNotes: String

    enum CodingKeys: String, CodingKey {
        case summary, readiness, workouts
        case readinessExplanation = "readiness_explanation"
        case weeklyFocus = "weekly_focus"
        case restDayNotes = "rest_day_notes"
    }
}

struct PlannedWorkout: Decodable, Hashable, Identifiable, Sendable {
    enum Activity: String, Decodable, Sendable {
        case running, walking, cycling, hiit, strength, mobility

        var swedishName: String {
            switch self {
            case .running: "Löpning"
            case .walking: "Promenad"
            case .cycling: "Cykling"
            case .hiit: "HIIT"
            case .strength: "Styrka"
            case .mobility: "Rörlighet"
            }
        }

        var symbolName: String {
            switch self {
            case .running: "figure.run"
            case .walking: "figure.walk"
            case .cycling: "figure.outdoor.cycle"
            case .hiit: "figure.highintensity.intervaltraining"
            case .strength: "figure.strengthtraining.traditional"
            case .mobility: "figure.flexibility"
            }
        }
    }

    enum Location: String, Decodable, Sendable {
        case outdoor, indoor
    }

    enum Intensity: String, Decodable, Sendable {
        case easy, moderate, hard

        var label: String {
            switch self {
            case .easy: "Lätt"
            case .moderate: "Medel"
            case .hard: "Hårt"
            }
        }
    }

    let date: String
    let activity: Activity
    let location: Location
    let title: String
    let description: String
    let intensity: Intensity
    let estimatedMinutes: Double
    let warmupMinutes: Double
    let cooldownMinutes: Double
    let blocks: [PlanBlock]

    var id: String { "\(date)-\(title)" }

    enum CodingKeys: String, CodingKey {
        case date, activity, location, title, description, intensity, blocks
        case estimatedMinutes = "estimated_minutes"
        case warmupMinutes = "warmup_minutes"
        case cooldownMinutes = "cooldown_minutes"
    }
}

struct PlanBlock: Decodable, Hashable, Sendable {
    let iterations: Double
    let steps: [PlanStep]
}

struct PlanStep: Decodable, Hashable, Sendable {
    enum Purpose: String, Decodable, Sendable { case work, recovery }
    enum GoalType: String, Decodable, Sendable { case time, distance, open }
    enum TargetType: String, Decodable, Sendable {
        case none
        case heartRateZone = "heart_rate_zone"
        case heartRateRange = "heart_rate_range"
        case pace
    }

    let purpose: Purpose
    let goalType: GoalType
    /// Sekunder (time) eller meter (distance).
    let goalValue: Double
    let targetType: TargetType
    let targetLow: Double
    let targetHigh: Double
    let description: String

    enum CodingKeys: String, CodingKey {
        case purpose, description
        case goalType = "goal_type"
        case goalValue = "goal_value"
        case targetType = "target_type"
        case targetLow = "target_low"
        case targetHigh = "target_high"
    }
}

/// Planens datum är strängar (YYYY-MM-DD) i svensk tid.
enum PlanDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Stockholm")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(from string: String) -> Date? { formatter.date(from: string) }
    static func string(from date: Date) -> String { formatter.string(from: date) }
}
