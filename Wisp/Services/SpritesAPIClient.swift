import Foundation
import os
import SwiftData

private let logger = Logger(subsystem: "com.wisp.app", category: "API")

enum SpriteWakeOutcome: Equatable, CustomStringConvertible {
    case alreadyRunning
    case runningAfterWake
    case timedOut

    var description: String {
        switch self {
        case .alreadyRunning:
            return "alreadyRunning"
        case .runningAfterWake:
            return "runningAfterWake"
        case .timedOut:
            return "timedOut"
        }
    }
}

struct ChannelBridgeMessageRequest: Codable, Sendable, Equatable {
    let chatId: String
    let text: String
    let workingDirectory: String?
    let sessionId: String?
    let model: String?
    let maxTurns: Int?
    let claudeQuestionToolEnabled: Bool
    let customInstructions: String?
    let attachments: [String]

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case text
        case workingDirectory = "working_directory"
        case sessionId = "session_id"
        case model
        case maxTurns = "max_turns"
        case claudeQuestionToolEnabled = "claude_question_tool_enabled"
        case customInstructions = "custom_instructions"
        case attachments
    }
}

struct ChannelBridgeInterruptRequest: Codable, Sendable, Equatable {
    let chatId: String

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
    }
}

struct ChannelBridgeStatus: Codable, Sendable, Equatable {
    let isRunning: Bool
    let isBusy: Bool?
    let activity: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case isRunning = "is_running"
        case isBusy = "is_busy"
        case activity
        case sessionId = "session_id"
    }
}

@MainActor
struct SpriteWakeCoordinator {
    let fetchStatus: () async throws -> SpriteStatus
    let triggerWake: () async -> Void
    var sleep: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }
    var timeout: TimeInterval = 45
    var pollInterval: TimeInterval = 2
    var wakeRetryInterval: TimeInterval = 12
    var maxConsecutiveNetworkFailures = 3

    func waitUntilRunning() async throws -> SpriteWakeOutcome {
        let pollCount = max(1, Int(ceil(timeout / pollInterval)))
        let wakeRetryPolls = max(1, Int(ceil(wakeRetryInterval / pollInterval)))

        var triggeredWake = false
        var lastWakePoll: Int?
        var consecutiveNetworkFailures = 0

        for poll in 0..<pollCount {
            do {
                let status = try await fetchStatus()
                consecutiveNetworkFailures = 0

                if status == .running {
                    return triggeredWake ? .runningAfterWake : .alreadyRunning
                }
            } catch {
                if Self.isGenuineNetworkIssue(error) {
                    consecutiveNetworkFailures += 1
                    if consecutiveNetworkFailures >= maxConsecutiveNetworkFailures {
                        throw error
                    }
                } else {
                    consecutiveNetworkFailures = 0
                }
            }

            if shouldTriggerWake(poll: poll, lastWakePoll: lastWakePoll, wakeRetryPolls: wakeRetryPolls) {
                triggeredWake = true
                lastWakePoll = poll
                await triggerWake()
            }

            if poll < pollCount - 1 {
                await sleep(pollInterval)
            }
        }

        return .timedOut
    }

    private func shouldTriggerWake(poll: Int, lastWakePoll: Int?, wakeRetryPolls: Int) -> Bool {
        guard let lastWakePoll else { return true }
        return poll - lastWakePoll >= wakeRetryPolls
    }

    static func isGenuineNetworkIssue(_ error: Error) -> Bool {
        if let appError = error as? AppError {
            switch appError {
            case .networkError(let underlying):
                return isGenuineNetworkIssue(underlying)
            default:
                return false
            }
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        let code = URLError.Code(rawValue: nsError.code)

        switch code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed,
             .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }
}

@Observable
@MainActor
final class SpritesAPIClient {
    private let baseURL = "https://api.sprites.dev/v1"
    private let decoder = JSONDecoder.apiDecoder()
    private let encoder = JSONEncoder.apiEncoder()
    private let keychain = KeychainService.shared
    private static let bridgeStatusPollAttempts = 6

    // Stored properties so @Observable tracks them for SwiftUI
    private(set) var isAuthenticated: Bool
    private(set) var hasClaudeToken: Bool
    private(set) var hasGitHubToken: Bool

