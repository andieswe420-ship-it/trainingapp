import AVFoundation
import CoreLocation
import Foundation
import HealthKit
import Observation

/// Ett steg i passet som röstcoachen leder: planens block och upprepningar utplattade i ordning.
struct RunStep: Identifiable, Sendable {
    enum Kind: Sendable { case warmup, work, recovery, cooldown }
    enum Goal: Sendable {
        case time(seconds: Double)
        case distance(meters: Double)
        /// Avslutas när personen trycker på Nästa.
        case open
    }

    let id: Int
    let kind: Kind
    let goal: Goal
    let target: PlanStep?
    let description: String
    /// Vilken upprepning av hur många, för block med fler än en upprepning.
    let repetition: (index: Int, count: Int)?

    static func steps(for workout: PlannedWorkout, usesGPS: Bool) -> [RunStep] {
        var steps: [RunStep] = []
        func add(_ kind: Kind, _ goal: Goal, target: PlanStep? = nil, description: String = "",
                 repetition: (index: Int, count: Int)? = nil) {
            steps.append(RunStep(id: steps.count, kind: kind, goal: goal, target: target,
                                 description: description, repetition: repetition))
        }

        if workout.warmupMinutes > 0 {
            add(.warmup, .time(seconds: workout.warmupMinutes * 60))
        }
        for block in workout.blocks {
            let count = max(1, Int(block.iterations.rounded()))
            for index in 1...count {
                for step in block.steps {
                    let goal: Goal = switch step.goalType {
                    case .time where step.goalValue > 0: .time(seconds: step.goalValue)
                    // Utan GPS (löpband) går distansen inte att mäta – personen trycker på Nästa.
                    case .distance where step.goalValue > 0 && usesGPS: .distance(meters: step.goalValue)
                    default: .open
                    }
                    add(step.purpose == .work ? .work : .recovery, goal,
                        target: step.targetType == .none ? nil : step,
                        description: step.description,
                        repetition: count > 1 ? (index: index, count: count) : nil)
                }
            }
        }
        if workout.cooldownMinutes > 0 {
            add(.cooldown, .time(seconds: workout.cooldownMinutes * 60))
        }
        return steps
    }
}

/// Leder ett planerat löppass med rösten i hörlurarna: telefonen håller tiden, mäter tempo och distans
/// med GPS och säger till vid varje steg. Klockappen startas samtidigt, spelar in passet i Hälsa och
/// skickar pulsen live (`LiveHeartRate`) – därför sparar röstcoachen inget eget pass.
@MainActor
@Observable
final class RunSession {
    enum State { case ready, running, paused, finished }

    let workout: PlannedWorkout
    let steps: [RunStep]
    let usesGPS: Bool

    private(set) var state: State = .ready
    private(set) var stepIndex = 0
    private(set) var stepElapsed: TimeInterval = 0
    private(set) var stepDistance: Double = 0
    private(set) var totalElapsed: TimeInterval = 0
    private(set) var totalDistance: Double = 0
    /// Tempo de senaste ~30 sekunderna, sekunder per km.
    private(set) var currentPace: Double?
    private(set) var locationDenied = false
    /// Klockappen startades och kör passet.
    private(set) var watchStarted = false

    /// Pulsen från klockan, om den är färsk.
    var heartRate: Double? { liveHeartRate.current }

