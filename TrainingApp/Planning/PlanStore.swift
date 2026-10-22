import Foundation
import Observation

/// Håller senaste veckoplanen och driver flödet synk → beställ plan → vänta tills den är klar.
@MainActor
@Observable
final class PlanStore {
    private(set) var plan: TrainingPlan?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    var isPlanning: Bool { isWorking || plan?.status == .pending }

    private let sync: SyncService
    private static let pollInterval: Duration = .seconds(3)
    /// Edge Functions får köra i högst några minuter; vänta lite längre än så.
    private static let maxPolls = 120

    init(sync: SyncService) {
        self.sync = sync
    }

    func loadLatest() async {
        do {
            plan = try await sync.fetchLatestPlan()
            if let plan, plan.status == .pending {
                await waitForPlan(id: plan.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Synkar först senaste HealthKit-datan så att planen bygger på färska värden.
    func generate(notes: String, workouts: [WorkoutSummary], samples: [HealthSample], daily: [DailyMetrics]) async {
        guard !isPlanning else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        await sync.sync(workouts: workouts, samples: samples, daily: daily)
        do {
            let id = try await sync.requestPlan(notes: notes)
            await waitForPlan(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func waitForPlan(id: UUID) async {
        for _ in 0..<Self.maxPolls {
            do {
                if let latest = try await sync.fetchPlan(id: id) {
                    plan = latest
                    if latest.status != .pending { return }
                }
                try await Task.sleep(for: Self.pollInterval)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        errorMessage = "Planeringen tar ovanligt lång tid. Dra nedåt för att uppdatera senare."
    }
}
