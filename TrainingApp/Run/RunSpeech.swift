import Foundation

/// Det röstcoachen säger, och tider/distanser för visning under passet.
enum RunSpeech {
    static func intro(_ step: RunStep, next: RunStep?) -> String {
        var parts: [String] = []
        switch step.kind {
        case .warmup:
            parts.append("Uppvärmning, \(goal(step.goal)). Lugnt tempo.")
        case .work:
            if let repetition = step.repetition {
                parts.append("Intervall \(repetition.index) av \(repetition.count), \(goal(step.goal)).")
            } else {
                parts.append("\(goal(step.goal)).")
            }
            if let target = step.target { parts.append(targetText(target)) }
            if !step.description.isEmpty { parts.append(step.description) }
        case .recovery:
            parts.append("Vila, \(goal(step.goal)).")
            if let target = step.target { parts.append(targetText(target)) }
        case .cooldown:
            parts.append("Nedvarvning, \(goal(step.goal)). Ta det lugnt.")
        }
        if case .open = step.goal {
            parts.append("Tryck på Nästa när du är klar.")
        }
        return parts.joined(separator: " ")
    }

    static func thirtySecondsLeft(next: RunStep?) -> String {
        guard let next else { return "30 sekunder kvar." }
        return "30 sekunder kvar, sedan \(shortName(next))."
    }

    static func kilometer(_ kilometers: Int, pace: Double?) -> String {
        let distance = kilometers == 1 ? "En kilometer" : "\(kilometers) kilometer"
        guard let pace else { return "\(distance)." }
        return "\(distance). Tempo \(self.pace(pace))."
    }

    static func summary(time: TimeInterval, distance: Double?) -> String {
        var text = "Passet är klart, bra jobbat! \(duration(time))"
        if let distance, distance > 100 {
            text += " och \(distanceSpoken(distance))"
        }
        return text + ". Glöm inte att avsluta passet på klockan."
    }

    /// "5 och 10 per kilometer", som löpare säger det.
    static func pace(_ secondsPerKm: Double) -> String {
        let total = Int(secondsPerKm.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return seconds == 0 ? "\(minutes) blankt per kilometer" : "\(minutes) och \(seconds) per kilometer"
    }

    static func paceRange(_ target: PlanStep) -> String {
        let low = Int(target.targetLow.rounded())
        let high = Int(target.targetHigh.rounded())
        func spoken(_ total: Int) -> String {
            total % 60 == 0 ? "\(total / 60) blankt" : "\(total / 60) och \(total % 60)"
        }
        return "\(spoken(low)) till \(spoken(high)) per kilometer"
    }

    // MARK: - Visning

    /// "4:05" eller "1:02:30".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func distanceShort(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f km", meters / 1000) : "\(Int(meters.rounded())) m"
    }

    static func paceShort(_ secondsPerKm: Double?) -> String {
        guard let secondsPerKm else { return "–" }
        let total = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d/km", total / 60, total % 60)
    }

    static func title(_ step: RunStep) -> String {
        switch step.kind {
        case .warmup: "Uppvärmning"
        case .cooldown: "Nedvarvning"
        case .recovery: "Vila"
        case .work:
            if let repetition = step.repetition {
                "Intervall \(repetition.index)/\(repetition.count)"
            } else {
                "Huvuddel"
            }
        }
    }

    static func targetLabel(_ step: RunStep) -> String? {
        guard let target = step.target else { return nil }
        return PlannedWorkoutRow.targetText(target)
    }

    // MARK: - Hjälpfunktioner

    private static func shortName(_ step: RunStep) -> String {
        switch step.kind {
        case .warmup: "uppvärmning"
        case .cooldown: "nedvarvning, \(goal(step.goal))"
        case .recovery: "vila, \(goal(step.goal))"
        case .work:
            if let repetition = step.repetition {
                "intervall \(repetition.index) av \(repetition.count)"
            } else {
                goal(step.goal)
            }
        }
    }

    private static func goal(_ goal: RunStep.Goal) -> String {
        switch goal {
        case .time(let seconds): duration(seconds)
        case .distance(let meters): distanceSpoken(meters)
        case .open: "öppet"
        }
    }

    private static func targetText(_ target: PlanStep) -> String {
        switch target.targetType {
        case .none:
            ""
        case .heartRateZone:
            "Puls i zon \(Int(target.targetLow.rounded()))."
        case .heartRateRange:
            "Puls \(Int(target.targetLow.rounded())) till \(Int(target.targetHigh.rounded()))."
        case .pace:
            "Tempo \(paceRange(target))."
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        let minuteText = minutes == 1 ? "en minut" : "\(minutes) minuter"
        if minutes == 0 { return "\(secs) sekunder" }
        if secs == 0 { return minuteText }
        return "\(minuteText) och \(secs) sekunder"
    }

    private static func distanceSpoken(_ meters: Double) -> String {
        guard meters >= 1000 else { return "\(Int((meters / 10).rounded()) * 10) meter" }
        let km = (meters / 100).rounded() / 10
        if km == km.rounded() { return km == 1 ? "en kilometer" : "\(Int(km)) kilometer" }
        return "\(String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",")) kilometer"
    }
}
