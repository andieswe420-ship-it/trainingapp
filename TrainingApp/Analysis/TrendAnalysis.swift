import Foundation

/// Tidsperiod i Trender-fliken.
enum TrendPeriod: String, CaseIterable, Identifiable, Sendable {
    case fourWeeks = "4w"
    case threeMonths = "3m"
    case sixMonths = "6m"

    var id: String { rawValue }
    var days: Int {
        switch self {
        case .fourWeeks: 28
        case .threeMonths: 91
        case .sixMonths: 182
        }
    }
    var weeks: Int { days / 7 }
    var label: String {
        switch self {
        case .fourWeeks: "4 veckor"
        case .threeMonths: "3 månader"
        case .sixMonths: "6 månader"
        }
    }
}

struct TrendPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Personens normala nivå: snitt ± en standardavvikelse.
struct Baseline: Hashable, Sendable {
    let mean: Double
    let low: Double
    let high: Double

    func contains(_ value: Double) -> Bool { value >= low && value <= high }
}

/// Kondition (långsiktig belastning), trötthet (senaste veckan) och form (skillnaden) per dag.
struct LoadPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let fitness: Double
    let fatigue: Double
    var form: Double { fitness - fatigue }
    var id: Date { date }
}

/// Beräkningar för Trender. Allt räknas lokalt från datan i Hälsa.
enum Trends {
    enum Aggregation { case mean, median }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    static func startDate(of period: TrendPeriod, from now: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: -period.days, to: calendar.startOfDay(for: now)) ?? now
    }

    static func within(_ points: [TrendPoint], _ period: TrendPeriod) -> [TrendPoint] {
        let start = startDate(of: period)
        return points.filter { $0.date >= start }
    }

    // MARK: Serier

    /// Minuter per vecka (måndag–söndag), även veckor utan pass.
    static func weeklyMinutes(_ workouts: [WorkoutSummary], weeks: Int) -> [TrendPoint] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        var minutes: [Date: Double] = [:]
        for workout in workouts {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: workout.start)?.start else { continue }
            minutes[week, default: 0] += workout.duration / 60
        }
        return (0..<weeks).reversed().compactMap { offset in
            guard let week = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek) else { return nil }
            return TrendPoint(date: week, value: minutes[week] ?? 0)
        }
    }

    static func daily(_ samples: [HealthSample], kind: HealthSample.Kind, using aggregation: Aggregation) -> [TrendPoint] {
        var byDay: [Date: [Double]] = [:]
        for sample in samples where sample.kind == kind {
            byDay[calendar.startOfDay(for: sample.date), default: []].append(sample.value)
        }
        return byDay.compactMap { day, values in
            let value = aggregation == .mean ? values.average : values.median
            return value.map { TrendPoint(date: day, value: $0) }
        }
        .sorted { $0.date < $1.date }
    }

    static func rollingAverage(_ points: [TrendPoint], days: Int) -> [TrendPoint] {
        points.compactMap { point in
            guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: point.date) else { return nil }
            let window = points.filter { $0.date >= start && $0.date <= point.date }.map(\.value)
            return window.average.map { TrendPoint(date: point.date, value: $0) }
        }
    }

    static func sleepHours(_ days: [DailyMetrics]) -> [TrendPoint] {
        days.compactMap { day in
            guard let total = day.sleep?.total, total > 0 else { return nil }
            return TrendPoint(date: day.date, value: total / 60)
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: Normalintervall

    /// Normalintervall från dag 8–67 bakåt, så att senaste veckan kan jämföras mot det.
    static func baseline(_ points: [TrendPoint]) -> Baseline? {
        let today = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: -7, to: today),
              let start = calendar.date(byAdding: .day, value: -67, to: today) else { return nil }
        let values = points.filter { $0.date >= start && $0.date < end }.map(\.value)
        guard values.count >= 10, let mean = values.average else { return nil }
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        let sd = max(variance.squareRoot(), abs(mean) * 0.02)
        return Baseline(mean: mean, low: mean - sd, high: mean + sd)
    }

    static func recentAverage(_ points: [TrendPoint], days: Int = 7) -> Double? {
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date())) else {
            return nil
        }
        return points.filter { $0.date >= start }.map(\.value).average
    }

    // MARK: Form och belastning

    /// Högsta uppmätta puls i passen, som uppskattning av maxpuls.
    static func maxHeartRate(_ workouts: [WorkoutSummary]) -> Double {
        workouts.compactMap(\.maxHeartRate).max() ?? 190
    }

    /// Belastning för ett pass (TRIMP enligt Edwards): minuter i varje pulszon × zonens vikt 1–5.
    static func trimp(_ workout: WorkoutSummary, maxHeartRate: Double) -> Double {
        func weight(_ bpm: Double) -> Double {
            switch bpm / maxHeartRate {
            case ..<0.5: 0
            case ..<0.6: 1
            case ..<0.7: 2
            case ..<0.8: 3
            case ..<0.9: 4
            default: 5
            }
        }
        if !workout.heartRateBuckets.isEmpty {
            return workout.heartRateBuckets.reduce(0) { total, bucket in
                total + bucket.value / 60 * weight(Double(bucket.key) + 5)
            }
        }
        // Utan pulsfördelning: hela passet i snittpulsens zon.
        guard let average = workout.averageHeartRate else { return 0 }
        return workout.duration / 60 * weight(average)
    }

    /// Daglig kondition (42-dagars viktat snitt av belastningen) och trötthet (7-dagars).
    static func trainingLoad(_ workouts: [WorkoutSummary]) -> [LoadPoint] {
        guard let first = workouts.map(\.start).min() else { return [] }
        let maxHR = maxHeartRate(workouts)
        var dailyLoad: [Date: Double] = [:]
        for workout in workouts {
            dailyLoad[calendar.startOfDay(for: workout.start), default: 0] += trimp(workout, maxHeartRate: maxHR)
        }

        var points: [LoadPoint] = []
        var fitness = 0.0
        var fatigue = 0.0
        var day = calendar.startOfDay(for: first)
        let today = calendar.startOfDay(for: Date())
        while day <= today {
            let load = dailyLoad[day] ?? 0
            fitness += (load - fitness) / 42
            fatigue += (load - fatigue) / 7
            points.append(LoadPoint(date: day, fitness: fitness, fatigue: fatigue))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return points
    }

    /// Senaste veckans belastning jämfört med snittet per vecka de senaste fyra veckorna.
    static func loadRatio(_ workouts: [WorkoutSummary]) -> Double? {
        let maxHR = maxHeartRate(workouts)
        let today = calendar.startOfDay(for: Date())
        guard let weekStart = calendar.date(byAdding: .day, value: -6, to: today),
              let monthStart = calendar.date(byAdding: .day, value: -27, to: today) else { return nil }
        let acute = workouts.filter { $0.start >= weekStart }.reduce(0) { $0 + trimp($1, maxHeartRate: maxHR) }
        let chronic = workouts.filter { $0.start >= monthStart }.reduce(0) { $0 + trimp($1, maxHeartRate: maxHR) } / 4
        return chronic > 0 ? acute / chronic : nil
    }

    // MARK: Aerob effektivitet

    /// Meter per hjärtslag i löppass på minst 2 km – högre betyder bättre aerob kondition.
    static func efficiency(_ workouts: [WorkoutSummary]) -> [TrendPoint] {
        workouts.compactMap { workout in
            guard workout.activityType == .running,
                  let distance = workout.distanceMeters, distance >= 2000,
                  let heartRate = workout.averageHeartRate, heartRate >= 90 else { return nil }
            let beats = workout.duration / 60 * heartRate
            return TrendPoint(date: workout.start, value: distance / beats)
        }
        .sorted { $0.date < $1.date }
    }

    /// Rak trendlinje (minsta kvadrat) genom punkterna: värdet vid första och sista datumet.
    static func linearTrend(_ points: [TrendPoint]) -> [TrendPoint] {
        guard points.count >= 3, let first = points.first, let last = points.last, first.date < last.date else { return [] }
        let xs = points.map { $0.date.timeIntervalSince(first.date) }
        let ys = points.map(\.value)
        guard let mx = xs.average, let my = ys.average else { return [] }
        let sxx = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        guard sxx > 0 else { return [] }
        let slope = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / sxx
        let at = { (x: TimeInterval) in my + slope * (x - mx) }
        return [
            TrendPoint(date: first.date, value: at(0)),
            TrendPoint(date: last.date, value: at(last.date.timeIntervalSince(first.date))),
        ]
    }

    // MARK: Text

    static func number(_ value: Double, decimals: Int) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).locale(Locale(identifier: "sv_SE")))
    }

    static func signed(_ value: Double, decimals: Int) -> String {
        (value >= 0 ? "+" : "−") + number(abs(value), decimals: decimals)
    }

    static func hoursText(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func percentChange(_ current: Double, _ previous: Double) -> Double? {
        previous > 0 ? (current - previous) / previous * 100 : nil
    }
}

extension Collection where Element == Double {
    var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }

    var median: Double? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
