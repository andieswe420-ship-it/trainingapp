import Foundation

/// Senaste värdet för en hälsomätning.
struct MetricSample: Hashable, Sendable {
    let value: Double
    let date: Date
}

/// Återhämtnings- och konditionsmått som AI-planeraren senare använder.
struct HealthMetrics: Hashable, Sendable {
    /// Vilopuls, slag/min.
    var restingHeartRate: MetricSample?
    /// HRV (SDNN), millisekunder.
    var heartRateVariability: MetricSample?
    /// VO2 max, ml/(kg·min).
    var vo2Max: MetricSample?

    static let empty = HealthMetrics()
}
