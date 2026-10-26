import CryptoKit
import Foundation
import HealthKit
import Observation
import WorkoutKit

/// Behörighet för att schemalägga pass till Apple Watch via WorkoutKit.
enum WorkoutKitAuthorization {
    static func requestIfNeeded() async -> WorkoutScheduler.AuthorizationState {
        let scheduler = WorkoutScheduler.shared
        let current = await scheduler.authorizationState
        guard current == .notDetermined else { return current }
        return await scheduler.requestAuthorization()
    }
}

/// Lägger veckoplanens kommande pass på Apple Watch (Träning-appen). Schemaläggaren ser bara den här
/// appens pass, så vid varje uppdatering tas allt bort och läggs in på nytt utifrån aktuell plan.
@MainActor
@Observable
final class WatchScheduler {
    struct Summary {
        let scheduled: Int
        /// Titlar på pass som inte kunde läggas på klockan.
        let skipped: [String]
        let date: Date
    }

    private(set) var isScheduling = false
    private(set) var summary: Summary?
    private(set) var errorMessage: String?

    /// Lägg ändrade planer (ny plan, godkänt förslag) på klockan utan att användaren behöver trycka.
    var autoSync: Bool {
        didSet { UserDefaults.standard.set(autoSync, forKey: Self.autoSyncKey) }
    }

    static var isSupported: Bool { WorkoutScheduler.isSupported }

    /// Klockslag för pass på kommande dagar (svensk tid).
    private static let defaultHour = 8
    private static let autoSyncKey = "watchAutoSync"
    private static let fingerprintKey = "watchScheduledFingerprint"

    init() {
        autoSync = UserDefaults.standard.object(forKey: Self.autoSyncKey) as? Bool ?? true
    }

    /// Lägger planen på klockan om den ändrats sedan sist. Frågar aldrig om behörighet.
    func syncIfNeeded(_ plan: TrainingPlan?) async {
        guard autoSync, Self.isSupported, let plan, plan.status == .ready, let content = plan.plan else { return }
        guard Self.fingerprint(plan: plan, workouts: Self.upcoming(content)) != storedFingerprint else { return }
        guard await WorkoutScheduler.shared.authorizationState == .authorized else { return }
        await schedule(plan)
    }

    /// Ersätter alla pass på klockan med planens pass från idag och framåt.
    func schedule(_ plan: TrainingPlan) async {
        guard !isScheduling, plan.status == .ready, let content = plan.plan else { return }
        isScheduling = true
        errorMessage = nil
        defer { isScheduling = false }

        guard await WorkoutKitAuthorization.requestIfNeeded() == .authorized else {
            errorMessage = "Appen får inte lägga pass på klockan. Tillåt det för TrainingApp i appen Inställningar."
            return
        }

        let upcoming = Self.upcoming(content)
        let scheduler = WorkoutScheduler.shared
        var scheduled = 0
        var skipped: [String] = []
        await scheduler.removeAllWorkouts()
        for workout in upcoming {
            guard scheduled < WorkoutScheduler.maxAllowedScheduledWorkoutCount,
                  let workoutPlan = WorkoutPlanBuilder.workoutPlan(for: workout),
                  let date = Self.scheduleDate(for: workout.date)
            else {
                skipped.append(workout.title)
                continue
            }
            await scheduler.schedule(workoutPlan, at: date)
            scheduled += 1
        }

        summary = Summary(scheduled: scheduled, skipped: skipped, date: .now)
        UserDefaults.standard.set(Self.fingerprint(plan: plan, workouts: upcoming), forKey: Self.fingerprintKey)
    }

    private var storedFingerprint: String? {
        UserDefaults.standard.string(forKey: Self.fingerprintKey)
    }

    private static func upcoming(_ content: PlanContent) -> [PlannedWorkout] {
        let today = PlanDate.string(from: .now)
        return content.workouts.filter { $0.date >= today }.sorted { $0.date < $1.date }
    }