    var currentStep: RunStep? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }
    var nextStep: RunStep? { steps.indices.contains(stepIndex + 1) ? steps[stepIndex + 1] : nil }

    /// Hur mycket som är kvar av steget, för visning.
    var stepRemaining: String {
        guard let step = currentStep else { return "" }
        switch step.goal {
        case .time(let seconds): return RunSpeech.clock(max(0, seconds - stepElapsed))
        case .distance(let meters): return RunSpeech.distanceShort(max(0, meters - stepDistance))
        case .open: return RunSpeech.clock(stepElapsed)
        }
    }

    /// Hur stor del av steget som är avklarad (0–1), för ringen. Öppna steg har ingen ände.
    var stepProgress: Double {
        guard let step = currentStep else { return state == .finished ? 1 : 0 }
        switch step.goal {
        case .time(let seconds): return seconds > 0 ? stepElapsed / seconds : 0
        case .distance(let meters): return meters > 0 ? stepDistance / meters : 0
        case .open: return 0
        }
    }

    @ObservationIgnored private let liveHeartRate: LiveHeartRate
    /// Pulszoner i bpm (zon 1–5) utifrån högsta uppmätta puls, eller tomt om den saknas.
    @ObservationIgnored private let zones: [ClosedRange<Double>]
    @ObservationIgnored private let voice = RunVoice()
    @ObservationIgnored private let tracker = RunLocationTracker()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastTick = Date()
    /// (passets tid, total distans) för tempoberäkningen.
    @ObservationIgnored private var paceSamples: [(time: TimeInterval, distance: Double)] = []
    @ObservationIgnored private var spokenKilometers = 0
    @ObservationIgnored private var cues = StepCues()

    /// Vad som redan sagts under steget, så att inget upprepas.
    private struct StepCues {
        var halfway = false
        var thirtySeconds = false
        var countdown = false
        var lastMeters = false
        var lastPaceCheck: TimeInterval = 0
        var lastHeartRateCheck: TimeInterval = 0
    }

    init(workout: PlannedWorkout, maxHeartRate: Double?) {
        self.workout = workout
        // Hämtas här och inte som standardvärde: standardvärden körs utanför huvudtråden.
        let liveHeartRate = LiveHeartRate.shared
        self.liveHeartRate = liveHeartRate
        zones = Self.zones(maxHeartRate: maxHeartRate)
        usesGPS = workout.location == .outdoor
        steps = RunStep.steps(for: workout, usesGPS: usesGPS)
        tracker.onDistance = { [weak self] meters in self?.addDistance(meters) }
        tracker.onDenied = { [weak self] in self?.locationDenied = true }
        liveHeartRate.onRemoteEnd = { [weak self] in self?.finish(fromWatch: true) }
    }

    /// Zon n = 40 + 10·n till 50 + 10·n % av maxpulsen (zon 1 = 50–60 %, zon 5 = 90–100 %).
    /// Klockans egna zoner går inte att läsa, så det här är en uppskattning.
    private static func zones(maxHeartRate: Double?) -> [ClosedRange<Double>] {
        guard let max = maxHeartRate, max > 120 else { return [] }
        return (1...5).map { zone in
            let low = (0.4 + 0.1 * Double(zone)) * max
            return low...(low + 0.1 * max)
        }
    }

    func previewVoice() {
        voice.preview()
    }

    func start() {
        guard state == .ready, let first = currentStep else { return }
        state = .running
        lastTick = .now
        // GPS-uppdateringarna håller också appen igång med låst skärm, även på löpband.
        tracker.start()
        voice.say("Nu kör vi. \(workout.title). \(RunSpeech.intro(first, next: nextStep))")
        Task {
            let activity: HKWorkoutActivityType = workout.activity == .walking ? .walking : .running
            watchStarted = await liveHeartRate.startWatchWorkout(activity: activity, outdoor: usesGPS)
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func pause() {
        guard state == .running else { return }
        tick()
        state = .paused
        tracker.resetLastLocation()
        voice.say("Pausat.")
        Task { await liveHeartRate.send(.pause) }
    }

    func resume() {
        guard state == .paused else { return }
        lastTick = .now
        state = .running
        voice.say("Vi fortsätter.")
        Task { await liveHeartRate.send(.resume) }
    }

    /// Hoppar till nästa steg, t.ex. för öppna steg eller distans på löpband.
    func skip() {
        guard state == .running || state == .paused else { return }
        advance()
    }

    /// Avslutar passet, även på klockan (som då sparar det i Hälsa).
    func finish(fromWatch: Bool = false) {
        guard state == .running || state == .paused else { return }
        if state == .running { tick() }
        ticker?.cancel()
        tracker.stop()
        state = .finished
        if !fromWatch { Task { await liveHeartRate.send(.end) } }
        voice.say(RunSpeech.summary(time: totalElapsed, distance: usesGPS ? totalDistance : nil,
                                    watchSaves: watchStarted))
    }

    /// Avbryter utan sammanfattning (när vyn stängs).
    func stop() {
        ticker?.cancel()
        tracker.stop()
        voice.stop()
    }

    // MARK: - Tid och distans

    private func tick() {
        let now = Date.now
        defer { lastTick = now }
        guard state == .running else { return }
        let delta = now.timeIntervalSince(lastTick)
        stepElapsed += delta
        totalElapsed += delta
        updatePace()
        speakCues()
        if isStepComplete { advance() }
    }

    private func addDistance(_ meters: Double) {
        guard state == .running, usesGPS else { return }
        stepDistance += meters
        totalDistance += meters
        paceSamples.append((totalElapsed, totalDistance))

        let kilometers = Int(totalDistance / 1000)
        if kilometers > spokenKilometers {
            spokenKilometers = kilometers
            voice.say(RunSpeech.kilometer(kilometers, pace: currentPace, heartRate: heartRate))
        }
    }

    private func updatePace() {
        paceSamples.removeAll { $0.time < totalElapsed - 30 }
        guard let first = paceSamples.first, let last = paceSamples.last else {
            currentPace = nil
            return
        }
        let meters = last.distance - first.distance
        let seconds = last.time - first.time
        currentPace = meters > 20 && seconds > 5 ? seconds / meters * 1000 : nil
    }

    private var isStepComplete: Bool {
        guard let step = currentStep else { return false }
        switch step.goal {
        case .time(let seconds): return stepElapsed >= seconds
        case .distance(let meters): return stepDistance >= meters
        case .open: return false
        }
    }

    private func advance() {
        stepIndex += 1
        stepElapsed = 0
        stepDistance = 0
        cues = StepCues()
        guard let step = currentStep else {
            finish()
            return
        }
        voice.say(RunSpeech.intro(step, next: nextStep))
    }

    // MARK: - Röstcues

    private func speakCues() {
        guard let step = currentStep else { return }
        switch step.goal {
        case .time(let seconds):
            let remaining = seconds - stepElapsed
            if step.kind == .work, seconds >= 240, !cues.halfway, stepElapsed >= seconds / 2 {
                cues.halfway = true
                voice.say("Halvvägs.")
            }
            if seconds >= 90, !cues.thirtySeconds, remaining <= 30 {
                cues.thirtySeconds = true
                voice.say(RunSpeech.thirtySecondsLeft(next: nextStep))
            }
            if seconds >= 20, !cues.countdown, remaining <= 3.5 {
                cues.countdown = true
                voice.say("Tre, två, ett.")
            }
        case .distance(let meters):
            if meters >= 400, !cues.lastMeters, meters - stepDistance <= 100 {
                cues.lastMeters = true
                voice.say("100 meter kvar.")
            }
        case .open:
            break
        }
        checkPace(step)
        checkHeartRate(step)
    }

    /// Under steg med pulsmål: säg till om pulsen ligger utanför, högst en gång i minuten. Pulsen
    /// släpar efter ansträngningen, så första kontrollen görs efter en minut.
    private func checkHeartRate(_ step: RunStep) {
        guard let target = step.target, let bpm = heartRate,
              let range = targetRange(target),
              stepElapsed >= 60, stepElapsed - cues.lastHeartRateCheck >= 60,
              stepElapsed - cues.lastPaceCheck >= 20
        else { return }
        cues.lastHeartRateCheck = stepElapsed
        let margin = 3.0
        if bpm > range.upperBound + margin {
            voice.say("Pulsen är \(Int(bpm.rounded())), lite hög. Sänk tempot.")
        } else if bpm < range.lowerBound - margin, step.kind == .work {
            voice.say("Pulsen är \(Int(bpm.rounded())). Du kan öka lite.")
        }
    }

    private func targetRange(_ target: PlanStep) -> ClosedRange<Double>? {
        switch target.targetType {
        case .heartRateRange where target.targetHigh > target.targetLow:
            return target.targetLow...target.targetHigh
        case .heartRateZone:
            let zone = min(5, max(1, Int(target.targetLow.rounded())))
            return zones.indices.contains(zone - 1) ? zones[zone - 1] : nil
        default:
            return nil
        }
    }

    /// Under steg med tempomål: säg till om tempot ligger utanför, högst en gång i minuten.
    private func checkPace(_ step: RunStep) {
        guard let target = step.target, target.targetType == .pace, let pace = currentPace,
              stepElapsed >= 45, stepElapsed - cues.lastPaceCheck >= 60
        else { return }
        cues.lastPaceCheck = stepElapsed
        let margin = 5.0
        if pace < target.targetLow - margin {
            voice.say("Lite för snabbt, \(RunSpeech.pace(pace)). Sikta på \(RunSpeech.paceRange(target)).")
        } else if pace > target.targetHigh + margin {
            voice.say("Lite för långsamt, \(RunSpeech.pace(pace)). Öka till \(RunSpeech.paceRange(target)).")
        }
    }
}

/// Talar på svenska i hörlurarna och sänker musiken medan rösten hörs.
@MainActor
final class RunVoice: NSObject, AVSpeechSynthesizerDelegate {
    /// Vald röst (identifier) i UserDefaults; tom = bästa installerade svenska rösten.
    nonisolated static let preferenceKey = "runVoiceIdentifier"

    private let synthesizer = AVSpeechSynthesizer()

    /// Installerade svenska röster, bästa kvaliteten först. Förbättrade och Premium-röster laddas ner
    /// under Inställningar → Hjälpmedel → Uppläst innehåll → Röster → Svenska.
    static var swedishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("sv") }
            .sorted { $0.quality != $1.quality ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name }
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Förbättrad"
        default: "Standard"
        }
    }

    /// Den valda rösten om den finns kvar, annars den bästa svenska.
    private var voice: AVSpeechSynthesisVoice? {
        let identifier = UserDefaults.standard.string(forKey: Self.preferenceKey) ?? ""
        if !identifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        return Self.swedishVoices.first ?? AVSpeechSynthesisVoice(language: "sv-SE")
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
    }

    /// Provlyssning i löpskärmen innan passet startar.
    func preview() {
        synthesizer.stopSpeaking(at: .immediate)
        say("Hej! Jag är din röstcoach. Intervall 1 av 4, fyra minuter. Tempo 5 och 10 per kilometer.")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivate()
    }

    private func deactivate() {
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Musiken går upp igen när kön är tom.
        Task { @MainActor in self.deactivate() }
    }
}

/// GPS-distans under passet. Bara punkter med god noggrannhet räknas.
@MainActor
final class RunLocationTracker: NSObject, CLLocationManagerDelegate {
    var onDistance: ((Double) -> Void)?
    var onDenied: (() -> Void)?

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        // Kräver bakgrundsläget "location" i Info.plist (project.yml).
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        lastLocation = nil
    }

    /// Efter paus: räkna inte sträckan som avverkats under pausen.
    func resetLastLocation() {
        lastLocation = nil
    }

    private func handle(_ locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy > 0 && location.horizontalAccuracy <= 25 {
            if let last = lastLocation {
                let meters = location.distance(from: last)
                // Orimliga hopp (sämre GPS-fix) räknas inte.
                if meters < 100 { onDistance?(meters) }
            }
            lastLocation = location
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.handle(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .denied || status == .restricted { self.onDenied?() }
        }
    }
}
