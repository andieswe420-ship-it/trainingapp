import SwiftUI

/// Röstcoachat löppass: telefonen leder passet steg för steg i hörlurarna.
struct RunView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: RunSession

    init(workout: PlannedWorkout, maxHeartRate: Double?) {
        _session = State(initialValue: RunSession(workout: workout, maxHeartRate: maxHeartRate))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if session.state == .finished {
                    finishedView
                } else {
                    stepView
                    statsView
                    Spacer()
                    controls
                }
            }
            .padding()
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

    @ViewBuilder
    private var stepView: some View {
        if let step = session.currentStep {
            VStack(spacing: 8) {
                Text(RunSpeech.title(step))
                    .font(.title2.weight(.semibold))
                Text(session.stepRemaining)
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let target = RunSpeech.targetLabel(step) {
                    Label(target, systemImage: "target")
                        .font(.headline)
                }
                if !step.description.isEmpty {
                    Text(step.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Text("Steg \(session.stepIndex + 1) av \(session.steps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let next = session.nextStep {
                    Text("Sedan: \(RunSpeech.title(next))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statsView: some View {
        HStack {
            stat("Tid", RunSpeech.clock(session.totalElapsed))
            if session.watchStarted || session.heartRate != nil {
                stat("Puls", session.heartRate.map { "\(Int($0.rounded()))" } ?? "–")
            }
            if session.usesGPS {
                stat("Distans", RunSpeech.distanceShort(session.totalDistance))
                stat("Tempo", RunSpeech.paceShort(session.currentPace))
            }
        }
        .overlay(alignment: .bottom) {
            if session.locationDenied && session.usesGPS {
                Text("Platstjänster är avstängda – tempo och distans mäts inte.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .offset(y: 24)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var controls: some View {
        switch session.state {
        case .ready:
            VStack(spacing: 12) {
                Text("Klockappen startar passet automatiskt, skickar pulsen hit och sparar passet i Hälsa – starta inte Träning-appen samtidigt. Ta på dig hörlurarna; rösten sänker musiken när den pratar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    session.start()
                } label: {
                    Label("Starta", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .running, .paused:
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        session.state == .running ? session.pause() : session.resume()
                    } label: {
                        Label(session.state == .running ? "Pausa" : "Fortsätt",
                              systemImage: session.state == .running ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        session.skip()
                    } label: {
                        Label("Nästa", systemImage: "forward.end.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                Button("Avsluta passet", role: .destructive) {
                    session.finish()
                }
            }
        case .finished:
            EmptyView()
        }
    }

    private var finishedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Passet är klart")
                .font(.title.weight(.bold))
            statsView
            Text(session.watchStarted
                 ? "Passet sparas från klockan. När det har synkats frågar coachen hur det kändes."
                 : "Avsluta passet på klockan. När det har synkats frågar coachen hur det kändes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                session.stop()
                dismiss()
            } label: {
                Text("Klar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
