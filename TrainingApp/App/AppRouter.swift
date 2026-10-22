import Observation

enum AppTab: String, Hashable {
    case workouts, plan, coach, trends
}

/// Vald flik. Delas så att t.ex. ett tryck på en notis kan öppna rätt flik.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var selectedTab: AppTab = .workouts

    private init() {}
}
