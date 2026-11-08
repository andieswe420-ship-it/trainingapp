import Foundation

/// Coachens personliga repliker inför ett löppass (Edge Function `run-brief`). Läses upp av
/// röstcoachen: `opening` vid start, `steps` direkt efter respektive stegs instruktion och
/// `finish` när passet är klart.
struct RunBrief: Decodable, Sendable {
    struct StepLine: Decodable, Sendable {
        /// Plats i röstcoachens steglista (`RunSession.steps`).
        let index: Int
        let text: String
    }

    let opening: String
    let steps: [StepLine]
    let finish: String

    func line(forStep index: Int) -> String? {
        steps.first { $0.index == index }?.text
    }
}
