import Foundation

enum ClaudeStreamEvent: Sendable {
    case system(ClaudeSystemEvent)
    case assistant(ClaudeAssistantEvent)
    case user(ClaudeToolResultEvent)
    case result(ClaudeResultEvent)
    case unknown(String)

    var uuid: String? {
        switch self {
        case .system(let e): e.uuid
        case .assistant(let e): e.uuid
        case .user(let e): e.uuid
        case .result(let e): e.uuid
        case .unknown: nil
        }
    }
}

extension ClaudeStreamEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        let singleContainer = try decoder.singleValueContainer()

        switch type {
        case "system":
            self = .system(try singleContainer.decode(ClaudeSystemEvent.self))
        case "assistant":
            self = .assistant(try singleContainer.decode(ClaudeAssistantEvent.self))
        case "user":
            self = .user(try singleContainer.decode(ClaudeToolResultEvent.self))
        case "result":
            self = .result(try singleContainer.decode(ClaudeResultEvent.self))
        default:
            self = .unknown(type)
        }
    }
}
