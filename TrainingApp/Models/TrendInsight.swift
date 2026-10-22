import Foundation

/// En rad i tabellen `trend_insights` – AI-analysen för en dag och period.
struct TrendInsight: Decodable, Identifiable, Sendable {
    enum Status: String, Decodable, Sendable { case pending, ready, failed }

    let id: UUID
    let status: Status
    let content: Content?
    let error: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status, content, error
        case updatedAt = "updated_at"
    }

    struct Content: Decodable, Sendable {
        let overall: String
        let cards: [Card]
        let patterns: [String]

        func card(_ key: CardKey) -> Card? { cards.first { $0.key == key } }
    }

    struct Card: Decodable, Sendable {
        let key: CardKey
        let headline: String
        let comment: String
        let status: CardStatus
    }

    enum CardKey: String, Decodable, Sendable {
        case volume, vo2max, hrv, sleep, load, efficiency
        case restingHR = "resting_hr"
    }

    enum CardStatus: String, Decodable, Sendable { case positive, neutral, attention }
}
