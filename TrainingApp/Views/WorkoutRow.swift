import SwiftUI

struct WorkoutRow: View {
    let workout: WorkoutSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(workout.activityName)
                    .font(.headline)
                Text(workout.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Label(Self.durationText(workout.duration), systemImage: "clock")
                Label(heartRateText, systemImage: "heart.fill")
                    .foregroundStyle(workout.averageHeartRate == nil ? .secondary : .primary)
            }
            .font(.subheadline.monospacedDigit())
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
                .foregroundStyle(.secondary)
        }
    }
}
