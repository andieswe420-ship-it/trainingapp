import SwiftUI

struct WorkoutListView: View {
    @Environment(HealthKitManager.self) private var health
    @Environment(SyncService.self) private var sync
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Träning")
                .refreshable {
                    await health.refresh()
                    await syncNow()
                }
                .toolbar { toolbar }
                .sheet(isPresented: $showAccount) { AccountView() }
        }
        .task {
            await health.requestAuthorizationAndLoad()
            _ = await WorkoutKitAuthorization.requestIfNeeded()
            await syncNow()
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
        await sync.sync(workouts: health.workouts, samples: health.samples)
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
        List {
            Section("Återhämtning & kondition") {
                MetricsRow(metrics: health.metrics)
            }

            Section {
                if health.workouts.isEmpty {
                    Text("Inga träningspass hittades. Kontrollera att appen har läsbehörighet i Hälsa → Delning → Appar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(health.workouts) { workout in
                        WorkoutRow(workout: workout)
                    }
                }
            } header: {
                Text("Senaste \(HealthKitManager.historyDays) dagarna (\(health.workouts.count) pass)")
            } footer: {
                Text(syncStatusText)
            }
        }
    }
}

#Preview {
    WorkoutListView()
        .environment(HealthKitManager())
        .environment(SyncService())
}
