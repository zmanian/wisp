import Foundation

actor ClaudeStreamParser {
    private var buffer = Data()
    private let decoder = JSONDecoder.apiDecoder()

    func parse(data: Data) -> [ClaudeStreamEvent] {
        buffer.append(data)

        var events: [ClaudeStreamEvent] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            guard !lineData.isEmpty else { continue }

            do {
                let event = try decoder.decode(ClaudeStreamEvent.self, from: Data(lineData))
                events.append(event)
            } catch {
                // Skip lines that can't be decoded (forward compatibility)
            }
        }

        return events
    }

    func reset() {
        buffer = Data()
    }

    func flush() -> [ClaudeStreamEvent] {
        guard !buffer.isEmpty else { return [] }

        let remaining = buffer
        buffer = Data()

        do {
            let event = try decoder.decode(ClaudeStreamEvent.self, from: remaining)
            return [event]
        } catch {
            return []
        }
    }
}

struct ServerSentEvent: Sendable, Equatable {
    let event: String?
    let id: String?
    let data: String
    let retry: Int?
}

actor ServerSentEventParser {
    private var eventName: String?
    private var eventId: String?
    private var dataLines: [String] = []
    private var retry: Int?

    func parse(line: String) -> ServerSentEvent? {
        if line.isEmpty {
            return flushCurrentEvent()
        }

        if line.hasPrefix(":") {
            return nil
        }

        let field: String
        var value = ""

        if let separator = line.firstIndex(of: ":") {
            field = String(line[..<separator])
            value = String(line[line.index(after: separator)...])
            if value.first == " " {
                value.removeFirst()
            }
        } else {
            field = line
        }

        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
        case "id":
            eventId = value
        case "retry":
            retry = Int(value)
        default:
            break
        }

        return nil
    }

    func finish() -> ServerSentEvent? {
        flushCurrentEvent()
    }

    private func flushCurrentEvent() -> ServerSentEvent? {
        guard !dataLines.isEmpty || eventName != nil || eventId != nil || retry != nil else {
            reset()
            return nil
        }

        let event = ServerSentEvent(
            event: eventName,
            id: eventId,
            data: dataLines.joined(separator: "\n"),
            retry: retry
        )
        reset()
        return event
    }

    private func reset() {
        eventName = nil
        eventId = nil
        dataLines = []
        retry = nil
    }
}
