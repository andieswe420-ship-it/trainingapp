import Foundation

/// Meddelanden mellan klockappen och telefonen under ett röstcoachat pass. Skickas över det
/// speglade träningspasset (HKWorkoutSession.sendToRemoteWorkoutSession). Delas av båda apparna.
enum LiveWorkoutMessage: Codable, Sendable {
    /// Klockan → telefonen: senaste pulsen (slag per minut).
    case heartRate(Double)
    /// Telefonen → klockan.
    case pause
    case resume
    /// Åt båda hållen: passet är slut.
    case end

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> LiveWorkoutMessage? {
        try? JSONDecoder().decode(LiveWorkoutMessage.self, from: data)
    }
}
