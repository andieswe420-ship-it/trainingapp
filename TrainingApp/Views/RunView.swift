import SwiftUI

/// Röstcoachat löppass: telefonen leder passet steg för steg i hörlurarna. Stegets tid eller sträcka
/// fylls som ringen i appikonen.
struct RunView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: RunSession
    @AppStorage(RunVoice.preferenceKey) private var voiceIdentifier = ""

    init(workout: PlannedWorkout, maxHeartRate: Double?) {
        _session = State(initialValue: RunSession(workout: workout, maxHeartRate: maxHeartRate))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if session.state == .finished {
                    finishedView
                } else {
                    stepRing
                    statsCard
                    Spacer(minLength: 0)
                    controls
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedScreen()
            .navigationTitle(session.workout.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if session.state == .ready || session.state == .finished {
                        Button("Stäng") {
                            session.stop()
                            dismiss()
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(session.state == .running || session.state == .paused)
    }

    // MARK: - Steget

    @ViewBuilder
    private var stepRing: some View {
        if let step = session.currentStep {
            VStack(spacing: 14) {
                ZStack {
                    ProgressRing(progress: session.stepProgress, lineWidth: 16)
                    VStack(spacing: 6) {
                        Text(RunSpeech.title(step).uppercased())
                            .font(.caption.weight(.semibold))
                            .tracking(1.5)
                            .foregroundStyle(Theme.cyan)
                        Text(session.stepRemaining)
                            .font(Theme.metric(64))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        if let target = RunSpeech.targetLabel(step) {
                            Label(target, systemImage: "target")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        if session.state == .paused {
                            Text("PAUSAT")
                                .font(.caption.weight(.bold))
                                .tracking(1.5)
                                .foregroundStyle(.yellow)
                        }
                    }
                    .padding(32)
                }
                .frame(maxWidth: 300)
                .aspectRatio(1, contentMode: .fit)
                .padding(.top, 8)

                if !step.description.isEmpty {
                    Text(step.description)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 6) {
                    Text("Steg \(session.stepIndex + 1) av \(session.steps.count)")
                    if let next = session.nextStep {
                        Text("·")
                        Text("Sedan: \(RunSpeech.title(next))")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: - Nyckeltal

    private var statsCard: some View {
        VStack(spacing: 8) {
            HStack {
                MetricView(value: RunSpeech.clock(session.totalElapsed), label: "Tid")
                if session.watchStarted || session.heartRate != nil {
                    MetricView(value: session.heartRate.map { "\(Int($0.rounded()))" } ?? "–", label: "Puls")
                }
                if session.usesGPS {
                    MetricView(value: RunSpeech.distanceShort(session.totalDistance), label: "Distans")
                    MetricView(value: RunSpeech.paceShort(session.currentPace), label: "Tempo")
                }
            }
            if session.locationDenied && session.usesGPS {
                Text("Platstjänster är avstängda – tempo och distans mäts inte.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .card()
    }

    // MARK: - Knappar

    @ViewBuilder
    private var controls: some View {
        switch session.state {
        case .ready:
            VStack(spacing: 14) {
                voicePicker
                Text("Runner's High på klockan startar passet automatiskt, skickar pulsen hit och sparar passet i Hälsa – starta inte Apples Träning-app samtidigt. Ta på dig hörlurarna; rösten sänker musiken när den pratar.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                Button {
                    session.start()
                } label: {
                    Label("Starta", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        case .running, .paused:
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Button {
                        session.state == .running ? session.pause() : session.resume()
                    } label: {
                        Label(session.state == .running ? "Pausa" : "Fortsätt",
                              systemImage: session.state == .running ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button {
                        session.skip()
                    } label: {
                        Label("Nästa", systemImage: "forward.end.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button("Avsluta passet", role: .destructive) {
                    session.finish()
                }
                .font(.subheadline.weight(.semibold))
            }
        case .finished:
            EmptyView()
        }
    }

    private var voicePicker: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Röst", selection: $voiceIdentifier) {
                    Text("Bästa tillgängliga").tag("")
                    ForEach(RunVoice.swedishVoices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(RunVoice.qualityLabel(voice)))").tag(voice.identifier)
                    }
                }
                .pickerStyle(.menu)
                Spacer(minLength: 0)
                Button {
                    session.previewVoice()
                } label: {
                    Label("Provlyssna", systemImage: "speaker.wave.2")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(Theme.cyan)
            }
            if !RunVoice.swedishVoices.contains(where: { $0.quality != .default }) {
                Text("Låter rösten robotaktig? Ladda ner en svensk röst med kvaliteten Förbättrad eller Premium under Inställningar → Hjälpmedel → Uppläst innehåll → Röster → Svenska.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .card()
    }

    // MARK: - Klart

    private var finishedView: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                ProgressRing(progress: 1, lineWidth: 12)
                Image(systemName: "checkmark")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(Theme.cyan)
            }
            .frame(width: 150, height: 150)
            Text("Passet är klart")
                .font(.title.weight(.bold))
            statsCard
            Text(session.watchStarted
                 ? "Passet sparas från klockan. När det har synkats frågar coachen hur det kändes."
                 : "Avsluta passet på klockan. När det har synkats frågar coachen hur det kändes.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Klar") {
                session.stop()
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}
