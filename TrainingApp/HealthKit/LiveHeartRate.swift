import Foundation
import HealthKit
import Observation

/// Live-puls från klockappen under ett röstcoachat pass. Telefonen startar klockappen
/// (`startWatchApp`), klockan kör passet och speglar det hit och skickar pulsen som
/// `LiveWorkoutMessage`. På iOS 17 finns ingen egen workout builder i telefonen, därför
/// går pulsen över det speglade passets datakanal.
@MainActor
@Observable
final class LiveHeartRate {
    static let shared = LiveHeartRate()

    private(set) var bpm: Double?
    private(set) var lastUpdate: Date?
    private(set) var isConnected = false

    /// Klockan avslutade passet.
    @ObservationIgnored var onRemoteEnd: (() -> Void)?

    /// Pulsen om den är färsk (högst 15 sekunder gammal).
    var current: Double? {
        guard let bpm, let lastUpdate, Date.now.timeIntervalSince(lastUpdate) < 15 else { return nil }
        return bpm
    }

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private let delegate = MirroredSessionDelegate()

    private init() {
        delegate.onMessages = { [weak self] messages in self?.handle(messages) }
        delegate.onDisconnect = { [weak self] in self?.disconnect() }
        // Måste sättas tidigt: klockan kan spegla passet innan röstcoachen är igång.
        store.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor in self?.attach(session) }
        }
    }

    /// Öppnar klockappen och startar ett pass där. Klockan spelar in passet och sparar det i Hälsa.
    func startWatchWorkout(activity: HKWorkoutActivityType, outdoor: Bool) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        configuration.locationType = outdoor ? .outdoor : .indoor
        do {
            try await store.startWatchApp(toHandle: configuration)
            return true
        } catch {
            return false
        }
    }

    func send(_ message: LiveWorkoutMessage) async {
        guard let session, let data = message.encoded() else { return }
        try? await session.sendToRemoteWorkoutSession(data: data)
    }

    private func attach(_ session: HKWorkoutSession) {
        self.session = session
        session.delegate = delegate
        isConnected = true
        bpm = nil
    }

    private func handle(_ messages: [LiveWorkoutMessage]) {
        for message in messages {
            switch message {
            case .heartRate(let value):
                bpm = value
                lastUpdate = .now
            case .end:
                onRemoteEnd?()
                disconnect()
            case .pause, .resume:
                break
            }
        }
    }

    private func disconnect() {
        isConnected = false
        session = nil
    }
}

/// Tar emot data och statusändringar från klockans speglade pass.
private final class MirroredSessionDelegate: NSObject, HKWorkoutSessionDelegate {
    var onMessages: (@MainActor ([LiveWorkoutMessage]) -> Void)?
    var onDisconnect: (@MainActor () -> Void)?

    func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        let messages = data.compactMap(LiveWorkoutMessage.decode)
        Task { @MainActor in self.onMessages?(messages) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended || toState == .stopped {
            Task { @MainActor in self.onDisconnect?() }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        Task { @MainActor in self.onDisconnect?() }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: (any Error)?) {
        Task { @MainActor in self.onDisconnect?() }
    }
}
