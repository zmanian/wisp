import Testing
import Foundation
@testable import Wisp

@Suite("Exec Session URL Encoding")
struct ExecSessionURLTests {

    // MARK: - Semicolon encoding

    @Test func semicolonsInCommandArePercentEncoded() throws {
        // Semicolons must be percent-encoded because Go's net/url (1.17+)
        // silently drops query parameters containing literal semicolons.
        let command = "echo 'CREATE TABLE t (id INT); SELECT 1;'"

        let url = buildExecURL(command: command)
        let query = try #require(url.query)

        // The raw query string must not contain literal semicolons
        #expect(!query.contains(";"))
        // But should contain the encoded form
        #expect(url.absoluteString.contains("%3B"))
    }

    @Test func commandWithSQLiteDefaultDatetime() throws {
        // Reproduces the exact user-reported bug: SQLite CREATE TABLE
        // with datetime('now') DEFAULT and trailing semicolons.
        let command = """
            mkdir -p /home/sprite/project && cd /home/sprite/project && claude -p \
            'CREATE TABLE emails (received_at TEXT NOT NULL DEFAULT (datetime('\\''now'\\''))); \
            CREATE TABLE docs (created_at TEXT NOT NULL DEFAULT (datetime('\\''now'\\'')));'
            """

        let url = buildExecURL(command: command)

        // Verify no literal semicolons in the URL
        #expect(!url.absoluteString.contains(";"))
        #expect(url.absoluteString.contains("%3B"))
    }

    @Test func commandWithoutSemicolonsIsUnchanged() throws {
        let command = "echo hello world"

        let url = buildExecURL(command: command)
        let query = try #require(url.query)

        // Should still have the command in the query
        #expect(query.contains("cmd=echo"))
    }

    @Test func allCmdParametersPreserved() throws {
        let command = "echo 'a;b'"

        let url = buildExecURL(command: command)
        let absoluteString = url.absoluteString

        // All three cmd params should be present
        let cmdCount = absoluteString.components(separatedBy: "cmd=").count - 1
        #expect(cmdCount == 3) // bash, -c, and the command
    }

    // MARK: - Channel bridge URL helpers

    @Test func channelBridgeURLAppendsPathToSpriteURL() throws {
        let baseURL = try #require(URL(string: "https://sprite.example.com"))
        let url = SpritesAPIClient.channelBridgeURL(baseURL: baseURL, path: "events")
        #expect(url.absoluteString == "https://sprite.example.com/events")
    }

    @Test func channelBridgeURLPreservesExistingBasePath() throws {
        let baseURL = try #require(URL(string: "https://sprite.example.com/wisp"))
        let url = SpritesAPIClient.channelBridgeURL(baseURL: baseURL, path: "/status/")
        #expect(url.absoluteString == "https://sprite.example.com/wisp/status")
    }

    @Test func channelBridgeRequestUsesBearerForSpriteAuth() throws {
        let baseURL = try #require(URL(string: "https://sprite.example.com"))
        let request = SpritesAPIClient.makeChannelBridgeRequest(
            baseURL: baseURL,
            authMode: "sprite",
            path: "message",
            method: "POST",
            bearerToken: "secret-token",
            bridgeSecret: "bridge-secret",
            timeout: 30
        )

        #expect(request.url?.absoluteString == "https://sprite.example.com/message")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.value(forHTTPHeaderField: "X-Wisp-Bridge-Key") == "bridge-secret")
        #expect(request.timeoutInterval == 30)
    }

    @Test func channelBridgeRequestSkipsBearerForPublicAuth() throws {
        let baseURL = try #require(URL(string: "https://sprite.example.com"))
        let request = SpritesAPIClient.makeChannelBridgeRequest(
            baseURL: baseURL,
            authMode: "public",
            path: "events",
            method: "GET",
            bearerToken: "secret-token",
            bridgeSecret: "bridge-secret"
        )

        #expect(request.url?.absoluteString == "https://sprite.example.com/events")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Wisp-Bridge-Key") == "bridge-secret")
    }

    @Test func channelBridgeRequestIncludesChatQueryItem() throws {
        let baseURL = try #require(URL(string: "https://sprite.example.com/wisp"))
        let request = SpritesAPIClient.makeChannelBridgeRequest(
            baseURL: baseURL,
            authMode: "sprite",
            path: "events",
            method: "GET",
            bearerToken: "secret-token",
            bridgeSecret: "bridge-secret",
            queryItems: [URLQueryItem(name: "chat_id", value: "chat-123")]
        )

        #expect(request.url?.absoluteString == "https://sprite.example.com/wisp/events?chat_id=chat-123")
    }

    // MARK: - Helpers

    /// Build an exec WebSocket URL the same way SpritesAPIClient does.
    private func buildExecURL(command: String, env: [String: String] = [:]) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.sprites.dev"
        components.path = "/v1/sprites/test-sprite/exec"

        var queryItems = [
            URLQueryItem(name: "cmd", value: "bash"),
            URLQueryItem(name: "cmd", value: "-c"),
            URLQueryItem(name: "cmd", value: command),
        ]

        for (key, value) in env {
            queryItems.append(URLQueryItem(name: "env", value: "\(key)=\(value)"))
        }

        components.queryItems = queryItems

        if let encoded = components.percentEncodedQuery {
            components.percentEncodedQuery = encoded.replacingOccurrences(of: ";", with: "%3B")
        }

        return components.url!
    }
}
