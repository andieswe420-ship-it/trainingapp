import Foundation

/// Dagliga värden från Hälsa. Sömn räknas till dagen man vaknar.
struct DailyMetrics: Identifiable, Hashable, Sendable {
    /// Dygnets start (lokal tid).
    let date: Date
    var steps: Double?
    var activeEnergyKcal: Double?
    var exerciseMinutes: Double?
    var standHours: Int?
    var sleep: SleepNight?
    var respiratoryRate: Double?
    var wristTemperatureCelsius: Double?

    var id: Date { date }

    init(date: Date) {
        self.date = date
    }
}

/// En natts sömn i minuter per fas.
struct SleepNight: Hashable, Sendable {
    var deep: Double = 0
    var rem: Double = 0
    var core: Double = 0
    /// Sömn utan fasinformation (äldre klockor eller andra appar).
    var unspecified: Double = 0
    var awake: Double = 0

    var total: Double { deep + rem + core + unspecified }
}
