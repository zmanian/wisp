import SwiftUI

struct InAppBrowserSheet: View {
    let initialURL: URL
    var authToken: String?
    @Environment(\.dismiss) private var dismiss
    @State private var state = WebViewState()
    @State private var showDevTools = false

    private var displayTitle: String {
        let host = (state.currentURL ?? initialURL).host() ?? ""
        if host.hasSuffix(".sprites.app"), let name = host.split(separator: ".").first {
            return String(name)
        }
        return host.isEmpty ? initialURL.absoluteString : host
    }

    private var devToolsIndicatorColor: Color? {
        if state.consoleLogs.contains(where: { $0.level == .error }) { return .red }
        if state.networkRequests.contains(where: { ($0.status ?? 0) >= 500 || $0.error != nil }) { return .red }
        if state.consoleLogs.contains(where: { $0.level == .warn }) { return .orange }
        if state.networkRequests.contains(where: { ($0.status ?? 0) >= 400 }) { return .orange }
        if !state.consoleLogs.isEmpty || !state.networkRequests.isEmpty { return .accentColor }
        return nil
    }

    var body: some View {
        NavigationStack {
            WebViewPage(initialURL: initialURL, authToken: authToken, state: state)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showDevTools) {
                    DevToolsDrawer(
                        logs: state.consoleLogs,
                        requests: state.networkRequests,
                        onClearLogs: { state.consoleLogs.removeAll() },
                        onClearRequests: { state.networkRequests.removeAll() }
                    )
                    .presentationDetents([.fraction(0.4), .large])
                    .presentationDragIndicator(.visible)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }

                    ToolbarItem(placement: .status) {
                        if state.isLoading {
                            ProgressView()
                        }
                    }

                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            state.goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!state.canGoBack)

                        Button {
                            state.goForward()
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!state.canGoForward)

                        Spacer()

                        ShareLink(item: state.currentURL ?? initialURL)

                        Button {
                            UIApplication.shared.open(state.currentURL ?? initialURL)
                        } label: {
                            Image(systemName: "safari")
                        }

                        Button {
                            showDevTools = true
                        } label: {
                            Image(systemName: "terminal")
                                .overlay(alignment: .topTrailing) {
                                    if let color = devToolsIndicatorColor {
                                        Circle()
                                            .fill(color)
                                            .frame(width: 7, height: 7)
                                            .offset(x: 5, y: -5)
                                    }
                                }
                        }
                    }
                }
        }
    }
}

private enum DevToolsTab {
    case console, network
}

private struct DevToolsDrawer: View {
    let logs: [ConsoleLogEntry]
    let requests: [NetworkRequestEntry]
    let onClearLogs: () -> Void
    let onClearRequests: () -> Void
    @State private var selectedTab: DevToolsTab = .console

    private var isCurrentTabEmpty: Bool {
        switch selectedTab {
        case .console: return logs.isEmpty
        case .network: return requests.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch selectedTab {
                case .console:
                    ConsoleLogList(logs: logs)
                case .network:
                    NetworkRequestList(requests: requests)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Tab", selection: $selectedTab) {
                        Text("Console").tag(DevToolsTab.console)
                        Text("Network").tag(DevToolsTab.network)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) {
                        switch selectedTab {
                        case .console: onClearLogs()
                        case .network: onClearRequests()
                        }
                    }
                    .disabled(isCurrentTabEmpty)
                }
            }
        }
    }
}

private struct ConsoleLogList: View {
    let logs: [ConsoleLogEntry]

    var body: some View {
        if logs.isEmpty {
            ContentUnavailableView(
                "No Console Output",
                systemImage: "terminal",
                description: Text("Console messages will appear here.")
            )
        } else {
            ScrollViewReader { proxy in
                List(logs) { entry in
                    ConsoleLogRow(entry: entry)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                .listStyle(.plain)
                .onChange(of: logs.count) { _, _ in
                    if let last = logs.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

private struct NetworkRequestList: View {
    let requests: [NetworkRequestEntry]

    var body: some View {
        if requests.isEmpty {
            ContentUnavailableView(
                "No Network Requests",
                systemImage: "network",
                description: Text("fetch and XMLHttpRequest calls will appear here.")
            )
        } else {
            ScrollViewReader { proxy in
                List(requests) { entry in
                    NetworkRequestRow(entry: entry)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                .listStyle(.plain)
                .onChange(of: requests.count) { _, _ in
                    if let last = requests.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

private struct NetworkRequestRow: View {
    let entry: NetworkRequestEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var methodColor: Color {
        switch entry.method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return .secondary
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.urlString)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let error = entry.error {
                    Text(error)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 8) {
                Text(entry.method)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(methodColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(methodColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    .padding(.top, 1)

                Text(entry.displayPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    if let status = entry.status {
                        Text(String(status))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(entry.statusColor)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    Text(entry.formattedDuration)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.top, 1)
            }
        }
    }
}

#Preview("Browser Sheet") {
    InAppBrowserSheet(initialURL: URL(string: "https://example.com")!)
}

#Preview("Dev Tools Drawer - Empty Console") {
    DevToolsDrawer(logs: [], requests: [], onClearLogs: {}, onClearRequests: {})
}

#Preview("Dev Tools Drawer - Console") {
    DevToolsDrawer(
        logs: [
            ConsoleLogEntry(level: .log, message: "Page loaded"),
            ConsoleLogEntry(level: .info, message: "User signed in"),
            ConsoleLogEntry(level: .debug, message: "Cache hit: true"),
            ConsoleLogEntry(level: .warn, message: "Deprecated API used"),
            ConsoleLogEntry(level: .error, message: "Failed to fetch: 404 Not Found"),
        ],
        requests: [],
        onClearLogs: {},
        onClearRequests: {}
    )
}

#Preview("Dev Tools Drawer - Network") {
    DevToolsDrawer(
        logs: [],
        requests: [
            NetworkRequestEntry(method: "GET", urlString: "https://api.example.com/users", status: 200, durationMs: 45, error: nil),
            NetworkRequestEntry(method: "POST", urlString: "https://api.example.com/auth/login", status: 401, durationMs: 120, error: nil),
            NetworkRequestEntry(method: "GET", urlString: "https://api.example.com/data/very/long/path/that/gets/truncated", status: 500, durationMs: 230, error: nil),
            NetworkRequestEntry(method: "DELETE", urlString: "https://api.example.com/session", status: nil, durationMs: 15, error: "TypeError: Failed to fetch"),
        ],
        onClearLogs: {},
        onClearRequests: {}
    )
}

private struct ConsoleLogRow: View {
    let entry: ConsoleLogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.level.rawValue.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(entry.level.color)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(entry.level.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                .padding(.top, 1)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, 1)
        }
    }
}
