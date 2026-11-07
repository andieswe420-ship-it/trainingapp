import SwiftUI

/// Veckoplan från AI-coachen: dagens pass överst, veckan som en rad och varje dag som ett kort.
struct PlanView: View {
    @Environment(HealthKitManager.self) private var health
    @Environment(SyncService.self) private var sync
    @Environment(PlanStore.self) private var store
    @Environment(WatchScheduler.self) private var watch

    @AppStorage("planNotes") private var notes = ""
    @State private var showAccount = false
    @State private var showProfile = false
    @State private var runWorkout: PlannedWorkout?

    private var today: String { PlanDate.string(from: .now) }

    var body: some View {
        NavigationStack {
            content
                .themedScreen()
                .navigationTitle("Veckoplan")
                .toolbar {
                    if sync.isSignedIn {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showProfile = true } label: {
                                Image(systemName: "person.text.rectangle")
                            }
                            .accessibilityLabel("Min profil")
                        }
                    }
                }
                .sheet(isPresented: $showAccount) { AccountView() }
                .sheet(isPresented: $showProfile) { ProfileView() }
                .fullScreenCover(item: $runWorkout) { workout in
                    RunView(workout: workout, maxHeartRate: health.workouts.compactMap(\.maxHeartRate).max())
                }
        }
        .task(id: sync.userEmail) {
            if sync.isSignedIn { await store.loadLatest() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !sync.isSignedIn {
            ContentUnavailableView {
                Label("Logga in för att planera", systemImage: "sparkles")
            } description: {
                Text("AI-coachen bygger veckoplanen utifrån dina synkade pass och din återhämtning.")
            } actions: {
                Button("Logga in") { showAccount = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 40)
            }
        } else {
            ScrollView {
                VStack(spacing: 20) {
                    status
                    if let plan = store.plan, let content = plan.plan {
                        weekStrip(plan: plan, content: content)
                        todayCard(plan: plan, content: content)
                        overviewCard(plan: plan, content: content)
                        upcomingDays(plan: plan, content: content)
                        if !content.restDayNotes.isEmpty {
                            VStack(spacing: 8) {
                                SectionTitle("Vilodagar")
                                Text(content.restDayNotes)
                                    .font(.callout)
                                    .card()
                            }
                        }
                        if WatchScheduler.isSupported, plan.status == .ready {
                            watchCard(plan: plan)
                        }
                    }
                    requestCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await store.loadLatest() }
        }
    }

    // MARK: - Veckan

    /// M T O T F L S med en prick per dag: färgad efter intensitet, tom för vila, ring runt idag.
    private func weekStrip(plan: TrainingPlan, content: PlanContent) -> some View {
        HStack(spacing: 0) {
            ForEach(plan.days, id: \.self) { day in
                let workouts = content.workouts.filter { $0.date == day }
                let isToday = day == today
                VStack(spacing: 8) {
                    Text(weekdayLetter(day))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isToday ? Theme.cyan : Theme.secondaryText)
                    ZStack {
                        Circle()
                            .fill(workouts.isEmpty ? Color.white.opacity(0.08) : dayColor(workouts).opacity(0.9))
                            .frame(width: 30, height: 30)
                        if let first = workouts.first {
                            Image(systemName: first.activity.symbolName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.backgroundTop)
                        }
                    }
                    .overlay(
                        Circle()
                            .strokeBorder(Theme.cyan, lineWidth: isToday ? 2 : 0)
                            .frame(width: 38, height: 38)
                    )
                    Text(dayNumber(day))
                        .font(.caption2)
                        .foregroundStyle(day < today ? Theme.secondaryText.opacity(0.6) : Theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .opacity(day < today ? 0.55 : 1)
            }
        }
        .padding(.vertical, 14)
        .card()
    }

    // MARK: - Idag

    @ViewBuilder
    private func todayCard(plan: TrainingPlan, content: PlanContent) -> some View {
        let workouts = content.workouts.filter { $0.date == today }
        if plan.days.contains(today) {
            VStack(spacing: 8) {
                SectionTitle("Idag")
                VStack(alignment: .leading, spacing: 16) {
                    if workouts.isEmpty {
                        Label("Vilodag – låt kroppen bygga upp sig.", systemImage: "bed.double.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.cyan)
                    } else {
                        ForEach(workouts) { workout in
                            PlannedWorkoutRow(workout: workout)
                            if workout.activity == .running || workout.activity == .walking {
                                Button {
                                    runWorkout = workout
                                } label: {
                                    Label("Spring med röstcoach", systemImage: "headphones")
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            }
                        }
                    }
                }
                .card(raised: true)
            }
        }
    }

    // MARK: - Översikt

    private func overviewCard(plan: TrainingPlan, content: PlanContent) -> some View {
        VStack(spacing: 8) {
            SectionTitle("Veckan · \(periodTitle(plan))")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: content.readiness.symbolName)
                        .font(.title3)
                        .foregroundStyle(Theme.cyan)
                    Text(content.readiness.label)
                        .font(.title3.weight(.bold))
                }
                Text(content.weeklyFocus)
                    .font(.headline)
                Text(content.readinessExplanation)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                Text(content.summary)
                    .font(.callout)
            }
            .card()
        }
    }

    // MARK: - Kommande dagar

    private func upcomingDays(plan: TrainingPlan, content: PlanContent) -> some View {
        let days = plan.days.filter { $0 > today }
        return VStack(spacing: 8) {
            if !days.isEmpty { SectionTitle("Kommande") }
            ForEach(days, id: \.self) { day in
                let workouts = content.workouts.filter { $0.date == day }
                VStack(alignment: .leading, spacing: 12) {
                    Text(dayTitle(day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                    if workouts.isEmpty {
                        Label("Vila", systemImage: "bed.double")
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        ForEach(workouts) { workout in
                            PlannedWorkoutRow(workout: workout)
                            if workout.activity == .running || workout.activity == .walking {
                                Button {
                                    runWorkout = workout
                                } label: {
                                    Label("Spring med röstcoach", systemImage: "headphones")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .tint(Theme.cyan)
                            }
                        }
                    }
                }
                .card()
            }
        }
    }

    // MARK: - Klockan

    private func watchCard(plan: TrainingPlan) -> some View {
        @Bindable var watch = watch
        return VStack(spacing: 8) {
            SectionTitle("Apple Watch")
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    Task { await watch.schedule(plan) }
                } label: {
                    HStack {
                        Label(watch.summary == nil ? "Lägg passen på klockan" : "Uppdatera klockan", systemImage: "applewatch")
                        if watch.isScheduling { ProgressView() }
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(watch.isScheduling)
                if let summary = watch.summary {
                    Text("\(summary.scheduled) pass på klockan · uppdaterat \(summary.date.formatted(date: .omitted, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                    if !summary.skipped.isEmpty {
                        Label("Kunde inte läggas på klockan: \(summary.skipped.joined(separator: ", "))", systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                if let message = watch.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                Toggle("Uppdatera klockan automatiskt", isOn: $watch.autoSync)
                    .tint(Theme.cyan)
                Text("Passen från idag och framåt hamnar under Schemalagda i Apples Träning-app på klockan. Ny plan och ändringar du godkänner hos coachen följer med automatiskt.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .card()
        }
    }

    // MARK: - Ny plan

    private var requestCard: some View {
        VStack(spacing: 8) {
            SectionTitle(store.plan == nil ? "Kom igång" : "Ny plan")
            VStack(alignment: .leading, spacing: 12) {
                TextField("Önskemål för just den här veckan", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                Button {
                    Task {
                        await store.generate(
                            notes: notes,
                            workouts: health.workouts,
                            samples: health.samples,
                            daily: health.dailyMetrics
                        )
                    }
                } label: {
                    Label(store.plan == nil ? "Skapa veckoplan" : "Skapa ny veckoplan", systemImage: "sparkles")
                }
                .buttonStyle(store.plan == nil ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
                .disabled(store.isPlanning || health.state != .loaded)
                Text("Planen gäller sju dagar från idag och följer veckoschemat i din profil. Dina senaste pass synkas först.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .card()
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var status: some View {
        if store.isPlanning {
            HStack(spacing: 12) {
                ProgressView()
                Text("AI-coachen planerar din vecka… Det brukar ta någon minut.")
                    .font(.callout)
            }
            .card(raised: true)
        }
        if let message = store.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .card()
        }
        if let plan = store.plan, plan.status == .failed {
            Label("Planeringen misslyckades: \(plan.error ?? "okänt fel")", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .card()
        }
    }

    // MARK: - Hjälpfunktioner

    /// Hårdaste passet bestämmer dagens färg.
    private func dayColor(_ workouts: [PlannedWorkout]) -> Color {
        if workouts.contains(where: { $0.intensity == .hard }) { return Theme.hot }
        if workouts.contains(where: { $0.intensity == .moderate }) { return Theme.blue }
        return Theme.cyan
    }

    private func weekdayLetter(_ day: String) -> String {
        guard let date = PlanDate.date(from: day) else { return "" }
        return date.formatted(.dateTime.weekday(.narrow)).uppercased()
    }

    private func dayNumber(_ day: String) -> String {
        guard let date = PlanDate.date(from: day) else { return "" }
        return date.formatted(.dateTime.day())
    }

    private func dayTitle(_ day: String) -> String {
        guard let date = PlanDate.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized
    }

    private func periodTitle(_ plan: TrainingPlan) -> String {
        guard let start = PlanDate.date(from: plan.startDate), let end = PlanDate.date(from: plan.endDate) else {
            return "\(plan.startDate) – \(plan.endDate)"
        }
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }
}

/// Typraderad knappstil, så att stilen kan väljas med ett villkor.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
