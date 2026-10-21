import SwiftUI

@main
struct TrainingApp: App {
    @State private var healthStore: HealthKitManager
    @State private var sync: SyncService
    @State private var planStore: PlanStore
    @State private var coachStore: CoachStore

    init() {
        let sync = SyncService()
        _healthStore = State(initialValue: HealthKitManager())
        _sync = State(initialValue: sync)
        _planStore = State(initialValue: PlanStore(sync: sync))
        _coachStore = State(initialValue: CoachStore(sync: sync))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                WorkoutListView()
                    .tabItem { Label("Pass", systemImage: "list.bullet") }
                PlanView()
                    .tabItem { Label("Plan", systemImage: "calendar") }
                CoachView()
                    .tabItem { Label("Coach", systemImage: "bubble.left.and.bubble.right") }
                    .badge(coachStore.unreadCount)
            }
            .environment(healthStore)
            .environment(sync)
            .environment(planStore)
            .environment(coachStore)
            .task { await sync.observeAuthChanges() }
        }
    }
}