    init() {
        let keychain = KeychainService.shared
        self.isAuthenticated = keychain.load(key: .spritesToken) != nil
        self.hasClaudeToken = keychain.load(key: .claudeToken) != nil
        self.hasGitHubToken = keychain.load(key: .githubToken) != nil
    }

    /// Call after saving/deleting tokens to update tracked auth state
    func refreshAuthState() {
        isAuthenticated = keychain.load(key: .spritesToken) != nil
        hasClaudeToken = keychain.load(key: .claudeToken) != nil
        hasGitHubToken = keychain.load(key: .githubToken) != nil
    }

    var spritesToken: String? {
        keychain.load(key: .spritesToken)
    }

    var claudeToken: String? {
        keychain.load(key: .claudeToken)
    }

    var githubToken: String? {
        keychain.load(key: .githubToken)
    }

    // MARK: - Sprites

    func listSprites() async throws -> [Sprite] {
        let response: SpritesListResponse = try await request(method: "GET", path: "/sprites")
        return response.sprites
    }

    func createSprite(name: String) async throws -> Sprite {
        let body = CreateSpriteRequest(name: name)
        return try await request(method: "POST", path: "/sprites", body: body)
    }

    func getSprite(name: String) async throws -> Sprite {
        return try await request(method: "GET", path: "/sprites/\(name)")
    }

    /// Best-effort wake helper for commands that work better against a running sprite.
    /// Returns `.timedOut` for slow warm-ups so callers can continue when appropriate,
    /// and only throws after repeated genuine connectivity failures.
    @discardableResult
    func wakeSpriteIfNeeded(name: String, timeout: TimeInterval = 25, pollInterval: TimeInterval = 2) async throws -> SpriteWakeOutcome {
        let coordinator = SpriteWakeCoordinator(
            fetchStatus: { [weak self] in
                guard let self else { return .unknown }
                return try await self.getSprite(name: name).status
            },
            triggerWake: { [weak self] in
                guard let self else { return }
                logger.info("Triggering wake ping for sprite \(name, privacy: .public)")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.runExec(spriteName: name, command: "true", timeout: 20)
                }
            },
            timeout: timeout,
            pollInterval: pollInterval
        )

