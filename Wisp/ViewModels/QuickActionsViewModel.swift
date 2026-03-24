import Foundation

@Observable
@MainActor
final class QuickActionsViewModel: Identifiable {
    let id = UUID()
    let spriteName: String
    let workingDirectory: String

    let bashViewModel: BashQuickViewModel

    init(spriteName: String, sessionId: String? = nil, workingDirectory: String) {
        self.spriteName = spriteName
        self.workingDirectory = workingDirectory
        self.bashViewModel = BashQuickViewModel(
            spriteName: spriteName,
            workingDirectory: workingDirectory
        )
    }
}
