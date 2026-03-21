import Foundation
import os

private let logger = Logger(subsystem: "com.wisp.app", category: "QuickChat")

@Observable
@MainActor
final class QuickChatViewModel {
    let spriteName: String
    let workingDirectory: String
    private let chatId: String

    var question = ""
    private(set) var lastQuestion = ""
    private(set) var response = ""
    private(set) var isStreaming = false
    private(set) var error: String?
    private(set) var sessionId: String?
    private(set) var channelLastEventId: String?

    private var streamTask: Task<Void, Never>?
    private let parser = ClaudeStreamParser()

    private var transportMode: ClaudeChatTransportMode {
        ClaudeChatTransportMode.current
    }

    private var usesChannelTransport: Bool {
        transportMode == .channels
    }

    init(spriteName: String, sessionId: String?, workingDirectory: String) {
        self.spriteName = spriteName
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.chatId = "quick-\(UUID().uuidString.lowercased())"
    }

    func send(apiClient: SpritesAPIClient) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }

        lastQuestion = q
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

        guard usesChannelTransport else { return }
        let spriteName = spriteName
        let bridgeChatId = chatId
        Task {
            guard let sprite = try? await apiClient.getSprite(name: spriteName) else { return }
            try? await apiClient.interruptChannelBridge(sprite: sprite, chatId: bridgeChatId)
        }
    }

    // MARK: - Private

    private func executeQuestion(_ question: String, apiClient: SpritesAPIClient) async {
        if usesChannelTransport {
            await executeChannelQuestion(question, apiClient: apiClient)
        } else {
            await executeExecQuestion(question, apiClient: apiClient)
        }
    }

    private func executeChannelQuestion(_ question: String, apiClient: SpritesAPIClient) async {
        let sprite: Sprite
        do {
            sprite = try await apiClient.ensureChannelBridgeReady(spriteName: spriteName)
        } catch AppError.invalidURL {
            error = "This sprite does not expose a channel bridge URL yet"
            isStreaming = false
            return
        } catch {
            self.error = "Could not connect to the channel bridge"
            isStreaming = false
            logger.error("Quick chat channel setup failed: \(error.localizedDescription)")
            return
        }

        let modelId = UserDefaults.standard.string(forKey: "claudeModel") ?? ClaudeModel.opus.rawValue
        let request = ChannelBridgeMessageRequest(
            chatId: chatId,
            text: question,
            workingDirectory: workingDirectory,
            sessionId: sessionId,
            model: modelId,
            maxTurns: 5,
            customInstructions: nil,
            attachments: []
        )

        do {
            try await apiClient.postChannelBridgeMessage(sprite: sprite, message: request)
            await processChannelStream(
                events: apiClient.streamChannelBridgeEvents(
                    sprite: sprite,
                    chatId: chatId,
                    lastEventId: channelLastEventId
                )
            )
        } catch {
            if !Task.isCancelled {
                self.error = "Failed to send message through the channel bridge"
                logger.error("Quick chat channel send failed: \(error.localizedDescription)")
            }
        }

        if !Task.isCancelled {
            isStreaming = false
        }
    }

    func processChannelStream(events: AsyncThrowingStream<ServerSentEvent, Error>) async {
        do {
            for try await event in events {
                guard !Task.isCancelled else { break }

                if let id = event.id {
                    channelLastEventId = id
                }

                guard !event.data.isEmpty else { continue }

                if event.event == "error" {
                    error = event.data
                    break
                }

                do {
                    handle(try SpritesAPIClient.decodeChannelBridgeEvent(event))
                } catch {
                    logger.warning("Quick chat dropped undecodable channel event: \(error.localizedDescription)")
                }
            }
        } catch {
            if !Task.isCancelled {
                self.error = "Connection error"
                logger.error("Quick chat channel stream error: \(error.localizedDescription)")
            }
        }
    }

    private func executeExecQuestion(_ question: String, apiClient: SpritesAPIClient) async {
        guard let claudeToken = apiClient.claudeToken else {
            error = "No Claude token configured"
            isStreaming = false
            return
        }

        let escapedQuestion = question.replacingOccurrences(of: "'", with: "'\\''")
        let modelId = UserDefaults.standard.string(forKey: "claudeModel") ?? ClaudeModel.opus.rawValue

        var claudeCmd = "claude -p --verbose --output-format stream-json --dangerously-skip-permissions"
        claudeCmd += " --disallowedTools \"Bash,Write,Edit,MultiEdit,WebSearch,WebFetch\""
        claudeCmd += " --max-turns 5"
        claudeCmd += " --model \(modelId)"
        if let sid = sessionId {
            claudeCmd += " --resume \(sid)"
        }
        claudeCmd += " '\(escapedQuestion)'"

        let commandParts: [String] = [
            "export CLAUDE_CODE_OAUTH_TOKEN='\(claudeToken)'",
            "mkdir -p \(workingDirectory)",
            "cd \(workingDirectory)",
            claudeCmd
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
                case .sessionInfo:
                    break

                case .stdout(let data):
                    receivedData = true
                    let parsed = await parser.parse(data: data)
                    for e in parsed {
                        handle(e)
                        if case .result = e { receivedResult = true }
                    }
                    if receivedResult { break streamLoop }

                case .stderr(let data):
                    if !receivedData, let text = String(data: data, encoding: .utf8) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { error = trimmed }
                    }

                case .exit:
                    let remaining = await parser.flush()
                    for e in remaining { handle(e) }
                    break streamLoop
                }
            }

            let remaining = await parser.flush()
            for e in remaining { handle(e) }
        } catch {
            if !Task.isCancelled {
                self.error = "Connection error"
                logger.error("Quick chat stream error: \(error.localizedDescription)")
            }
        }

        session.disconnect()

        if !Task.isCancelled {
            isStreaming = false
        }
    }

    func handle(_ event: ClaudeStreamEvent) {
        switch event {
        case .system(let systemEvent):
            sessionId = systemEvent.sessionId
        case .assistant(let assistantEvent):
            for block in assistantEvent.message.content {
                if case .text(let text) = block {
                    response += text
                }
            }
        case .result(let resultEvent):
            sessionId = resultEvent.sessionId
            let isErrorResult = resultEvent.isError == true || (resultEvent.subtype != nil && resultEvent.subtype != "success")
            if isErrorResult, response.isEmpty {
                if resultEvent.subtype == "error_max_turns" {
                    error = "Claude hit the turn limit without responding — try a simpler question"
                } else {
                    error = "Claude returned an error"
                }
            }
        default:
            break
        }
    }
}
