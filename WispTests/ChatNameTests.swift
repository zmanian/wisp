import Testing
import Foundation
@testable import Wisp

@Suite("ChatName")
struct ChatNameTests {

    @Test("Name is non-nil and non-empty for normal prompt")
    func chatNameFromPrompt() async {
        let name = await ChatViewModel.generateChatName(from: "How do I add dark mode to my iOS app?")
        #expect(name.isEmpty == false)
        #expect(name.count <= 80)
    }

    @Test("Name is capped at 80 chars")
    func chatNameMaxLength() async {
        let longPrompt = String(repeating: "a", count: 1000)
        let name = await ChatViewModel.generateChatName(from: longPrompt)
        #expect(name.count <= 80)
    }

    @Test("Empty prompt returns 'New Chat'")
    func chatNameFromEmptyPrompt() async {
        let name = await ChatViewModel.generateChatName(from: "")
        #expect(name == "New Chat")
    }

    @Test("Whitespace-only prompt returns 'New Chat'")
    func chatNameFromWhitespace() async {
        let name = await ChatViewModel.generateChatName(from: "   \n\t  ")
        #expect(name == "New Chat")
    }

    @Test("Multiline prompt uses first line as fallback base")
    func chatNameMultilinePrompt() async {
        let prompt = "Fix the login bug\nIt crashes when the user taps submit"
        let name = await ChatViewModel.generateChatName(from: prompt)
        #expect(name.isEmpty == false)
        #expect(name.count <= 80)
    }
}
