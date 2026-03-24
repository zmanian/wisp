import SwiftUI

struct QuickActionsView: View {
    @Environment(SpritesAPIClient.self) private var apiClient
    @Environment(\.dismiss) private var dismiss
    let viewModel: QuickActionsViewModel
    var insertCallback: ((String) -> Void)? = nil
    var startChatCallback: ((String) -> Void)? = nil

    var body: some View {
        NavigationStack {
            bashContent
                .navigationTitle("Quick Actions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: handleDone) {
                            Image(systemName: "xmark")
                        }
                    }
                }
        }
    }

    @ViewBuilder private var bashContent: some View {
        if let cb = insertCallback {
            BashQuickView(viewModel: viewModel.bashViewModel, onInsert: { text in
                cb(text)
                dismiss()
            })
        } else if let cb = startChatCallback {
            BashQuickView(viewModel: viewModel.bashViewModel, onStartChat: { text in
                cb(text)
                dismiss()
            })
        } else {
            BashQuickView(viewModel: viewModel.bashViewModel)
        }
    }

    private func handleDone() {
        viewModel.bashViewModel.cancel(apiClient: apiClient)
        dismiss()
    }
}

#Preview {
    QuickActionsView(
        viewModel: QuickActionsViewModel(
            spriteName: "my-sprite",
            workingDirectory: "/home/sprite/project"
        )
    )
    .environment(SpritesAPIClient())
}
