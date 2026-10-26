import Foundation

/// Nyckeltal för en period: visas i appen och skickas till AI-analysen (Edge Function insights).
struct TrendSnapshot: Encodable, Sendable {
    struct Volume: Encodable, Sendable {
        let minutes: Double
        let previousMinutes: Double
        let sessions: Int
        let previousSessions: Int
        let km: Double
        let previousKm: Double
        let weeklyMinutes: [Int]
    }

    /// Ett hälsomått: senaste värde, snitt senaste veckan, normalintervall och förändring under perioden.
    struct Metric: Encodable, Sendable {
        let unit: String
        let latest: Double?
        let last7DaysAverage: Double?
        let normalLow: Double?
        let normalHigh: Double?
        let periodStartAverage: Double?
        let changeOverPeriod: Double?
    }

    struct Load: Encodable, Sendable {
        let fitness: Double?
        let fatigue: Double?
        let form: Double?
        let fitnessChangeOverPeriod: Double?
        let loadRatio: Double?
    }

    struct Efficiency: Encodable, Sendable {
        let runs: Int
        let metersPerBeatStart: Double?
        let metersPerBeatEnd: Double?
        let changePercent: Double?
    }

    let period: String
    let periodDays: Int
    let volume: Volume
    let vo2Max: Metric
    let restingHeartRate: Metric
    let hrv: Metric
    let sleepHours: Metric
    let load: Load
    let efficiency: Efficiency
}

extension TrendSnapshot {
    @MainActor
    static func make(period: TrendPeriod, health: HealthKitManager) -> TrendSnapshot {
        let calendar = Trends.calendar
        let start = Trends.startDate(of: period)
        let previousStart = calendar.date(byAdding: .day, value: -period.days, to: start) ?? start

        let current = health.workouts.filter { $0.start >= start }
        let previous = health.workouts.filter { $0.start >= previousStart && $0.start < start }
        func km(_ workouts: [WorkoutSummary]) -> Double { workouts.compactMap(\.distanceMeters).reduce(0, +) / 1000 }
        func minutes(_ workouts: [WorkoutSummary]) -> Double { workouts.map(\.duration).reduce(0, +) / 60 }

        let volume = Volume(
            minutes: minutes(current).rounded(),
            previousMinutes: minutes(previous).rounded(),
            sessions: current.count,
            previousSessions: previous.count,
            km: round1(km(current)),
            previousKm: round1(km(previous)),
            weeklyMinutes: Trends.weeklyMinutes(health.workouts, weeks: period.weeks).map { Int($0.value.rounded()) }
        )

        let load = Trends.trainingLoad(health.workouts)
        let latestLoad = load.last
        let startLoad = load.first { $0.date >= start }
        let efficiency = Trends.within(Trends.efficiency(health.workouts), period)
        let efficiencyTrend = Trends.linearTrend(efficiency)

        return TrendSnapshot(
            period: period.rawValue,
            periodDays: period.days,
            volume: volume,
            vo2Max: metric(Trends.daily(health.samples, kind: .vo2Max, using: .mean), unit: "ml/kg/min", period: period),
            restingHeartRate: metric(
                Trends.daily(health.samples, kind: .restingHeartRate, using: .mean), unit: "bpm", period: period
            ),
            hrv: metric(Trends.daily(health.samples, kind: .heartRateVariability, using: .median), unit: "ms", period: period),
            sleepHours: metric(Trends.sleepHours(health.dailyMetrics), unit: "timmar", period: period),
            load: Load(
                fitness: latestLoad.map { round1($0.fitness) },
                fatigue: latestLoad.map { round1($0.fatigue) },
                form: latestLoad.map { round1($0.form) },
                fitnessChangeOverPeriod: latestLoad.flatMap { latest in startLoad.map { round1(latest.fitness - $0.fitness) } },
                loadRatio: Trends.loadRatio(health.workouts).map(round2)
            ),
            efficiency: Efficiency(
                runs: efficiency.count,
                metersPerBeatStart: efficiencyTrend.first.map { round2($0.value) },
                metersPerBeatEnd: efficiencyTrend.last.map { round2($0.value) },
                changePercent: efficiencyTrend.count == 2
                    ? Trends.percentChange(efficiencyTrend[1].value, efficiencyTrend[0].value).map(round1)
                    : nil
            )
        )
    }

    private static func metric(_ points: [TrendPoint], unit: String, period: TrendPeriod) -> Metric {
        let inPeriod = Trends.within(points, period)
        let baseline = Trends.baseline(points)
        let recent = Trends.recentAverage(points)
        let startAverage = inPeriod.prefix(7).map(\.value).average
        return Metric(
            unit: unit,
            latest: points.last.map { round1($0.value) },
            last7DaysAverage: recent.map(round1),
            normalLow: baseline.map { round1($0.low) },
            normalHigh: baseline.map { round1($0.high) },
            periodStartAverage: startAverage.map(round1),
            changeOverPeriod: recent.flatMap { r in startAverage.map { round1(r - $0) } }
        )
    }

    private static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
