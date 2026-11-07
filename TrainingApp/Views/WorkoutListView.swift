import SwiftUI

struct WorkoutListView: View {
    @Environment(HealthKitManager.self) private var health
    @Environment(SyncService.self) private var sync
    @Environment(CoachStore.self) private var coach
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            content
                .themedScreen()
                .navigationTitle("Pass")
                .refreshable {
                    await health.refresh()
                    await syncNow()
                }
                .toolbar { toolbar }
                .sheet(isPresented: $showAccount) { AccountView() }
        }
        .task {
            await health.requestAuthorizationAndLoad()
            await WorkoutKitAuthorization.requestIfNeeded()
            await Notifications.requestAuthorization()
            await syncNow()
            if sync.isSignedIn, let profile = try? await sync.fetchProfile() {
                await Notifications.updateWeeklyPlanReminder(enabled: profile.autoWeeklyPlan)
            }
        }
        .onChange(of: sync.userEmail) { _, email in
            guard email != nil else { return }
            Task { await syncNow() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showAccount = true
            } label: {
                Image(systemName: sync.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
            }
            .accessibilityLabel("Konto")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if sync.syncState == .syncing {
                ProgressView()
            } else {
                Button {
                    if sync.isSignedIn {
                        Task { await syncNow() }
                    } else {
                        showAccount = true
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                }
                .accessibilityLabel("Synka till molnet")
            }
        }
    }

    private func syncNow() async {
        guard health.state == .loaded else { return }
        await sync.sync(workouts: health.workouts, samples: health.samples, daily: health.dailyMetrics)
        // Synken kan ha fått coachen att fråga om ett nytt pass.
        await coach.refresh()
    }

    private var syncStatusText: String {
        if !sync.isSignedIn {
            return "Inte inloggad – tryck på molnet för att synka."
        }
        switch sync.syncState {
        case .syncing:
            return "Synkar…"
        case .failed(let message):
            return "Synk misslyckades: \(message)"
        case .idle:
            guard let date = sync.lastSyncedAt else { return "Inte synkad än." }
            return "Senast synkad \(date.formatted(.relative(presentation: .named)))."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch health.state {
        case .idle:
            ProgressView("Hämtar från Hälsa…")
        case .loading where health.workouts.isEmpty:
            ProgressView("Hämtar från Hälsa…")
        case .failed(let message) where health.workouts.isEmpty:
            ContentUnavailableView {
                Label("Kunde inte läsa hälsodata", systemImage: "heart.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Försök igen") {
                    Task { await health.requestAuthorizationAndLoad() }
                }
            }
        default:
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    SectionTitle("Återhämtning & kondition")
                    MetricsRow(metrics: health.metrics)
                        .card()
                }

                if let thisWeek = weeks.first, thisWeek.start == Self.weekStart(of: .now) {
                    weekSummaryCard(thisWeek, title: "Den här veckan")
                }

                if health.workouts.isEmpty {
                    Text("Inga träningspass hittades. Kontrollera att appen har läsbehörighet i Hälsa → Delning → Appar.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .card()
                } else {
                    LazyVStack(spacing: 20) {
                        ForEach(weeks) { week in
                            VStack(spacing: 8) {
                                SectionTitle(weekTitle(week))
                                VStack(spacing: 0) {
                                    ForEach(week.workouts) { workout in
                                        WorkoutRow(workout: workout)
                                            .padding(.vertical, 10)
                                        if workout.id != week.workouts.last?.id {
                                            Divider().overlay(Theme.border)
                                        }
                                    }
                                }
                                .padding(.vertical, -4)
                                .card()
                            }
                        }
                    }
                }

                Text(syncStatusText)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Veckor

    /// Passen grupperade per vecka (måndag–söndag), nyast först.
    private struct Week: Identifiable {
        let start: Date
        let workouts: [WorkoutSummary]
        var id: Date { start }
        var minutes: Double { workouts.reduce(0) { $0 + $1.duration } / 60 }
        var kilometers: Double { workouts.compactMap(\.distanceMeters).reduce(0, +) / 1000 }
    }

    private var weeks: [Week] {
        Dictionary(grouping: health.workouts) { Self.weekStart(of: $0.start) }
            .map { Week(start: $0.key, workouts: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.start > $1.start }
    }

    private static func weekStart(of date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    private func weekSummaryCard(_ week: Week, title: String) -> some View {
        VStack(spacing: 8) {
            SectionTitle(title)
            HStack {
                MetricView(value: "\(week.workouts.count)", label: "Pass")
                MetricView(value: Self.hoursText(week.minutes), label: "Tid")
                MetricView(value: String(format: "%.1f", week.kilometers), label: "km")
            }
            .padding(.vertical, 4)
            .card(raised: true)
        }
    }

    private func weekTitle(_ week: Week) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let number = calendar.component(.weekOfYear, from: week.start)
        let count = week.workouts.count == 1 ? "1 pass" : "\(week.workouts.count) pass"
        return "Vecka \(number) · \(count) · \(Self.hoursText(week.minutes))"
    }

    /// "45 min" eller "2 h 10 min".
    private static func hoursText(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total) min" }
        return total % 60 == 0 ? "\(total / 60) h" : "\(total / 60) h \(total % 60) min"
    }
}

#Preview {
    WorkoutListView()
        .environment(HealthKitManager())
        .environment(SyncService())
        .environment(CoachStore(sync: SyncService()))
}
