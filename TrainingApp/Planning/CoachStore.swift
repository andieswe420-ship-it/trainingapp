import Foundation
import Observation

/// Chatten med coachen: hämtar meddelanden, skickar nya och väntar in svar som genereras i bakgrunden.
@MainActor
@Observable
final class CoachStore {
    private(set) var messages: [CoachMessage] = []
    private(set) var isSending = false
    private(set) var deciding: Set<UUID> = []
    private(set) var errorMessage: String?
    /// Sätts av chattvyn så att nya svar räknas som lästa medan den visas.
    var isVisible = false {
        didSet { if isVisible { markSeen() } }
    }

    var hasPendingReply: Bool { messages.contains { $0.status == .pending } }

    /// Antal svar från coachen sedan chatten senast visades.
    var unreadCount: Int {
        messages.filter { $0.role == .assistant && $0.status == .done && $0.createdAt > lastSeen }.count
    }

    private let sync: SyncService
    private var pollTask: Task<Void, Never>?
    private var lastSeen: Date {
        didSet { UserDefaults.standard.set(lastSeen, forKey: Self.lastSeenKey) }
    }

    private static let lastSeenKey = "coachLastSeen"
    private static let pollInterval: Duration = .seconds(2)
    private static let maxPolls = 120

    init(sync: SyncService) {
        self.sync = sync
        lastSeen = UserDefaults.standard.object(forKey: Self.lastSeenKey) as? Date ?? .distantPast
    }

    func refresh() async {
        guard sync.isSignedIn else { return }
        do {
            try await fetch()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        if hasPendingReply { startPolling() }
    }

    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await sync.sendCoachMessage(text)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    /// Godkänner eller avböjer ett förslag. Returnerar `true` om planen ändrades.
    @discardableResult
    func decide(_ message: CoachMessage, accept: Bool) async -> Bool {
        deciding.insert(message.id)
        defer { deciding.remove(message.id) }
        do {
            try await sync.decideProposal(messageId: message.id, accept: accept)
            await refresh()
            return accept
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func fetch() async throws {
        messages = try await sync.fetchCoachMessages()
        if isVisible { markSeen() }
    }

    private func markSeen() {
        if let latest = messages.last?.createdAt, latest > lastSeen {
            lastSeen = latest
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            for _ in 0..<Self.maxPolls {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                try? await self.fetch()
                if !self.hasPendingReply { break }
            }
            self?.pollTask = nil
        }
    }
}
