import Foundation
import os

private let logger = Logger(subsystem: "com.wisp.app", category: "SideChat")

@Observable
@MainActor
final class SideChatViewModel {
    let spriteName: String
    let sessionId: String
    let workingDirectory: String

    var question = ""
    private(set) var response = ""
    private(set) var isStreaming = false
    private(set) var error: String?

    private var streamTask: Task<Void, Never>?
    private let parser = ClaudeStreamParser()

    init(spriteName: String, sessionId: String, workingDirectory: String) {
        self.spriteName = spriteName
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
    }

    func send(apiClient: SpritesAPIClient) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }

        question = ""
        response = ""
        error = nil
        isStreaming = true

        streamTask = Task {
            await executeQuestion(q, apiClient: apiClient)
        }
    }

    func cancel(apiClient: SpritesAPIClient) {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    // MARK: - Private

    private func executeQuestion(_ question: String, apiClient: SpritesAPIClient) async {
        guard let claudeToken = apiClient.claudeToken else {
            error = "No Claude token configured"
            isStreaming = false
            return
        }

        let escapedQuestion = question.replacingOccurrences(of: "'", with: "'\\''")
        let modelId = UserDefaults.standard.string(forKey: "claudeModel") ?? ClaudeModel.sonnet.rawValue

        let commandParts: [String] = [
            "export CLAUDE_CODE_OAUTH_TOKEN='\(claudeToken)'",
            "cd \(workingDirectory)",
            "claude -p --verbose --output-format stream-json --dangerously-skip-permissions --tools \"\" --model \(modelId) --resume \(sessionId) '\(escapedQuestion)'"
        ]
        let fullCommand = commandParts.joined(separator: " && ")

        let session = apiClient.createExecSession(spriteName: spriteName, command: fullCommand)
        session.connect()

        await parser.reset()

        var receivedData = false
        var receivedResult = false

        do {
            streamLoop: for try await event in session.events() {
                guard !Task.isCancelled else { break streamLoop }

                switch event {
                case .stdout(let data):
                    receivedData = true
                    let parsed = await parser.parse(data: data)
                    for e in parsed {
                        handle(e)
                        if case .result = e { receivedResult = true }
                    }
                    if receivedResult { break streamLoop }

                case .stderr:
                    receivedData = true

                case .exit:
                    let remaining = await parser.flush()
                    for e in remaining { handle(e) }
                    break streamLoop

                case .sessionInfo:
                    break
                }
            }

            let remaining = await parser.flush()
            for e in remaining { handle(e) }
        } catch {
            if !Task.isCancelled {
                self.error = "Connection error"
                logger.error("Side chat stream error: \(error.localizedDescription)")
            }
        }

        session.disconnect()

        if !Task.isCancelled {
            isStreaming = false
        }
    }

    func handle(_ event: ClaudeStreamEvent) {
        switch event {
        case .assistant(let assistantEvent):
            for block in assistantEvent.message.content {
                if case .text(let text) = block {
                    response += text
                }
            }
        case .result(let resultEvent):
            if resultEvent.isError == true, response.isEmpty {
                error = "Claude returned an error"
            }
        default:
            break
        }
    }
}
