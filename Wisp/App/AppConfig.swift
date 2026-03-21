import Foundation

// MARK: - App Configuration
// Fork this project? Update these values for your own deployment.

enum ClaudeChatTransportMode: String, CaseIterable, Identifiable, Sendable {
    case exec
    case channels

    static let defaultsKey = "chatTransportMode"

    var id: String { rawValue }

    static var current: ClaudeChatTransportMode {
        ClaudeChatTransportMode(
            rawValue: UserDefaults.standard.string(forKey: defaultsKey)
                ?? ClaudeChatTransportMode.exec.rawValue
        ) ?? .exec
    }

    var displayName: String {
        switch self {
        case .exec:
            return "Exec"
        case .channels:
            return "Channels"
        }
    }

    var detailText: String {
        switch self {
        case .exec:
            return "Current WebSocket exec transport."
        case .channels:
            return "Experimental HTTP + SSE groundwork for issue #110."
        }
    }
}

enum AppConfig {
    /// GitHub OAuth App client ID (public, not a secret).
    /// Create your own at: https://github.com/settings/applications/new
    /// - Set "Device flow" enabled
    /// - No callback URL needed
    static let githubClientID = "Ov23lix0yTawxu7UQ7FH"
}
