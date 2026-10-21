import SwiftUI

struct WorkoutListView: View {
    @Environment(HealthKitManager.self) private var health

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Träning")
                .refreshable { await health.refresh() }
        }
        .task {
            await health.requestAuthorizationAndLoad()
            _ = await WorkoutKitAuthorization.requestIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch health.state {
        case .idle, .loading where health.workouts.isEmpty:
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

            Section("Senaste \(HealthKitManager.historyDays) dagarna (\(health.workouts.count) pass)") {
                if health.workouts.isEmpty {
                    Text("Inga träningspass hittades. Kontrollera att appen har läsbehörighet i Hälsa → Delning → Appar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(health.workouts) { workout in
                        WorkoutRow(workout: workout)
                    }
                }
            }
        }
    }
}

#Preview {
    WorkoutListView()
        .environment(HealthKitManager())
}
