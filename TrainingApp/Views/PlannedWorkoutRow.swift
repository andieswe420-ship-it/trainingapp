import SwiftUI

/// Ett planerat pass med uppvärmning, block/steg och nedvarvning.
struct PlannedWorkoutRow: View {
    let workout: PlannedWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: workout.activity.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.title)
                        .font(.headline)
                    Text("\(workout.activity.swedishName) · \(workout.intensity.label) · ca \(Int(workout.estimatedMinutes.rounded())) min")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(workout.description)
                .font(.callout)

            VStack(alignment: .leading, spacing: 4) {
                if workout.warmupMinutes > 0 {
                    stepLine("Uppvärmning \(Int(workout.warmupMinutes)) min", symbol: "flame")
                }
                ForEach(Array(workout.blocks.enumerated()), id: \.offset) { _, block in
                    let iterations = Int(block.iterations.rounded())
                    if iterations > 1 {
                        Text("\(iterations) ×")
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(Array(block.steps.enumerated()), id: \.offset) { _, step in
                        stepLine(Self.stepText(step), symbol: step.purpose == .work ? "bolt.fill" : "pause.circle")
                            .padding(.leading, iterations > 1 ? 12 : 0)
                    }
                }
                if workout.cooldownMinutes > 0 {
                    stepLine("Nedvarvning \(Int(workout.cooldownMinutes)) min", symbol: "wind")
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    private func stepLine(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
    }

    static func stepText(_ step: PlanStep) -> String {
        var parts = [goalText(step)]
        if let target = targetText(step) { parts.append(target) }
        if !step.description.isEmpty { parts.append(step.description) }
        return parts.joined(separator: " · ")
    }

    static func goalText(_ step: PlanStep) -> String {
        switch step.goalType {
        case .time:
            let seconds = Int(step.goalValue.rounded())
            if seconds % 60 == 0 { return "\(seconds / 60) min" }
            if seconds > 60 { return "\(seconds / 60) min \(seconds % 60) s" }
            return "\(seconds) s"
        case .distance:
            let meters = step.goalValue
            if meters >= 1000 {
                let km = meters / 1000
                return km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km)
            }
            return "\(Int(meters.rounded())) m"
        case .open:
            return "Öppet"
        }
    }

    static func targetText(_ step: PlanStep) -> String? {
        switch step.targetType {
        case .none:
            return nil
        case .heartRateZone:
            return "zon \(Int(step.targetLow.rounded()))"
        case .heartRateRange:
            return "\(Int(step.targetLow.rounded()))–\(Int(step.targetHigh.rounded())) bpm"
        case .pace:
            return "\(pace(step.targetLow))–\(pace(step.targetHigh))/km"
        }
    }

    private static func pace(_ secondsPerKm: Double) -> String {
        let total = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
