import SwiftUI

@main
struct TrainingApp: App {
    @State private var healthStore = HealthKitManager()
    @State private var sync = SyncService()

    var body: some Scene {
        WindowGroup {
            WorkoutListView()
                .environment(healthStore)
                .environment(sync)
                .task { await sync.observeAuthChanges() }
        }
    }
}
