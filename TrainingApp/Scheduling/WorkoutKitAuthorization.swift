import WorkoutKit

/// Behörighet för att schemalägga pass till Apple Watch via WorkoutKit.
/// Själva schemaläggningen kommer i fas 4 (WorkoutScheduling.swift) –
/// här ber vi bara om tillåtelse så att behörigheten finns på plats.
enum WorkoutKitAuthorization {
    static func requestIfNeeded() async -> WorkoutScheduler.AuthorizationState {
        let scheduler = WorkoutScheduler.shared
        let current = await scheduler.authorizationState
        guard current == .notDetermined else { return current }
        return await scheduler.requestAuthorization()
    }
}
