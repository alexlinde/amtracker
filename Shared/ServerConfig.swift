import Foundation

/// Push-server configuration, read from Info.plist (populated from Config/Secrets.xcconfig).
enum ServerConfig {
    static var baseURL: URL? {
        guard let s = value("AMTRACKER_SERVER_URL"), let u = URL(string: s), u.scheme != nil else { return nil }
        return u
    }
    static var sharedSecret: String? { value("AMTRACKER_SHARED_SECRET") }
    static var isConfigured: Bool { baseURL != nil && sharedSecret != nil }

    /// Compile-time switch: Xcode-run (DEBUG) builds use the APNs sandbox; TestFlight/App Store builds use production.
    #if DEBUG
    static let apnsEnv = "development"
    #else
    static let apnsEnv = "production"
    #endif

    private static func value(_ key: String) -> String? {
        let v = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unexpanded "$(VAR)" means the xcconfig value is unset.
        guard let v, !v.isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
    }
}
