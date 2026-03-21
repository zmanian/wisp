import Testing
import Foundation
@testable import Wisp

@Suite("API Models")
struct APIModelTests {

    private let decoder = JSONDecoder.apiDecoder()
    private let encoder = JSONEncoder.apiEncoder()

    // MARK: - Sprite

    @Test func decodeSpriteAllFields() throws {
        let json = """
        {
            "id": "sprite-1",
            "name": "my-sprite",
            "status": "running",
            "url": "https://my-sprite.sprites.dev",
            "created_at": "2025-01-15T10:30:00.123Z",
            "url_settings": {"auth": "public"}
        }
        """
        let sprite = try decoder.decode(Sprite.self, from: Data(json.utf8))
        #expect(sprite.id == "sprite-1")
        #expect(sprite.name == "my-sprite")
        #expect(sprite.status == .running)
        #expect(sprite.url == "https://my-sprite.sprites.dev")
        #expect(sprite.createdAt != nil)
        #expect(sprite.urlSettings?.auth == "public")
    }

    @Test func decodeSpriteOptionalFieldsMissing() throws {
        let json = """
        {
            "id": "sprite-2",
            "name": "minimal",
            "status": "cold"
        }
        """
        let sprite = try decoder.decode(Sprite.self, from: Data(json.utf8))
        #expect(sprite.id == "sprite-2")
        #expect(sprite.name == "minimal")
        #expect(sprite.status == .cold)
        #expect(sprite.url == nil)
        #expect(sprite.createdAt == nil)
        #expect(sprite.urlSettings == nil)
    }

    @Test func spriteStatusDecodesKnownValues() throws {
        for (raw, expected) in [("running", SpriteStatus.running), ("warm", .warm), ("cold", .cold)] {
            let json = #""\#(raw)""#
            let status = try JSONDecoder().decode(SpriteStatus.self, from: Data(json.utf8))
            #expect(status == expected)
        }
    }

    @Test func spriteStatusUnknownValue() throws {
        let json = #""suspended""#
        let status = try JSONDecoder().decode(SpriteStatus.self, from: Data(json.utf8))
        #expect(status == .unknown)
    }

    @Test func spriteStatusDisplayName() {
        #expect(SpriteStatus.running.displayName == "Running")
        #expect(SpriteStatus.warm.displayName == "Warm")
        #expect(SpriteStatus.cold.displayName == "Cold")
        #expect(SpriteStatus.unknown.displayName == "Unknown")
    }

    @Test func spriteRoundTrip() throws {
        let json = """
        {
            "id": "sprite-rt",
            "name": "roundtrip",
            "status": "warm",
            "url": "https://rt.sprites.dev",
            "created_at": "2025-06-01T12:00:00Z"
        }
        """
        let sprite = try decoder.decode(Sprite.self, from: Data(json.utf8))
        let encoded = try encoder.encode(sprite)
        let decoded = try decoder.decode(Sprite.self, from: encoded)
        #expect(decoded.id == sprite.id)
        #expect(decoded.name == sprite.name)
        #expect(decoded.status == sprite.status)
        #expect(decoded.url == sprite.url)
    }

    // MARK: - Checkpoint

    @Test func decodeCheckpointAllFields() throws {
        let json = """
        {
            "id": "cp-1",
            "create_time": "2025-03-10T08:15:30.456Z",
            "is_auto": true,
            "comment": "before refactor",
            "source_id": "cp-0"
        }
        """
        let checkpoint = try decoder.decode(Checkpoint.self, from: Data(json.utf8))
        #expect(checkpoint.id == "cp-1")
        #expect(checkpoint.createTime != nil)
        #expect(checkpoint.isAuto == true)
        #expect(checkpoint.comment == "before refactor")
        #expect(checkpoint.sourceId == "cp-0")
    }

    @Test func decodeCheckpointOptionalFieldsMissing() throws {
        let json = #"{"id": "cp-2"}"#
        let checkpoint = try decoder.decode(Checkpoint.self, from: Data(json.utf8))
        #expect(checkpoint.id == "cp-2")
        #expect(checkpoint.createTime == nil)
        #expect(checkpoint.isAuto == nil)
        #expect(checkpoint.comment == nil)
        #expect(checkpoint.sourceId == nil)
    }

    @Test func checkpointRoundTrip() throws {
        let json = """
        {
            "id": "cp-rt",
            "create_time": "2025-06-01T12:00:00Z",
            "is_auto": false,
            "comment": "manual save"
        }
        """
        let checkpoint = try decoder.decode(Checkpoint.self, from: Data(json.utf8))
        let encoded = try encoder.encode(checkpoint)
        let decoded = try decoder.decode(Checkpoint.self, from: encoded)
        #expect(decoded.id == checkpoint.id)
        #expect(decoded.isAuto == checkpoint.isAuto)
        #expect(decoded.comment == checkpoint.comment)
    }

    // MARK: - Channel bridge

    @Test func channelBridgeMessageRequestUsesSnakeCaseKeys() throws {
        let request = ChannelBridgeMessageRequest(
            chatId: "chat-123",
            text: "Ship it",
            workingDirectory: "/home/sprite/project",
            sessionId: "sess-123",
            model: "claude-sonnet-4",
            maxTurns: 10,
            customInstructions: "Be concise",
            attachments: ["/tmp/spec.md"]
        )

        let data = try encoder.encode(request)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(jsonObject["chat_id"] as? String == "chat-123")
        #expect(jsonObject["working_directory"] as? String == "/home/sprite/project")
        #expect(jsonObject["session_id"] as? String == "sess-123")
        #expect(jsonObject["max_turns"] as? Int == 10)
        #expect(jsonObject["custom_instructions"] as? String == "Be concise")
    }

    @Test func decodeChannelBridgeStatus() throws {
        let json = """
        {
            "is_running": true,
            "is_busy": false,
            "activity": "Waiting for Claude",
            "session_id": "sess-abc"
        }
        """

        let status = try decoder.decode(ChannelBridgeStatus.self, from: Data(json.utf8))
        #expect(status.isRunning == true)
        #expect(status.isBusy == false)
        #expect(status.activity == "Waiting for Claude")
        #expect(status.sessionId == "sess-abc")
    }

    @Test func channelBridgeInterruptRequestUsesSnakeCaseKey() throws {
        let request = ChannelBridgeInterruptRequest(chatId: "chat-456")
        let data = try encoder.encode(request)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(jsonObject["chat_id"] as? String == "chat-456")
    }
}
