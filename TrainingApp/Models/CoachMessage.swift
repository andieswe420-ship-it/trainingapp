import Foundation

/// En rad i tabellen `coach_messages`.
struct CoachMessage: Decodable, Identifiable, Hashable, Sendable {
    enum Role: String, Decodable, Sendable { case user, assistant }
    enum Status: String, Decodable, Sendable { case pending, done, failed }
    enum ProposalStatus: String, Decodable, Sendable { case pending, accepted, rejected }

    let id: UUID
    let role: Role
    let content: String
    let status: Status
    /// Passet som en fråga efter pass gäller.
    let workoutId: UUID?
    let proposal: CoachProposal?
    let proposalStatus: ProposalStatus?
    /// Satt när coachen uppdaterade profilen i samband med svaret.
    let profileUpdate: ProfileUpdate?
    /// Satt när coachen sparade en anteckning om ett genomfört pass.
    let workoutNote: ProfileUpdate?
    let error: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, role, content, status, proposal, error
        case workoutId = "workout_id"
        case proposalStatus = "proposal_status"
        case profileUpdate = "profile_update"
        case workoutNote = "workout_note"
        case createdAt = "created_at"
    }

    struct ProfileUpdate: Decodable, Hashable, Sendable {
        let summary: String
    }
}

/// Coachens förslag: hela listan av pass för perioden ersätter planens pass där.
struct CoachProposal: Decodable, Hashable, Sendable {
    let reason: String
    let windowStart: String
    let windowEnd: String
    let workouts: [PlannedWorkout]

    enum CodingKeys: String, CodingKey {
        case reason, workouts
        case windowStart = "window_start"
        case windowEnd = "window_end"
    }

    /// Alla dagar i perioden (YYYY-MM-DD), även vilodagar.
    var days: [String] {
        guard let start = PlanDate.date(from: windowStart), let end = PlanDate.date(from: windowEnd) else { return [] }
        var result: [String] = []
        var day = start
        while day <= end {
            result.append(PlanDate.string(from: day))
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}
