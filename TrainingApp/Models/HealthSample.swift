import Foundation

/// En enskild hälsomätning från HealthKit (t.ex. en vilopulsmätning).
/// Historiken synkas till Supabase och används av AI-planeraren.
struct HealthSample: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case restingHeartRate = "resting_heart_rate"
        case heartRateVariability = "hrv_sdnn"
        case vo2Max = "vo2_max"

        /// Enhet som värdet lagras i (även i databasen).
        var unitSymbol: String {
            switch self {
            case .restingHeartRate: "count/min"
            case .heartRateVariability: "ms"
            case .vo2Max: "ml/kg*min"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let value: Double
    let date: Date
}
