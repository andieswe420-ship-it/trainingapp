import SwiftUI

@main
struct TrainingApp: App {
    @State private var healthStore = HealthKitManager()

    var body: some Scene {
        WindowGroup {
            WorkoutListView()
                .environment(healthStore)
        }
    }
}
