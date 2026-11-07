import Foundation
import HealthKit
import Observation

/// Kör passet på klockan när telefonens röstcoach startar det: spelar in med HKLiveWorkoutBuilder,
/// speglar passet till telefonen och skickar pulsen dit. Passet sparas i Hälsa när det avslutas.
@MainActor
@Observable
final class WatchWorkoutManager {
    enum State { case idle, running, paused, saving, saved, failed }

    static let shared = WatchWorkoutManager()

    private(set) var state: State = .idle
    private(set) var heartRate: Double?
    private(set) var startDate: Date?
    private(set) var errorMessage: String?

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private let delegate = WatchSessionDelegate()

    private init() {
        delegate.onHeartRate = { [weak self] bpm in self?.didMeasure(bpm) }
        delegate.onState = { [weak self] state, date in self?.didChange(to: state, at: date) }
        delegate.onMessages = { [weak self] messages in self?.handle(messages) }
        delegate.onFailure = { [weak self] message in
            self?.errorMessage = message
            self?.state = .failed
        }
    }

    func requestAuthorization() async {
        let share: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
        ]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
        ]
        try? await store.requestAuthorization(toShare: share, read: read)
    }

    /// Anropas när telefonen öppnar klockappen med ett pass (`startWatchApp`).
    func start(configuration: HKWorkoutConfiguration) async {
        guard session == nil else { return }
        await requestAuthorization()
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = delegate
            builder.delegate = delegate
            self.session = session
            self.builder = builder

            let start = Date.now
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            startDate = start
            state = .running
            heartRate = nil
            errorMessage = nil
            try await session.startMirroringToCompanionDevice()
        } catch {
            errorMessage = "Kunde inte starta passet: \(error.localizedDescription)"
            state = session == nil ? .failed : state
        }
    }

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    /// Avslutar från klockan: säg till telefonen först så att röstcoachen också slutar.
    func endFromWatch() async {
        await send(.end)
        end()
    }

    private func end() {
        guard let session, state == .running || state == .paused else { return }
        state = .saving
        session.stopActivity(with: .now)
    }

    private func send(_ message: LiveWorkoutMessage) async {
        guard let session, let data = message.encoded() else { return }
        try? await session.sendToRemoteWorkoutSession(data: data)
    }

    private func didMeasure(_ bpm: Double) {
        heartRate = bpm
        Task { await send(.heartRate(bpm)) }
    }

    private func handle(_ messages: [LiveWorkoutMessage]) {
        for message in messages {
            switch message {
            case .pause: pause()
            case .resume: resume()
            case .end: end()
            case .heartRate: break
            }
        }
    }

    private func didChange(to newState: HKWorkoutSessionState, at date: Date) {
        switch newState {
        case .running:
            if state == .paused { state = .running }
        case .paused:
            state = .paused
        case .stopped:
            // stopActivity → stopped: avsluta passet och spara det.
            session?.end()
            Task { await save(at: date) }
        default:
            break
        }
    }

    private func save(at date: Date) async {
        guard let builder else { return }
        do {
            try await builder.endCollection(at: date)
            _ = try await builder.finishWorkout()
            state = .saved
        } catch {
            errorMessage = "Kunde inte spara passet: \(error.localizedDescription)"
            state = .failed
        }
        session = nil
        self.builder = nil
    }
}

/// Tar emot HealthKits anrop (på godtycklig tråd) och skickar dem vidare till huvudtråden.
private final class WatchSessionDelegate: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    var onHeartRate: (@MainActor (Double) -> Void)?
    var onState: (@MainActor (HKWorkoutSessionState, Date) -> Void)?
    var onMessages: (@MainActor ([LiveWorkoutMessage]) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType),
              let value = workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity()?.doubleValue(for: Self.bpm)
        else { return }
        Task { @MainActor in self.onHeartRate?(value) }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.onState?(toState, date) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.onFailure?(message) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        let messages = data.compactMap(LiveWorkoutMessage.decode)
        Task { @MainActor in self.onMessages?(messages) }
    }
}