        let outcome = try await coordinator.waitUntilRunning()
        logger.info("wakeSpriteIfNeeded(\(name, privacy: .public)) -> \(outcome.description, privacy: .public)")
        return outcome
    }

    func deleteSprite(name: String) async throws {
        let _: EmptyResponse = try await request(method: "DELETE", path: "/sprites/\(name)")
    }

    func updateSprite(name: String, urlSettings: Sprite.UrlSettings) async throws -> Sprite {
        let body = UpdateSpriteRequest(urlSettings: urlSettings)
        return try await request(method: "PUT", path: "/sprites/\(name)", body: body)
    }

    // MARK: - Checkpoints

    func listCheckpoints(spriteName: String) async throws -> [Checkpoint] {
        return try await request(method: "GET", path: "/sprites/\(spriteName)/checkpoints")
    }

    func createCheckpoint(spriteName: String, comment: String?) async throws {
        try await streamingRequest(
            method: "POST",
            path: "/sprites/\(spriteName)/checkpoint",
            body: CreateCheckpointRequest(comment: comment)
        )
    }

    func restoreCheckpoint(spriteName: String, checkpointId: String) async throws {
        try await streamingRequest(
            method: "POST",
            path: "/sprites/\(spriteName)/checkpoints/\(checkpointId)/restore"
        )
    }

    // MARK: - Auth Validation

    func validateToken() async throws {
        let _: SpritesListResponse = try await request(method: "GET", path: "/sprites")
    }

    // MARK: - Channel Bridge

    private func channelBridgeSecretDefaultsKey(spriteName: String) -> String {
        "channelBridgeSecret.\(spriteName)"
    }

    private func channelBridgeSecret(for spriteName: String) -> String {
        let defaults = UserDefaults.standard
        let key = channelBridgeSecretDefaultsKey(spriteName: spriteName)
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        defaults.set(generated, forKey: key)
        return generated
    }

    private func uploadTextFile(spriteName: String, remotePath: String, contents: String) async throws {
        _ = try await uploadFile(
            spriteName: spriteName,
            remotePath: remotePath,
            data: Data(contents.utf8)
        )
    }

    private func ensureMinimumClaudeVersion(spriteName: String) async throws {
        let (versionOutput, success) = await runExec(
            spriteName: spriteName,
            command: WispChannelBridge.checkClaudeVersionCommand,
            timeout: 15
        )
        let installedVersion = versionOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " (Claude Code)", with: "")

        if success, !installedVersion.isEmpty,
           installedVersion.compare(WispChannelBridge.minimumClaudeVersion, options: .numeric) != .orderedAscending {
            logger.info("Claude version \(installedVersion, privacy: .public) meets minimum \(WispChannelBridge.minimumClaudeVersion, privacy: .public)")
            return
        }

        logger.info("Claude version \(installedVersion, privacy: .public) below minimum \(WispChannelBridge.minimumClaudeVersion, privacy: .public) — updating")
        let (updateOutput, updateSuccess) = await runExec(
            spriteName: spriteName,
            command: WispChannelBridge.updateClaudeCommand,
            timeout: 120
        )
        if updateSuccess {
            logger.info("Claude update completed: \(updateOutput.suffix(100), privacy: .public)")
        } else {
            logger.error("Claude update may have failed: \(updateOutput.suffix(200), privacy: .public)")
        }
    }

    private func installChannelBridgeIfNeeded(
        spriteName: String,
        claudeToken: String?,
        bridgeSecret: String
    ) async throws {
        let (versionOutput, versionCheckSuccess) = await runExec(
            spriteName: spriteName,
            command: WispChannelBridge.checkVersionCommand,
            timeout: 15
        )
        let installedVersion = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsInstall = !versionCheckSuccess || installedVersion != WispChannelBridge.version

        if needsInstall {
            try await uploadTextFile(
                spriteName: spriteName,
                remotePath: WispChannelBridge.serverTsPath,
                contents: WispChannelBridge.serverScript
            )
            try await uploadTextFile(
                spriteName: spriteName,
                remotePath: WispChannelBridge.launcherPyPath,
                contents: WispChannelBridge.launcherScript
            )
            try await uploadTextFile(
                spriteName: spriteName,
                remotePath: WispChannelBridge.packageJsonPath,
                contents: WispChannelBridge.packageJsonScript
            )
            try await uploadTextFile(
                spriteName: spriteName,
                remotePath: WispChannelBridge.versionPath,
                contents: WispChannelBridge.version
            )

            let (_, chmodSuccess) = await runExec(
                spriteName: spriteName,
                command: WispChannelBridge.chmodCommand,
                timeout: 15
            )
            guard chmodSuccess else {
                throw AppError.serverError(statusCode: 500, message: "Failed to mark plugin scripts as executable")
            }

            let (_, depsSuccess) = await runExec(
                spriteName: spriteName,
                command: WispChannelBridge.installDepsCommand,
                timeout: 60
            )
            if !depsSuccess {
                logger.error("Plugin dependency install may have failed")
            }

            // Clean up old bridge service if it exists
            _ = try? await deleteService(spriteName: spriteName, serviceName: "wisp-channel-bridge")
        }

        try await uploadTextFile(
            spriteName: spriteName,
            remotePath: WispChannelBridge.secretPath,
            contents: bridgeSecret
        )

        // Only upload the app's Claude token if the sprite doesn't already have
        // its own credentials from an interactive `claude /login`.
        let (hasLocalCreds, _) = await runExec(
            spriteName: spriteName,
            command: "test -f ~/.claude/.credentials.json && echo yes || echo no",
            timeout: 10
        )
        let spriteHasOwnToken = hasLocalCreds.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"

        if spriteHasOwnToken {
            // Remove any previously uploaded token so the bridge uses the sprite's own credentials
            _ = await runExec(
                spriteName: spriteName,
                command: "rm -f \(WispChannelBridge.claudeTokenPath)",
                timeout: 10
            )
            logger.info("Sprite has its own Claude credentials — using sprite-local auth")
        } else if let claudeToken, !claudeToken.isEmpty {
            try await uploadTextFile(
                spriteName: spriteName,
                remotePath: WispChannelBridge.claudeTokenPath,
                contents: claudeToken
            )
        } else {
            _ = await runExec(
                spriteName: spriteName,
                command: "rm -f \(WispChannelBridge.claudeTokenPath)",
                timeout: 15
            )
        }
    }

    func ensureChannelBridgeReady(spriteName: String) async throws -> Sprite {
        _ = try await wakeSpriteIfNeeded(name: spriteName, timeout: 25)
        let sprite = try await getSprite(name: spriteName)
        _ = try channelBridgeBaseURL(sprite: sprite)

        let bridgeSecret = channelBridgeSecret(for: spriteName)
        try await ensureMinimumClaudeVersion(spriteName: spriteName)
        try await installChannelBridgeIfNeeded(
            spriteName: spriteName,
            claudeToken: claudeToken,
            bridgeSecret: bridgeSecret
        )

        _ = try await upsertService(
            spriteName: spriteName,
            serviceName: WispChannelBridge.serviceName,
            request: WispChannelBridge.serviceRequest
        )

        do {
            try await startService(
                spriteName: spriteName,
                serviceName: WispChannelBridge.serviceName
            )
        } catch {
            logger.info("Channel bridge service start returned non-fatal error: \(error.localizedDescription, privacy: .public)")
        }

        for attempt in 1...Self.bridgeStatusPollAttempts {
            do {
                let status = try await getChannelBridgeStatus(sprite: sprite)
                if status.isRunning {
                    return sprite
                }
            } catch {
                logger.info("Channel bridge health check attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }

            if attempt < Self.bridgeStatusPollAttempts {
                try? await Task.sleep(for: .milliseconds(350))
            }
        }

        return sprite
    }

    func channelBridgeBaseURL(sprite: Sprite) throws -> URL {
        guard let spriteURL = sprite.url, let baseURL = URL(string: spriteURL) else {
            throw AppError.invalidURL
        }
        return baseURL
    }

    nonisolated static func channelBridgeURL(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = baseURL.appendingPathComponent(normalizedPath)

        guard !queryItems.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = queryItems
        return components.url ?? url
    }

    nonisolated static func makeChannelBridgeRequest(
        baseURL: URL,
        authMode: String,
        path: String,
        method: String,
        bearerToken: String?,
        bridgeSecret: String?,
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval? = nil
    ) -> URLRequest {
        var request = URLRequest(
            url: channelBridgeURL(baseURL: baseURL, path: path, queryItems: queryItems)
        )
        request.httpMethod = method
        if let timeout {
            request.timeoutInterval = timeout
        }
        if authMode != "public", let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let bridgeSecret, !bridgeSecret.isEmpty {
            request.setValue(bridgeSecret, forHTTPHeaderField: "X-Wisp-Bridge-Key")
        }
        return request
    }

    nonisolated static func decodeChannelBridgeEvent(_ event: ServerSentEvent) throws -> ClaudeStreamEvent {
        try JSONDecoder.apiDecoder().decode(ClaudeStreamEvent.self, from: Data(event.data.utf8))
    }

    func postChannelBridgeMessage(sprite: Sprite, message: ChannelBridgeMessageRequest) async throws {
        let authMode = sprite.urlSettings?.auth ?? "sprite"
        let token = spritesToken
        if authMode != "public", token == nil {
            throw AppError.noToken
        }

        var request = Self.makeChannelBridgeRequest(
            baseURL: try channelBridgeBaseURL(sprite: sprite),
            authMode: authMode,
            path: "message",
            method: "POST",
            bearerToken: token,
            bridgeSecret: channelBridgeSecret(for: sprite.name),
            timeout: 30
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(message)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.networkError(URLError(.badServerResponse))
        }

        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.info("POST channel /message → \(httpResponse.statusCode): \(raw)")

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            throw AppError.unauthorized
        case 404:
            throw AppError.notFound
        default:
            throw AppError.serverError(statusCode: httpResponse.statusCode, message: raw)
        }
    }

    func interruptChannelBridge(sprite: Sprite, chatId: String) async throws {
        let authMode = sprite.urlSettings?.auth ?? "sprite"
        let token = spritesToken
        if authMode != "public", token == nil {
            throw AppError.noToken
        }

        var request = Self.makeChannelBridgeRequest(
            baseURL: try channelBridgeBaseURL(sprite: sprite),
            authMode: authMode,
            path: "interrupt",
            method: "POST",
            bearerToken: token,
            bridgeSecret: channelBridgeSecret(for: sprite.name),
            timeout: 15
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(ChannelBridgeInterruptRequest(chatId: chatId))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.networkError(URLError(.badServerResponse))
        }

        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.info("POST channel /interrupt → \(httpResponse.statusCode): \(raw)")

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            throw AppError.unauthorized
        case 404:
            throw AppError.notFound
        default:
            throw AppError.serverError(statusCode: httpResponse.statusCode, message: raw)
        }
    }

    func getChannelBridgeStatus(sprite: Sprite, chatId: String? = nil) async throws -> ChannelBridgeStatus {
        let authMode = sprite.urlSettings?.auth ?? "sprite"
        let token = spritesToken
        if authMode != "public", token == nil {
            throw AppError.noToken
        }

        let request = Self.makeChannelBridgeRequest(
            baseURL: try channelBridgeBaseURL(sprite: sprite),
            authMode: authMode,
            path: "status",
            method: "GET",
            bearerToken: token,
            bridgeSecret: channelBridgeSecret(for: sprite.name),
            queryItems: chatId.map { [URLQueryItem(name: "chat_id", value: $0)] } ?? [],
            timeout: 15
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.networkError(URLError(.badServerResponse))
        }

        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.info("GET channel /status → \(httpResponse.statusCode): \(raw)")

        switch httpResponse.statusCode {
        case 200...299:
            do {
                return try decoder.decode(ChannelBridgeStatus.self, from: data)
            } catch {
                throw AppError.decodingError(error)
            }
        case 401:
            throw AppError.unauthorized
        case 404:
            throw AppError.notFound
        default:
            throw AppError.serverError(statusCode: httpResponse.statusCode, message: raw)
        }
    }

    func streamChannelBridgeEvents(
        sprite: Sprite,
        chatId: String? = nil,
        lastEventId: String? = nil,
        timeout: TimeInterval = 120
    ) -> AsyncThrowingStream<ServerSentEvent, Error> {
        let authMode = sprite.urlSettings?.auth ?? "sprite"
        let token = spritesToken

        if authMode != "public", token == nil {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AppError.noToken)
            }
        }

        let baseURL: URL
        do {
            baseURL = try channelBridgeBaseURL(sprite: sprite)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        var request = Self.makeChannelBridgeRequest(
            baseURL: baseURL,
            authMode: authMode,
            path: "events",
            method: "GET",
            bearerToken: token,
            bridgeSecret: channelBridgeSecret(for: sprite.name),
            queryItems: chatId.map { [URLQueryItem(name: "chat_id", value: $0)] } ?? [],
            timeout: timeout
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let lastEventId {
            request.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }

        // Use a dedicated session for SSE to avoid shared session buffering/caching
        let sseConfig = URLSessionConfiguration.default
        sseConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sseConfig.urlCache = nil
        sseConfig.timeoutIntervalForRequest = timeout
        sseConfig.timeoutIntervalForResource = timeout
        let sseSession = URLSession(configuration: sseConfig)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    logger.info("SSE: connecting to \(request.url?.absoluteString ?? "nil", privacy: .public)")
                    let (bytes, response) = try await sseSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: AppError.networkError(URLError(.badServerResponse)))
                        return
                    }

                    logger.info("SSE: got response status=\(httpResponse.statusCode, privacy: .public)")

                    guard (200...299).contains(httpResponse.statusCode) else {
                        switch httpResponse.statusCode {
                        case 401: continuation.finish(throwing: AppError.unauthorized)
                        case 404: continuation.finish(throwing: AppError.notFound)
                        default: continuation.finish(throwing: AppError.serverError(statusCode: httpResponse.statusCode, message: nil))
                        }
                        return
                    }

                    let parser = ServerSentEventParser()
                    // bytes.lines skips empty lines, but SSE requires them as
                    // event separators. Use raw byte iteration with manual line
                    // splitting to preserve empty lines.
                    var lineBuffer = ""
                    for try await byte in bytes {
                        let char = Character(UnicodeScalar(byte))
                        if char == "\n" {
                            let line = lineBuffer
                            lineBuffer = ""
                            if let event = await parser.parse(line: line) {
                                continuation.yield(event)
                            }
                        } else if char != "\r" {
                            lineBuffer.append(char)
                        }
                    }
                    // Flush any remaining partial line
                    if !lineBuffer.isEmpty {
                        if let event = await parser.parse(line: lineBuffer) {
                            continuation.yield(event)
                        }
                    }
                    logger.info("SSE: stream ended normally")
                    if let trailingEvent = await parser.finish() {
                        continuation.yield(trailingEvent)
                    }
                    continuation.finish()
                } catch {
                    logger.error("SSE stream error: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Exec WebSocket

    func createExecSession(spriteName: String, command: String, env: [String: String] = [:], maxRunAfterDisconnect: Int? = nil) -> ExecSession {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.sprites.dev"
        components.path = "/v1/sprites/\(spriteName)/exec"

        var queryItems = [
            URLQueryItem(name: "cmd", value: "bash"),
            URLQueryItem(name: "cmd", value: "-c"),
            URLQueryItem(name: "cmd", value: command),
        ]

        if let maxRunAfterDisconnect {
            queryItems.append(URLQueryItem(name: "max_run_after_disconnect", value: String(maxRunAfterDisconnect)))
        }

        for (key, value) in env {
            queryItems.append(URLQueryItem(name: "env", value: "\(key)=\(value)"))
        }

        components.queryItems = queryItems

        // URLQueryItem doesn't percent-encode semicolons (they're allowed in RFC 3986),
        // but Go's net/url (1.17+) silently drops query parameters containing literal
        // semicolons. Manually encode them so the server receives the full command.
        if let encoded = components.percentEncodedQuery {
            components.percentEncodedQuery = encoded
                .replacingOccurrences(of: ";", with: "%3B")
                .replacingOccurrences(of: "+", with: "%2B")
        }

        guard let url = components.url else {
            preconditionFailure("URLComponents with scheme=wss, host=api.sprites.dev failed to produce URL")
        }
        return ExecSession(url: url, token: spritesToken ?? "")
    }

    func attachExecSession(spriteName: String, execSessionId: String) -> ExecSession {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.sprites.dev"
        components.path = "/v1/sprites/\(spriteName)/exec/\(execSessionId)"

        guard let url = components.url else {
            preconditionFailure("URLComponents with scheme=wss, host=api.sprites.dev failed to produce URL")
        }
        return ExecSession(url: url, token: spritesToken ?? "")
    }

    func killExecSession(spriteName: String, execSessionId: String) async throws {
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "/sprites/\(spriteName)/exec/\(execSessionId)/kill"
        )
    }

    // MARK: - Legacy service cleanup

    func deleteService(spriteName: String, serviceName: String) async {
        let _: EmptyResponse? = try? await request(
            method: "DELETE",
            path: "/sprites/\(spriteName)/services/\(serviceName)",
            timeout: 5
        )
    }

    func listServices(spriteName: String) async throws -> [ServiceInfo] {
        return try await request(method: "GET", path: "/sprites/\(spriteName)/services")
    }

    func upsertService(
        spriteName: String,
        serviceName: String,
        request serviceRequest: ServiceRequest
    ) async throws {
        try await streamingRequest(
            method: "PUT",
            path: "/sprites/\(spriteName)/services/\(serviceName)",
            body: serviceRequest
        )
    }

    func startService(spriteName: String, serviceName: String) async throws {
        try await streamingRequest(
            method: "POST",
            path: "/sprites/\(spriteName)/services/\(serviceName)/start"
        )
    }

    /// Stream logs from a service (used by the Services UI to view non-Claude service output).
    func streamServiceLogs(
        spriteName: String,
        serviceName: String,
        duration: String = "3600s"
    ) -> AsyncThrowingStream<ServiceLogEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let token = spritesToken else {
                        continuation.finish(throwing: AppError.noToken)
                        return
                    }

                    let path = "\(baseURL)/sprites/\(spriteName)/services/\(serviceName)/logs?duration=\(duration)"
                    guard let url = URL(string: path) else {
                        continuation.finish(throwing: AppError.invalidURL)
                        return
                    }

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "GET"
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    urlRequest.timeoutInterval = 120

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: AppError.networkError(URLError(.badServerResponse)))
                        return
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        switch httpResponse.statusCode {
                        case 401: continuation.finish(throwing: AppError.unauthorized)
                        case 404: continuation.finish(throwing: AppError.notFound)
                        default: continuation.finish(throwing: AppError.serverError(statusCode: httpResponse.statusCode, message: nil))
                        }
                        return
                    }

                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        do {
                            let event = try decoder.decode(ServiceLogEvent.self, from: data)
                            continuation.yield(event)
                        } catch {
                            logger.warning("Failed to decode service log event: \(error.localizedDescription, privacy: .public) line: \(line.prefix(200), privacy: .public)")
                        }
                    }
                    continuation.finish()
                } catch {
                    logger.error("streamServiceLogs error: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// One-time migration: delete `wisp-claude-*` and `wisp-quick-*` services left by
    /// the old service-based execution model. They restart on every sprite wake and
    /// re-execute stale prompts / burn Claude tokens.
    ///
    /// - Stored names (`currentServiceName` in SpriteChat) are cleared immediately so
    ///   this is a true one-time operation for the claude services.
    /// - `spriteNames` drives a live sweep to also catch `wisp-quick-*` and any
    ///   services whose names weren't persisted.
    ///
    /// TODO: Remove this function (and its call in DashboardView, and `listServices`,
    /// `deleteService`, `ServiceTypes.swift`, and `SpriteChat.currentServiceName`) once
    /// enough time has passed that no users are still running the service-based version.
    func cleanupLegacyServices(spriteNames: [String] = [], modelContext: ModelContext) {
        // Only run while there are chats that still have a stored service name.
        // Once all are cleared (after first run post-migration), this becomes a no-op
        // and no sprite API calls are made on subsequent launches.
        let descriptor = FetchDescriptor<SpriteChat>(
            predicate: #Predicate { $0.currentServiceName != nil }
        )
        guard let chats = try? modelContext.fetch(descriptor), !chats.isEmpty else { return }

        // 1. Delete stored wisp-claude-* service names and clear them from the model
        logger.info("Cleaning up \(chats.count) stored legacy service(s)")
        for chat in chats {
            guard let serviceName = chat.currentServiceName else { continue }
            let sName = chat.spriteName
            chat.currentServiceName = nil
            Task {
                await deleteService(spriteName: sName, serviceName: serviceName)
                logger.info("Deleted legacy service \(serviceName) on \(sName)")
            }
        }
        try? modelContext.save()

        // 2. Sweep known sprites for any remaining wisp-* services (catches wisp-quick-*)
        for spriteName in spriteNames {
            let sName = spriteName
            Task {
                guard let services = try? await listServices(spriteName: sName) else { return }
                let wispServices = services.filter { $0.name.hasPrefix("wisp-") }
                guard !wispServices.isEmpty else { return }
                logger.info("Sweeping \(wispServices.count) wisp-* service(s) on \(sName)")
                for service in wispServices {
                    await deleteService(spriteName: sName, serviceName: service.name)
                }
            }
        }
    }

}

extension SpritesAPIClient {

    // MARK: - File Upload

    struct FileUploadResponse: Codable, Sendable {
        let path: String
        let size: Int
        let mode: String
    }

    func fileExists(spriteName: String, remotePath: String) async throws -> Bool {
        guard let token = spritesToken else {
            throw AppError.noToken
        }

        guard var components = URLComponents(string: baseURL + "/sprites/\(spriteName)/fs/read") else {
            throw AppError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "path", value: remotePath),
        ]

        guard let url = components.url else {
            throw AppError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200...299:
            return true
        case 404:
            return false
        case 401:
            throw AppError.unauthorized
        default:
            throw AppError.serverError(statusCode: httpResponse.statusCode, message: nil)
        }
    }

    func uploadFile(spriteName: String, remotePath: String, data: Data) async throws -> FileUploadResponse {
        let maxSize = 10 * 1024 * 1024 // 10 MB
        guard data.count <= maxSize else {
            throw AppError.fileTooLarge(data.count)
        }

        guard let token = spritesToken else {
            throw AppError.noToken
        }

        guard var components = URLComponents(string: baseURL + "/sprites/\(spriteName)/fs/write") else {
            throw AppError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "path", value: remotePath),
            URLQueryItem(name: "mkdir", value: "true"),
        ]

        guard let url = components.url else {
            throw AppError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.networkError(URLError(.badServerResponse))
        }

        let raw = String(data: responseData, encoding: .utf8) ?? "<binary>"
        logger.info("PUT /sprites/\(spriteName)/fs/write → \(httpResponse.statusCode): \(raw)")

        switch httpResponse.statusCode {
        case 200...299:
            do {
                return try decoder.decode(FileUploadResponse.self, from: responseData)
            } catch {
                logger.error("Decode FileUploadResponse: \(error)")
                throw AppError.decodingError(error)
            }
        case 401:
            throw AppError.unauthorized
        case 404:
            throw AppError.notFound
        default:
            let message = String(data: responseData, encoding: .utf8)
            throw AppError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    // MARK: - Exec Helpers

    /// Run a command on a sprite via exec WebSocket, collecting output.
    /// Returns the accumulated stdout/stderr text and whether the command exited successfully before timeout.
    func runExec(spriteName: String, command: String, env: [String: String] = [:], timeout: Int = 15) async -> (output: String, success: Bool) {
        let session = createExecSession(spriteName: spriteName, command: command, env: env)
        session.connect()
        var output = Data()
        var timedOut = false
        var exitCode: Int?

        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            timedOut = true
            session.disconnect()
        }

        do {
            for try await event in session.events() {
                if case .stdout(let chunk) = event {
                    output.append(chunk)
                } else if case .stderr(let chunk) = event {
                    output.append(chunk)
                } else if case .exit(let code) = event {
                    exitCode = code
                }
            }
        } catch {
            // Expected on timeout disconnect
        }

        timeoutTask.cancel()
        session.disconnect()
        let text = String(data: output, encoding: .utf8) ?? ""
        let succeeded = !timedOut && (exitCode.map { $0 == 0 } ?? true)
        return (text, succeeded)
    }

    // MARK: - Private

    private func request<T: Decodable>(
        method: String,
        path: String,
        body: (some Encodable)? = nil as String?,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        guard let token = spritesToken else {
            throw AppError.noToken
        }

        guard let url = URL(string: baseURL + path) else {
            throw AppError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let timeout {
            urlRequest.timeoutInterval = timeout
        }

        if let body {
            urlRequest.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.networkError(URLError(.badServerResponse))
        }

        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.info("\(method) \(path) → \(httpResponse.statusCode): \(raw)")

        switch httpResponse.statusCode {
        case 200...299:
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                logger.error("Decode \(String(describing: T.self)): \(error)")
                throw AppError.decodingError(error)
            }
        case 401:
            throw AppError.unauthorized
        case 404:
            throw AppError.notFound
        default:
            let message = String(data: data, encoding: .utf8)
            throw AppError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    /// Consume a streaming NDJSON response (checkpoint create/restore).
    /// Reads all events and throws if any event has type "error".
    private func streamingRequest(
        method: String,
        path: String,
        body: (some Encodable)? = nil as String?
    ) async throws {
        guard let token = spritesToken else {
            throw AppError.noToken
        }
        guard let url = URL(string: baseURL + path) else {
            throw AppError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body {
            urlRequest.httpBody = try encoder.encode(body)
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            switch httpResponse.statusCode {
            case 401: throw AppError.unauthorized
            case 404: throw AppError.notFound
            default: throw AppError.serverError(statusCode: httpResponse.statusCode, message: nil)
            }
        }

        let decoder = self.decoder
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            if let event = try? decoder.decode(CheckpointStreamEvent.self, from: data) {
                if event.type == "error" {
                    throw AppError.serverError(statusCode: 500, message: event.error ?? event.data)
                }
                logger.info("Checkpoint stream: \(event.type) — \(event.data ?? "")")
            }
        }
    }
}

private struct EmptyResponse: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}
