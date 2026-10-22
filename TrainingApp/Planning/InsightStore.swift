import Foundation
import Observation

/// AI-analysen av trenderna per period. Analysen skapas en gång per dag och period på servern.
@MainActor
@Observable
final class InsightStore {
    private(set) var insights: [TrendPeriod: TrendInsight] = [:]
    private(set) var loading: Set<TrendPeriod> = []
    private(set) var errors: [TrendPeriod: String] = [:]

    private let sync: SyncService
    private static let pollInterval: Duration = .seconds(3)
    private static let maxPolls = 100

    init(sync: SyncService) {
        self.sync = sync
    }

    /// Hämtar dagens analys (eller beställer en). `force` skapar en ny även om en finns.
    func load(_ period: TrendPeriod, snapshot: TrendSnapshot, force: Bool = false) async {
        guard sync.isSignedIn, !loading.contains(period) else { return }
        if !force, let existing = insights[period], existing.status == .ready,
           Calendar.current.isDateInToday(existing.updatedAt) {
            return
        }
        loading.insert(period)
        errors[period] = nil
        defer { loading.remove(period) }

        do {
            let id = try await sync.requestInsight(period: period.rawValue, snapshot: snapshot, force: force)
            for _ in 0..<Self.maxPolls {
                if let insight = try await sync.fetchInsight(id: id) {
                    insights[period] = insight
                    if insight.status != .pending { return }
                }
                try await Task.sleep(for: Self.pollInterval)
            }
            errors[period] = "Analysen tar ovanligt lång tid. Försök igen om en stund."
        } catch is CancellationError {
            return
        } catch {
            errors[period] = error.localizedDescription
        }
    }
}
