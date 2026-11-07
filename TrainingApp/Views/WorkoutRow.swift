import SwiftUI

struct WorkoutRow: View {
    let workout: WorkoutSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.symbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.cyan)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Theme.cyan.opacity(0.14)))

            VStack(alignment: .leading, spacing: 4) {
                Text(workout.activityName)
                    .font(.headline)
                Text(workout.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Label(Self.durationText(workout.duration), systemImage: "clock")
                if let distance = workout.distanceMeters, distance > 100 {
                    Label(String(format: "%.1f km", distance / 1000), systemImage: "location.north.fill")
                }
                Label(heartRateText, systemImage: "heart.fill")
                    .foregroundStyle(workout.averageHeartRate == nil ? .secondary : .primary)
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
            .labelStyle(TrailingIconLabelStyle())
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var heartRateText: String {
        guard let bpm = workout.averageHeartRate else { return "– bpm" }
        return "\(Int(bpm.rounded())) bpm"
    }

    static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
                .font(.caption)
                .foregroundStyle(Theme.cyan.opacity(0.8))
        }
    }
}
