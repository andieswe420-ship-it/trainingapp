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

    private let client: SupabaseClient?
    private static let lastSyncKey = "lastSyncedAt"
    private static let batchSize = 500

    init() {
        client = SupabaseConfig.load().map {
            SupabaseClient(supabaseURL: $0.url, supabaseKey: $0.publishableKey)
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

    /// Laddar upp pass och mätningar. Idempotent: upsert på HealthKit-UUID.
    func sync(workouts: [WorkoutSummary], samples: [HealthSample]) async {
        guard let client, isSignedIn else { return }
        guard syncState != .syncing else { return }
        syncState = .syncing
        do {
            for batch in workouts.map(WorkoutRecord.init).chunked(into: Self.batchSize) {
                try await client.from("workouts").upsert(batch, onConflict: "id").execute()
            }
            for batch in samples.map(HealthSampleRecord.init).chunked(into: Self.batchSize) {
                try await client.from("health_samples").upsert(batch, onConflict: "id").execute()
            }
            let now = Date()
            lastSyncedAt = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
            syncState = .idle
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }
}

enum SyncError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Supabase är inte konfigurerat. Skapa Config/Secrets.xcconfig och bygg om appen."
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