    /// Ändras när planen, något kommande pass eller dagens datum ändras.
    private static func fingerprint(plan: TrainingPlan, workouts: [PlannedWorkout]) -> String {
        let text = "\(plan.id)|\(PlanDate.string(from: .now))|\(String(describing: workouts))"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Kommande dagar kl. 08:00; idag om några minuter om klockan redan passerat 08:00.
    private static func scheduleDate(for day: String) -> DateComponents? {
        guard let date = PlanDate.date(from: day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
        guard var start = calendar.date(bySettingHour: defaultHour, minute: 0, second: 0, of: date) else { return nil }
        let soon = Date.now.addingTimeInterval(5 * 60)
        if start < soon {
            guard calendar.isDate(date, inSameDayAs: .now) else { return nil }
            start = soon
        }
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
    }
}

/// Översätter AI-planens pass till WorkoutKit. Planformatet är gjort för detta:
/// uppvärmning/nedvarvning → WorkoutStep, block → IntervalBlock, steg → IntervalStep med mål och larm.
enum WorkoutPlanBuilder {
    static func workoutPlan(for workout: PlannedWorkout) -> WorkoutPlan? {
        let activity = activityType(workout.activity)
        let location: HKWorkoutSessionLocationType = workout.location == .indoor ? .indoor : .outdoor

        if CustomWorkout.supportsActivity(activity) {
            let blocks = workout.blocks.compactMap { block -> IntervalBlock? in
                let steps = block.steps.map { intervalStep($0, activity: activity, location: location) }
                guard !steps.isEmpty else { return nil }
                return IntervalBlock(steps: steps, iterations: max(1, Int(block.iterations.rounded())))
            }
            let custom = CustomWorkout(
                activity: activity,
                location: location,
                displayName: workout.title,
                warmup: timeStep(minutes: workout.warmupMinutes),
                blocks: blocks,
                cooldown: timeStep(minutes: workout.cooldownMinutes)
            )
            return WorkoutPlan(.custom(custom))
        }

        // Aktiviteter utan stöd för egna pass (t.ex. yoga) läggs in som ett tidsmål.
        guard SingleGoalWorkout.supportsActivity(activity), workout.estimatedMinutes > 0 else { return nil }
        let goal = WorkoutGoal.time(workout.estimatedMinutes.rounded(), .minutes)
        return WorkoutPlan(.goal(SingleGoalWorkout(activity: activity, location: location, goal: goal)))
    }

    private static func activityType(_ activity: PlannedWorkout.Activity) -> HKWorkoutActivityType {
        switch activity {
        case .running: .running
        case .walking: .walking
        case .cycling: .cycling
        case .hiit: .highIntensityIntervalTraining
        case .strength: .traditionalStrengthTraining
        case .mobility: .flexibility
        case .pilates: .pilates
        case .yoga: .yoga
        }
    }

    private static func timeStep(minutes: Double) -> WorkoutStep? {
        guard minutes > 0 else { return nil }
        return WorkoutStep(goal: .time(minutes.rounded(), .minutes))
    }

    /// Mål och larm som klockan inte stöder för aktiviteten byts mot öppet mål respektive inget larm.
    private static func intervalStep(
        _ step: PlanStep,
        activity: HKWorkoutActivityType,
        location: HKWorkoutSessionLocationType
    ) -> IntervalStep {
        var goal = goal(for: step)
        if !CustomWorkout.supportsGoal(goal, activity: activity, location: location) {
            goal = .open
        }
        var alert = alert(for: step)
        if let current = alert, !CustomWorkout.supportsAlert(current, activity: activity, location: location) {
            alert = nil
        }
        return IntervalStep(step.purpose == .work ? .work : .recovery, goal: goal, alert: alert)
    }

    private static func goal(for step: PlanStep) -> WorkoutGoal {
        switch step.goalType {
        case .time where step.goalValue > 0: .time(step.goalValue, .seconds)
        case .distance where step.goalValue > 0: .distance(step.goalValue, .meters)
        default: .open
        }
    }

    private static func alert(for step: PlanStep) -> (any WorkoutAlert)? {
        switch step.targetType {
        case .none:
            return nil
        case .heartRateZone:
            return HeartRateZoneAlert.heartRate(zone: min(5, max(1, Int(step.targetLow.rounded()))))
        case .heartRateRange:
            guard step.targetLow > 0, step.targetHigh > step.targetLow else { return nil }
            return HeartRateRangeAlert.heartRate(step.targetLow...step.targetHigh)
        case .pace:
            // target_low är snabbaste tempot (s/km) och ger därför den högsta farten.
            guard step.targetLow > 0, step.targetHigh >= step.targetLow else { return nil }
            let speeds = (1000 / step.targetHigh)...(1000 / step.targetLow)
            return SpeedRangeAlert.speed(speeds, unit: .metersPerSecond, metric: .current)
        }
    }
}
