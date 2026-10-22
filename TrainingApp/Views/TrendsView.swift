import Charts
import SwiftUI

/// Trender över tid, beräknade från datan i Hälsa (ingen server behövs).
struct TrendsView: View {
    @Environment(HealthKitManager.self) private var health

    var body: some View {
        NavigationStack {
            Group {
                if health.workouts.isEmpty && health.samples.isEmpty {
                    ContentUnavailableView(
                        "Inga trender än",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Trenderna visas när appen har läst din data från Hälsa.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            weeklyVolume
                            vo2Max
                            restingHeartRate
                            heartRateVariability
                            sleep
                        }
                        .padding()
                    }
                    .refreshable { await health.refresh() }
                }
            }
            .navigationTitle("Trender")
        }
    }

    // MARK: - Diagram

    private var weeklyVolume: some View {
        let weeks = Trends.weeklyMinutes(health.workouts, weeks: 12)
        let average = weeks.dropLast().suffix(4).map(\.value).average
        return TrendCard(
            title: "Träningstid per vecka",
            summary: average.map { "Snitt senaste 4 veckorna: \(Int($0.rounded())) min" }
        ) {
            Chart(weeks) { week in
                BarMark(
                    x: .value("Vecka", week.date, unit: .weekOfYear),
                    y: .value("Minuter", week.value)
                )
                .foregroundStyle(Color.accentColor.gradient)
            }
            .chartYAxisLabel("min")
        }
    }

    private var vo2Max: some View {
        let points = Trends.daily(health.samples, kind: .vo2Max, using: .mean)
        return TrendCard(title: "VO2 max", summary: Trends.changeText(points, unit: "", decimals: 1)) {
            Chart(points) { point in
                LineMark(x: .value("Datum", point.date, unit: .day), y: .value("VO2 max", point.value))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Datum", point.date, unit: .day), y: .value("VO2 max", point.value))
                    .symbolSize(20)
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    private var restingHeartRate: some View {
        let points = Trends.daily(health.samples, kind: .restingHeartRate, using: .mean)
        return TrendCard(title: "Vilopuls", summary: Trends.changeText(points, unit: " bpm", decimals: 0)) {
            Chart(points) { point in
                LineMark(x: .value("Datum", point.date, unit: .day), y: .value("Vilopuls", point.value))
                    .foregroundStyle(.red)
                    .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    private var heartRateVariability: some View {
        // HRV mäts många gånger per dygn – visa dagsmedian och ett rullande 7-dagarssnitt.
        let points = Trends.daily(health.samples, kind: .heartRateVariability, using: .median)
        let rolling = Trends.rollingAverage(points, days: 7)
        return TrendCard(title: "Pulsvariabilitet (HRV)", summary: Trends.changeText(rolling, unit: " ms", decimals: 0)) {
            Chart {
                ForEach(points) { point in
                    PointMark(x: .value("Datum", point.date, unit: .day), y: .value("HRV", point.value))
                        .symbolSize(12)
                        .foregroundStyle(.purple.opacity(0.35))
                }
                ForEach(rolling) { point in
                    LineMark(x: .value("Datum", point.date, unit: .day), y: .value("7-dagarssnitt", point.value))
                        .foregroundStyle(.purple)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    private var sleep: some View {
        let nights = Trends.sleepHours(health.dailyMetrics, days: 30)
        let average = nights.map(\.value).average
        return TrendCard(
            title: "Sömn senaste 30 nätterna",
            summary: average.map { "Snitt: \(Trends.hoursText($0)) per natt" }
        ) {
            Chart {
                ForEach(nights) { night in
                    BarMark(x: .value("Natt", night.date, unit: .day), y: .value("Timmar", night.value))
                        .foregroundStyle(.indigo.gradient)
                }
                if let average {
                    RuleMark(y: .value("Snitt", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxisLabel("h")
        }
    }
}

/// Ett kort med rubrik, sammanfattning och diagram.
private struct TrendCard<Content: View>: View {
    let title: String
    let summary: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if let summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            content
                .frame(height: 180)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct TrendPoint: Identifiable, Hashable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Beräkningar för diagrammen.
enum Trends {
    enum Aggregation { case mean, median }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

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

    static func sleepHours(_ days: [DailyMetrics], days count: Int) -> [TrendPoint] {
        guard let start = calendar.date(byAdding: .day, value: -count, to: calendar.startOfDay(for: Date())) else { return [] }
        return days
            .filter { $0.date >= start }
            .compactMap { day in
                guard let total = day.sleep?.total, total > 0 else { return nil }
                return TrendPoint(date: day.date, value: total / 60)
            }
    }

    /// "Senast 53,7 (+2,1 senaste 60 dagarna)".
    static func changeText(_ points: [TrendPoint], unit: String, decimals: Int) -> String? {
        guard let latest = points.last else { return nil }
        let format = "%.\(decimals)f"
        var text = "Senast \(String(format: format, latest.value))\(unit)"
        if let cutoff = calendar.date(byAdding: .day, value: -60, to: latest.date),
           let earlier = points.first(where: { $0.date >= cutoff }), earlier.date < latest.date {
            let change = latest.value - earlier.value
            text += " (\(change >= 0 ? "+" : "")\(String(format: format, change)) senaste 60 dagarna)"
        }
        return text
    }

    static func hoursText(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

private extension Collection where Element == Double {
    var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }

    var median: Double? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
