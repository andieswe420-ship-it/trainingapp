import Foundation

/// Ett färdigt AI-svar (coach, veckoplan eller trendanalys) från vyn `ai_usage`.
struct AIUsage: Decodable, Hashable, Sendable {
    enum Kind: String, Decodable, Sendable, CaseIterable {
        case coach, plan, insight

        var label: String {
            switch self {
            case .coach: "Coach"
            case .plan: "Veckoplaner"
            case .insight: "Trendanalys"
            }
        }
    }

    let kind: Kind
    let createdAt: Date
    let model: String?
    /// Koldioxidutsläpp i gram enligt Berget AI; nil om leverantören inte mäter det.
    let co2Grams: Double?

    enum CodingKeys: String, CodingKey {
        case kind, model
        case createdAt = "created_at"
        case co2Grams = "co2_grams"
    }
}

extension [AIUsage] {
    var totalCO2: Double { compactMap(\.co2Grams).reduce(0, +) }
    var measuredCount: Int { filter { $0.co2Grams != nil }.count }
}

/// "0,78 g" eller "783 mg" för små mängder.
func formatCO2(_ grams: Double) -> String {
    grams < 1
        ? "\(Int((grams * 1000).rounded())) mg"
        : grams.formatted(.number.precision(.fractionLength(grams < 10 ? 1 : 0))) + " g"
}
