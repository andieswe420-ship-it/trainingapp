import SwiftUI

/// Veckoplan från AI-coachen.
struct PlanView: View {
    @Environment(HealthKitManager.self) private var health
    @Environment(SyncService.self) private var sync
    @Environment(PlanStore.self) private var store
    @Environment(WatchScheduler.self) private var watch

    @AppStorage("planNotes") private var notes = ""
    @State private var showAccount = false
    @State private var showProfile = false

    var body: some View {
        NavigationStack {
            content
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
            }
        } else {
            List {
                requestSection
                statusSection
                if let plan = store.plan, let content = plan.plan {
                    overviewSection(plan: plan, content: content)
                    if WatchScheduler.isSupported, plan.status == .ready {
                        watchSection(plan: plan)
                    }
                    ForEach(plan.days, id: \.self) { day in
                        daySection(day: day, workouts: content.workouts.filter { $0.date == day })
                    }
                    Section("Vilodagar") {
                        Text(content.restDayNotes)
                    }
                }
            }
            .refreshable { await store.loadLatest() }
        }
    }

    private var requestSection: some View {
        Section {
            TextField("Önskemål för just den här veckan", text: $notes, axis: .vertical)
                .lineLimit(2...5)
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
            .disabled(store.isPlanning || health.state != .loaded)
        } footer: {
            Text("Planen gäller sju dagar från idag och följer veckoschemat i din profil. Dina senaste pass synkas först.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if store.isPlanning {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("AI-coachen planerar din vecka… Det brukar ta någon minut.")
                }
            }
        }
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        if let plan = store.plan, plan.status == .failed {
            Section {
                Label("Planeringen misslyckades: \(plan.error ?? "okänt fel")", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    private func overviewSection(plan: TrainingPlan, content: PlanContent) -> some View {
        Section {
            Label(content.readiness.label, systemImage: content.readiness.symbolName)
                .font(.headline)
            Text(content.readinessExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(content.weeklyFocus)
                .font(.subheadline.weight(.semibold))
            Text(content.summary)
        } header: {
            Text(periodTitle(plan))
        }
    }

    private func watchSection(plan: TrainingPlan) -> some View {
        @Bindable var watch = watch
        return Section {
            Button {
                Task { await watch.schedule(plan) }
            } label: {
                HStack {
                    Label(watch.summary == nil ? "Lägg passen på klockan" : "Uppdatera klockan", systemImage: "applewatch")
                    if watch.isScheduling {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(watch.isScheduling)
            if let summary = watch.summary {
                Text("\(summary.scheduled) pass på klockan · uppdaterat \(summary.date.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("Passen från idag och framåt hamnar under Schemalagda i Träning-appen på klockan. Ny plan och ändringar du godkänner hos coachen följer med automatiskt.")
        }
    }

    private func daySection(day: String, workouts: [PlannedWorkout]) -> some View {
        Section(dayTitle(day)) {
            if workouts.isEmpty {
                Label("Vila", systemImage: "bed.double")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(workouts) { workout in
                    PlannedWorkoutRow(workout: workout)
                }
            }
        }
    }

    private func dayTitle(_ day: String) -> String {
        guard let date = PlanDate.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func periodTitle(_ plan: TrainingPlan) -> String {
        guard let start = PlanDate.date(from: plan.startDate), let end = PlanDate.date(from: plan.endDate) else {
            return "\(plan.startDate) – \(plan.endDate)"
        }
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }
}
