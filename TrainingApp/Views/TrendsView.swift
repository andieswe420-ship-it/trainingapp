import Charts
import SwiftUI

/// Trender över tid med AI-analys, normalintervall, form/belastning och aerob effektivitet.
struct TrendsView: View {
    @Environment(HealthKitManager.self) private var health
    @Environment(SyncService.self) private var sync
    @Environment(InsightStore.self) private var insights
    @Environment(CoachStore.self) private var coach

    @AppStorage("trendPeriod") private var periodRaw = TrendPeriod.threeMonths.rawValue

    private var period: TrendPeriod { TrendPeriod(rawValue: periodRaw) ?? .threeMonths }
    private var insight: TrendInsight.Content? { insights.insights[period]?.content }

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
                            Picker("Period", selection: $periodRaw) {
                                ForEach(TrendPeriod.allCases) { Text($0.label).tag($0.rawValue) }
                            }
                            .pickerStyle(.segmented)

                            analysisCard
                            comparisonCard
                            volumeCard
                            loadCard
                            efficiencyCard
                            vo2Card
                            restingHeartRateCard
                            hrvCard
                            sleepCard
                        }
                        .padding()
                    }
                    .refreshable { await health.refresh() }
                }
            }
            .navigationTitle("Trender")
        }
        .task(id: TaskKey(period: period, loaded: health.state == .loaded, user: sync.userEmail)) {
            guard health.state == .loaded else { return }
            await insights.load(period, snapshot: TrendSnapshot.make(period: period, health: health))
        }
    }

    private struct TaskKey: Equatable {
        let period: TrendPeriod
        let loaded: Bool
        let user: String?
    }

    private func ask(_ question: String) {
        coach.prefill = question
        AppRouter.shared.selectedTab = .coach
    }

    // MARK: - Analys och jämförelse

    @ViewBuilder
    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Coachens analys", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if insights.loading.contains(period) {
                    ProgressView()
                } else if sync.isSignedIn {
                    Button {
                        Task {
                            await insights.load(period, snapshot: TrendSnapshot.make(period: period, health: health), force: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Uppdatera analysen")
                }
            }

            if !sync.isSignedIn {
                Text("Logga in för att få coachens analys av dina trender.")
                    .foregroundStyle(.secondary)
            } else if let insight {
                Text(insight.overall)
                if !insight.patterns.isEmpty {
                    Text("Mönster i din data")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    ForEach(insight.patterns, id: \.self) { pattern in
                        Label(pattern, systemImage: "link")
                            .font(.subheadline)
                    }
                }
                if let updated = insights.insights[period]?.updatedAt {
                    Text("Uppdaterad \(updated.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else if insights.loading.contains(period) {
                Text("Coachen analyserar dina trender… Det brukar ta under en minut.")
                    .foregroundStyle(.secondary)
            } else if let failed = insights.insights[period], failed.status == .failed {
                Label(failed.error ?? "Analysen misslyckades.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if let error = insights.errors[period] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var comparisonCard: some View {
        let snapshot = TrendSnapshot.make(period: period, health: health).volume
        return VStack(alignment: .leading, spacing: 10) {
            Text("Jämfört med föregående \(period.label)")
                .font(.headline)
            HStack(alignment: .top) {
                ComparisonTile(title: "Träningstid", value: "\(Int(snapshot.minutes / 60)) h", current: snapshot.minutes, previous: snapshot.previousMinutes)
                ComparisonTile(title: "Pass", value: "\(snapshot.sessions)", current: Double(snapshot.sessions), previous: Double(snapshot.previousSessions))
                ComparisonTile(title: "Distans", value: "\(Int(snapshot.km.rounded())) km", current: snapshot.km, previous: snapshot.previousKm)
            }
        }
        .cardStyle()
    }

    // MARK: - Diagram

    private var volumeCard: some View {
        let weeks = Trends.weeklyMinutes(health.workouts, weeks: period.weeks)
        let average = weeks.dropLast().suffix(4).map(\.value).average
        return TrendCard(
            title: "Träningstid per vecka",
            summary: average.map { "Snitt senaste 4 veckorna: \(Int($0.rounded())) min" },
            insight: insight?.card(.volume),
            question: "Hur ser du på min träningsmängd per vecka – ökar jag lagom?",
            onAsk: ask
        ) {
            Chart(weeks) { week in
                BarMark(x: .value("Vecka", week.date, unit: .weekOfYear), y: .value("Minuter", week.value))
                    .foregroundStyle(Color.accentColor.gradient)
            }
            .chartYAxisLabel("min")
        }
    }

    private var loadCard: some View {
        let start = Trends.startDate(of: period)
        let points = Trends.trainingLoad(health.workouts).filter { $0.date >= start }
        let ratio = Trends.loadRatio(health.workouts)
        var summary: String?
        if let latest = points.last {
            let state = latest.form > 5 ? "utvilad" : latest.form < -10 ? "belastad" : "i balans"
            summary = "Form \(Trends.signed(latest.form, decimals: 0)) (\(state))"
            if let ratio {
                summary! += " · belastningskvot \(Trends.number(ratio, decimals: 2))"
                if ratio > 1.5 { summary! += " – snabb ökning" }
            }
        }
        return TrendCard(
            title: "Form och belastning",
            summary: summary,
            explanation: "Kondition = din långsiktiga träningsbelastning (6 veckor). Trötthet = senaste veckans belastning. "
                + "Form = kondition minus trötthet: positiv när du är utvilad, negativ när du är belastad. "
                + "Belastningen räknas från tiden i varje pulszon.",
            insight: insight?.card(.load),
            question: "Kan du förklara min form och belastning just nu?",
            onAsk: ask
        ) {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Datum", point.date, unit: .day), y: .value("Värde", point.fitness))
                        .foregroundStyle(by: .value("Serie", "Kondition"))
                    LineMark(x: .value("Datum", point.date, unit: .day), y: .value("Värde", point.fatigue))
                        .foregroundStyle(by: .value("Serie", "Trötthet"))
                    LineMark(x: .value("Datum", point.date, unit: .day), y: .value("Värde", point.form))
                        .foregroundStyle(by: .value("Serie", "Form"))
                }
                RuleMark(y: .value("Noll", 0))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
            .chartForegroundStyleScale(["Kondition": Color.blue, "Trötthet": Color.pink, "Form": Color.green])
            .chartLegend(position: .bottom)
        }
    }

    private var efficiencyCard: some View {
        let points = Trends.within(Trends.efficiency(health.workouts), period)
        let trend = Trends.linearTrend(points)
        var summary: String?
        if trend.count == 2, let change = Trends.percentChange(trend[1].value, trend[0].value) {
            summary = "\(Trends.number(trend[1].value, decimals: 2)) m per hjärtslag (\(Trends.signed(change, decimals: 1)) %)"
        } else if points.isEmpty {
            summary = "Behöver löppass på minst 2 km med puls."
        }
        return TrendCard(
            title: "Aerob effektivitet",
            summary: summary,
            explanation: "Hur långt du springer per hjärtslag. Kommer du längre på samma antal slag har din aeroba kondition blivit bättre.",
            insight: insight?.card(.efficiency),
            question: "Vad säger min aeroba effektivitet om min kondition?",
            onAsk: ask
        ) {
            Chart {
                ForEach(points) { point in
                    PointMark(x: .value("Datum", point.date, unit: .day), y: .value("m/slag", point.value))
                        .foregroundStyle(.teal)
                }
                ForEach(trend) { point in
                    LineMark(x: .value("Datum", point.date, unit: .day), y: .value("Trend", point.value))
                        .foregroundStyle(.teal.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    private var vo2Card: some View {
        let all = Trends.daily(health.samples, kind: .vo2Max, using: .mean)
        let points = Trends.within(all, period)
        return TrendCard(
            title: "VO2 max",
            summary: changeSummary(points, unit: "", decimals: 1),
            insight: insight?.card(.vo2max),
            question: "Hur har min VO2 max utvecklats och vad betyder det?",
            onAsk: ask
        ) {
            Chart(points) { point in
                LineMark(x: .value("Datum", point.date, unit: .day), y: .value("VO2 max", point.value))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Datum", point.date, unit: .day), y: .value("VO2 max", point.value))
                    .symbolSize(18)
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    private var restingHeartRateCard: some View {
        let all = Trends.daily(health.samples, kind: .restingHeartRate, using: .mean)
        return bandCard(
            title: "Vilopuls",
            all: all,
            line: Trends.within(all, period),
            color: .red,
            unit: " bpm",
            decimals: 0,
            insightKey: .restingHR,
            question: "Hur ser min vilopuls ut jämfört med det normala för mig?"
        )
    }

    private var hrvCard: some View {
        // HRV mäts många gånger per dygn – dagsmedian som punkter och 7-dagarssnitt som linje.
        let all = Trends.daily(health.samples, kind: .heartRateVariability, using: .median)
        return bandCard(
            title: "Pulsvariabilitet (HRV)",
            all: all,
            line: Trends.within(Trends.rollingAverage(all, days: 7), period),
            dots: Trends.within(all, period),
            color: .purple,
            unit: " ms",
            decimals: 0,
            insightKey: .hrv,
            question: "Vad betyder utvecklingen i min HRV?"
        )
    }

    private var sleepCard: some View {
        let all = Trends.sleepHours(health.dailyMetrics)
        return bandCard(
            title: "Sömn",
            all: all,
            line: Trends.within(Trends.rollingAverage(all, days: 7), period),
            dots: Trends.within(all, period),
            color: .indigo,
            unit: " h",
            decimals: 1,
            insightKey: .sleep,
            question: "Hur påverkar min sömn träningen och återhämtningen?"
        )
    }

    /// Diagram med normalintervallet som skuggat band.
    private func bandCard(
        title: String,
        all: [TrendPoint],
        line: [TrendPoint],
        dots: [TrendPoint] = [],
        color: Color,
        unit: String,
        decimals: Int,
        insightKey: TrendInsight.CardKey,
        question: String
    ) -> some View {
        let baseline = Trends.baseline(all)
        var summary = changeSummary(line, unit: unit, decimals: decimals) ?? ""
        if let baseline {
            summary += "\nDitt normala: \(Trends.number(baseline.low, decimals: decimals))–\(Trends.number(baseline.high, decimals: decimals))\(unit)"
            if let recent = Trends.recentAverage(all), !baseline.contains(recent) {
                summary += recent > baseline.high ? " – senaste veckan över" : " – senaste veckan under"
            }
        }
        let range = (line + dots).map(\.date)
        return TrendCard(
            title: title,
            summary: summary.isEmpty ? nil : summary,
            insight: insight?.card(insightKey),
            question: question,
            onAsk: ask
        ) {
            Chart {
                if let baseline, let first = range.min(), let last = range.max(), first < last {
                    RectangleMark(
                        xStart: .value("Från", first),
                        xEnd: .value("Till", last),
                        yStart: .value("Låg", baseline.low),
                        yEnd: .value("Hög", baseline.high)
                    )
                    .foregroundStyle(color.opacity(0.12))
                }
                ForEach(dots) { point in
                    PointMark(x: .value("Datum", point.date, unit: .day), y: .value(title, point.value))
                        .symbolSize(10)
                        .foregroundStyle(color.opacity(0.35))
                }
                ForEach(line) { point in
                    LineMark(x: .value("Datum", point.date, unit: .day), y: .value(title, point.value))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    /// "Senast 53,7 (+2,1 under perioden)".
    private func changeSummary(_ points: [TrendPoint], unit: String, decimals: Int) -> String? {
        guard let latest = points.last else { return nil }
        var text = "Senast \(Trends.number(latest.value, decimals: decimals))\(unit)"
        if let first = points.first, first.date < latest.date {
            text += " (\(Trends.signed(latest.value - first.value, decimals: decimals)) under perioden)"
        }
        return text
    }
}

// MARK: - Komponenter

/// Kort med rubrik, sammanfattning, diagram, coachens kommentar och "Fråga coachen".
private struct TrendCard<Content: View>: View {
    let title: String
    let summary: String?
    var explanation: String?
    let insight: TrendInsight.Card?
    let question: String
    let onAsk: (String) -> Void
    @ViewBuilder let content: Content

    @State var showExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                if explanation != nil {
                    Button { showExplanation.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Förklaring")
                }
            }
            if showExplanation, let explanation {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            content
                .frame(height: 180)
            if let insight {
                InsightComment(card: insight)
            }
            Button {
                onAsk(question)
            } label: {
                Label("Fråga coachen", systemImage: "bubble.left")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .cardStyle()
    }
}

/// Coachens kommentar till ett diagram, med färg efter status.
private struct InsightComment: View {
    let card: TrendInsight.Card

    private var color: Color {
        switch card.status {
        case .positive: .green
        case .neutral: .secondary
        case .attention: .orange
        }
    }

    private var symbol: String {
        switch card.status {
        case .positive: "arrow.up.right.circle.fill"
        case .neutral: "minus.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.headline)
                    .font(.subheadline.weight(.semibold))
                Text(card.comment)
                    .font(.subheadline)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ComparisonTile: View {
    let title: String
    let value: String
    let current: Double
    let previous: Double

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            if let change = Trends.percentChange(current, previous) {
                Text("\(Trends.signed(change, decimals: 0)) %")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(change >= 0 ? .green : .orange)
            } else {
                Text("–")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private extension View {
    func cardStyle() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
