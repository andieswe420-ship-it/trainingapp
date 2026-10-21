import SwiftUI

@main
struct TrainingApp: App {
    @State private var healthStore: HealthKitManager
    @State private var sync: SyncService
    @State private var planStore: PlanStore

    init() {
        let sync = SyncService()
        _healthStore = State(initialValue: HealthKitManager())
        _sync = State(initialValue: sync)
        _planStore = State(initialValue: PlanStore(sync: sync))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                WorkoutListView()
                    .tabItem { Label("Pass", systemImage: "list.bullet") }
                PlanView()
                    .tabItem { Label("Plan", systemImage: "calendar") }
            }
            .environment(healthStore)
            .environment(sync)
            .environment(planStore)
            .task { await sync.observeAuthChanges() }
        }
    }
}
