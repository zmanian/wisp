import SwiftData
import SwiftUI

@main
struct WispApp: App {
    private let sharedModelContainer: ModelContainer
    @State private var apiClient = SpritesAPIClient()
    @State private var browserCoordinator = InAppBrowserCoordinator()
    @State private var chatSessionManager = ChatSessionManager()
    @State private var shareIntentCoordinator = ShareIntentCoordinator()
    @AppStorage("theme") private var theme: String = "system"

    init() {
        do {
            sharedModelContainer = try ModelContainer(for: SpriteChat.self, SpriteSession.self, QuickMessage.self)
        } catch {
            fatalError("Failed to initialize model container: \(error)")
        }

        UserDefaults.standard.register(defaults: [
            "claudeQuestionTool": true,
            "worktreePerChat": true,
        ])

        KeychainService.shared.migrateAccessibility()
    }

    private var preferredColorScheme: ColorScheme? {
        switch theme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(apiClient)
                .environment(browserCoordinator)
                .environment(chatSessionManager)
                .environment(shareIntentCoordinator)
                .preferredColorScheme(preferredColorScheme)
                .onChange(of: apiClient.isAuthenticated, initial: true) {
                    browserCoordinator.authToken = apiClient.spritesToken
                }
                .onOpenURL { url in
                    guard url.scheme == "wisp" else { return }
                    shareIntentCoordinator.handleURL(url)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
