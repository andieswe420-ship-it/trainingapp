import Foundation
import Observation
import Supabase

/// Inloggning och synk till Supabase. Enda stället i appen som pratar med SupabaseClient.
@MainActor
@Observable
final class SyncService {
    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    private(set) var userEmail: String?
    private(set) var syncState: SyncState = .idle
    private(set) var lastSyncedAt: Date?

    var isConfigured: Bool { client != nil }
    var isSignedIn: Bool { userEmail != nil }

    fileprivate let client: SupabaseClient?
    private static let lastSyncKey = "lastSyncedAt"
    private static let batchSize = 500

    init() {
        client = SupabaseConfig.load().map {
            SupabaseClient(
                supabaseURL: $0.url,
                supabaseKey: $0.publishableKey,
                // Nya beteendet: den lokalt sparade sessionen skickas direkt vid start, även om den
                // hunnit gå ut. Klienten förnyar den själv; misslyckas det kommer en utloggning.
                options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
            )
        }
        userEmail = client?.auth.currentUser?.email
        lastSyncedAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    /// Håller `userEmail` uppdaterad när sessionen ändras (inloggning, utloggning, utgången token).
    func observeAuthChanges() async {
        guard let client else { return }
        for await (_, session) in client.auth.authStateChanges {
            userEmail = session?.user.email
        }
    }

    // MARK: - Konto

    func signIn(email: String, password: String) async throws {
        guard let client else { throw SyncError.notConfigured }
        let session = try await client.auth.signIn(email: email, password: password)
        userEmail = session.user.email
    }

    /// Skapar konto. Returnerar `true` om e-postbekräftelse krävs innan inloggning.
    func signUp(email: String, password: String) async throws -> Bool {
        guard let client else { throw SyncError.notConfigured }
        let response = try await client.auth.signUp(email: email, password: password)
        guard let session = response.session else { return true }
        userEmail = session.user.email
        return false
    }

    func signOut() async {
        try? await client?.auth.signOut()
        userEmail = nil
    }

    // MARK: - Synk

    /// Laddar upp pass, mätningar och dagsvärden. Idempotent: upsert på HealthKit-UUID respektive datum.
    /// Efter en lyckad synk får coachen chansen att fråga om ett nytt pass.
    /// Returnerar `true` om coachen började formulera en fråga om ett nytt pass.
    @discardableResult
    func sync(workouts: [WorkoutSummary], samples: [HealthSample], daily: [DailyMetrics]) async -> Bool {
        guard let client, isSignedIn else { return false }
        guard syncState != .syncing else { return false }
        syncState = .syncing
        do {
            for batch in workouts.map(WorkoutRecord.init).chunked(into: Self.batchSize) {
                try await client.from("workouts").upsert(batch, onConflict: "id").execute()
            }
            for batch in samples.map(HealthSampleRecord.init).chunked(into: Self.batchSize) {
                try await client.from("health_samples").upsert(batch, onConflict: "id").execute()
            }
            for batch in daily.map(DailyMetricsRecord.init).chunked(into: Self.batchSize) {
                try await client.from("daily_metrics").upsert(batch, onConflict: "user_id,date").execute()
            }
            let now = Date()
            lastSyncedAt = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
            syncState = .idle
        } catch {
            syncState = .failed(error.localizedDescription)
            return false
        }
        return (try? await requestCheckin()) ?? false
    }
}

// MARK: - Veckoplan

extension SyncService {
    /// Beställer en ny veckoplan. Planen genereras i bakgrunden – hämta den med `fetchPlan(id:)`.
    func requestPlan(notes: String) async throws -> UUID {
        guard let client else { throw SyncError.notConfigured }
        guard isSignedIn else { throw SyncError.notSignedIn }
        struct Body: Encodable { let notes: String }
        struct Response: Decodable { let id: UUID }
        let response: Response = try await client.functions.invoke(
            "plan-week",
            options: FunctionInvokeOptions(body: Body(notes: notes))
        )
        return response.id
    }

    func fetchPlan(id: UUID) async throws -> TrainingPlan? {
        guard let client else { throw SyncError.notConfigured }
        let plans: [TrainingPlan] = try await client.from("training_plans")
            .select()
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value
        return plans.first
    }

    func fetchLatestPlan() async throws -> TrainingPlan? {
        guard let client else { throw SyncError.notConfigured }
        let plans: [TrainingPlan] = try await client.from("training_plans")
            .select()
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return plans.first
    }
}

// MARK: - Coach

extension SyncService {
    private struct CoachRequest: Encodable {
        let action: String
        var text: String?
        var messageId: UUID?
        var accept: Bool?

        enum CodingKeys: String, CodingKey {
            case action, text, accept
            case messageId = "message_id"
        }
    }

    private struct CoachResponse: Decodable {
        var created: Bool?
    }

    func sendCoachMessage(_ text: String) async throws {
        _ = try await invokeCoach(CoachRequest(action: "send", text: text))
    }

    /// Ber coachen fråga om det senaste passet, om den inte redan gjort det.
    /// Returnerar `true` om en ny fråga skapades.
    @discardableResult
    func requestCheckin() async throws -> Bool {
        try await invokeCoach(CoachRequest(action: "checkin")).created ?? false
    }

    func decideProposal(messageId: UUID, accept: Bool) async throws {
        _ = try await invokeCoach(CoachRequest(action: "decide", messageId: messageId, accept: accept))
    }

    func fetchCoachMessages(limit: Int = 100) async throws -> [CoachMessage] {
        guard let client else { throw SyncError.notConfigured }
        let messages: [CoachMessage] = try await client.from("coach_messages")
            .select()
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return messages.reversed()
    }

    private func invokeCoach(_ request: CoachRequest) async throws -> CoachResponse {
        guard let client else { throw SyncError.notConfigured }
        guard isSignedIn else { throw SyncError.notSignedIn }
        return try await client.functions.invoke(
            "coach",
            options: FunctionInvokeOptions(body: request)
        )
    }
}

// MARK: - Profil

extension SyncService {
    func fetchProfile() async throws -> AthleteProfile {
        guard let client else { throw SyncError.notConfigured }
        let profiles: [AthleteProfile] = try await client.from("athlete_profiles")
            .select()
            .limit(1)
            .execute()
            .value
        return profiles.first ?? .empty
    }

    func saveProfile(_ profile: AthleteProfile) async throws {
        guard let client else { throw SyncError.notConfigured }
        try await client.from("athlete_profiles").upsert(profile, onConflict: "user_id").execute()
    }
}

enum SyncError: LocalizedError {
    case notConfigured
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Supabase är inte konfigurerat. Skapa Config/Secrets.xcconfig och bygg om appen."
        case .notSignedIn:
            "Du behöver logga in först."
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
