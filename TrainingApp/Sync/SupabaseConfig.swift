import Foundation

/// Läser Supabase-inställningar som byggs in i Info.plist från Config/Secrets.xcconfig.
struct SupabaseConfig {
    let url: URL
    let publishableKey: String

    static func load(from bundle: Bundle = .main) -> SupabaseConfig? {
        guard
            let host = bundle.object(forInfoDictionaryKey: "SupabaseHost") as? String,
            let key = bundle.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
            !host.isEmpty, !key.isEmpty,
            let url = URL(string: "https://\(host)")
        else { return nil }
        return SupabaseConfig(url: url, publishableKey: key)
    }
}
