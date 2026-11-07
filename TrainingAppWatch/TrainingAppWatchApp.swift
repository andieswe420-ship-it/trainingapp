import HealthKit
import SwiftUI
import WatchKit

/// Klockappen till röstcoachen: startas av telefonen, kör passet och skickar pulsen live.
@main
struct TrainingAppWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WatchRunView()
                .environment(WatchWorkoutManager.shared)
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// Telefonen öppnade appen med ett pass (`HKHealthStore.startWatchApp`).
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            await WatchWorkoutManager.shared.start(configuration: workoutConfiguration)
        }
    }
}

struct WatchRunView: View {
    @Environment(WatchWorkoutManager.self) private var manager
    @State private var confirmEnd = false

    var body: some View {
        VStack(spacing: 8) {
            switch manager.state {
            case .idle:
                Image(systemName: "headphones")
                    .font(.title)
                Text("Starta passet med Spring med röstcoach i telefonen.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            case .running, .paused:
                running
            case .saving:
                ProgressView("Sparar passet…")
            case .saved:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                Text("Passet är sparat")
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(manager.errorMessage ?? "Något gick fel.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        // Första gången: be om behörighet direkt så att passet kan starta när telefonen ber om det.
        .task { await manager.requestAuthorization() }
    }

    private var running: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text(manager.heartRate.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            if let start = manager.startDate {
                Text(start, style: .timer)
                    .font(.title3)
                    .monospacedDigit()
            }
            if manager.state == .paused {
                Text("Pausat")
                    .foregroundStyle(.yellow)
            }
            Button("Avsluta", role: .destructive) { confirmEnd = true }
                .confirmationDialog("Avsluta passet?", isPresented: $confirmEnd) {
                    Button("Avsluta och spara", role: .destructive) {
                        Task { await manager.endFromWatch() }
                    }
                }
        }
    }
}
