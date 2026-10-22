import SwiftUI
import UIKit

@main
struct TrainingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var healthStore: HealthKitManager
    @State private var sync: SyncService
    @State private var planStore: PlanStore
    @State private var coachStore: CoachStore
    @State private var insightStore: InsightStore
    @State private var router = AppRouter.shared

    init() {
        let health = HealthKitManager()
        let sync = SyncService()
        let coach = CoachStore(sync: sync)
        _healthStore = State(initialValue: health)
        _sync = State(initialValue: sync)
        _planStore = State(initialValue: PlanStore(sync: sync))
        _coachStore = State(initialValue: coach)
        _insightStore = State(initialValue: InsightStore(sync: sync))

        // Nytt pass i Hälsa (även när appen ligger i bakgrunden): synka och låt coachen fråga.
        health.observeNewWorkouts {
            guard sync.isSignedIn, health.state != .loading else { return }
            await health.refresh()
            let coachAsked = await sync.sync(
                workouts: health.workouts,
                samples: health.samples,
                daily: health.dailyMetrics
            )
            await coach.refresh()
            if coachAsked && UIApplication.shared.applicationState != .active {
                await Notifications.notifyCoachCheckin()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $router.selectedTab) {
                WorkoutListView()
                    .tabItem { Label("Pass", systemImage: "list.bullet") }
                    .tag(AppTab.workouts)
                PlanView()
                    .tabItem { Label("Plan", systemImage: "calendar") }
                    .tag(AppTab.plan)
                CoachView()
                    .tabItem { Label("Coach", systemImage: "bubble.left.and.bubble.right") }
                    .badge(coachStore.unreadCount)
                    .tag(AppTab.coach)
                TrendsView()
                    .tabItem { Label("Trender", systemImage: "chart.xyaxis.line") }
                    .tag(AppTab.trends)
            }
            .environment(healthStore)
            .environment(sync)
            .environment(planStore)
            .environment(coachStore)
            .environment(insightStore)
            .task { await sync.observeAuthChanges() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshOnActivate() }
            }
        }
    }

    /// När appen öppnas igen: hämta nytt från Hälsa, synka och uppdatera plan och chatt.
    private func refreshOnActivate() async {
        guard healthStore.state == .loaded else { return }
        await healthStore.refresh()
        await sync.sync(workouts: healthStore.workouts, samples: healthStore.samples, daily: healthStore.dailyMetrics)
        await coachStore.refresh()
        await planStore.loadLatest()
    }
}
