import Foundation

/// Bestående information som både coachen och planeraren följer (tabellen `athlete_profiles`).
struct AthleteProfile: Codable, Equatable, Sendable {
    enum Weekday: String, CaseIterable, Identifiable, Sendable {
        case monday, tuesday, wednesday, thursday, friday, saturday, sunday

        var id: String { rawValue }

        var swedishName: String {
            switch self {
            case .monday: "Måndag"
            case .tuesday: "Tisdag"
            case .wednesday: "Onsdag"
            case .thursday: "Torsdag"
            case .friday: "Fredag"
            case .saturday: "Lördag"
            case .sunday: "Söndag"
            }
        }
    }

    var goals = ""
    /// Vad varje veckodag ska innehålla, nyckel = `Weekday.rawValue`. Saknad dag = flexibel.
    var weeklySchedule: [String: String] = [:]
    var limitations = ""
    var notes = ""
    var updatedAt: Date?

    static let empty = AthleteProfile()

    enum CodingKeys: String, CodingKey {
        case goals, limitations, notes
        case weeklySchedule = "weekly_schedule"
        case updatedAt = "updated_at"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goals = try container.decodeIfPresent(String.self, forKey: .goals) ?? ""
        weeklySchedule = try container.decodeIfPresent([String: String].self, forKey: .weeklySchedule) ?? [:]
        limitations = try container.decodeIfPresent(String.self, forKey: .limitations) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// `user_id` sätts av databasen. Tomma fält sparas som null.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.nonEmpty(goals), forKey: .goals)
        try container.encode(Self.nonEmpty(limitations), forKey: .limitations)
        try container.encode(Self.nonEmpty(notes), forKey: .notes)
        try container.encode(
            weeklySchedule.compactMapValues { Self.nonEmpty($0) },
            forKey: .weeklySchedule
        )
        try container.encode(Date(), forKey: .updatedAt)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
