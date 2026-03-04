import Testing
import SwiftUI
@testable import Wisp

@Suite("NetworkRequestEntry")
struct NetworkRequestEntryTests {

    // MARK: - Status color

    @Test func statusColorForSuccess() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "https://example.com/", status: 200, durationMs: 50, error: nil)
        #expect(entry.statusColor == Color.green)
    }

    @Test func statusColorForRedirect() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "https://example.com/", status: 301, durationMs: 10, error: nil)
        #expect(entry.statusColor == Color.blue)
    }

    @Test func statusColorForClientError() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "https://example.com/", status: 404, durationMs: 80, error: nil)
        #expect(entry.statusColor == Color.orange)
    }

    @Test func statusColorForServerError() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "https://example.com/", status: 500, durationMs: 200, error: nil)
        #expect(entry.statusColor == Color.red)
    }

    @Test func statusColorForNetworkError() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "https://example.com/", status: nil, durationMs: 5, error: "TypeError: Failed to fetch")
        #expect(entry.statusColor == Color.red)
    }

    // MARK: - displayPath

    @Test func displayPathExtractsPath() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "https://api.example.com/users/123", status: 200, durationMs: 30, error: nil)
        #expect(entry.displayPath == "/users/123")
    }

    @Test func displayPathReturnsSlashForEmptyPath() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "https://api.example.com", status: 200, durationMs: 30, error: nil)
        #expect(entry.displayPath == "/")
    }

    @Test func displayPathFallsBackToRawStringForInvalidURL() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "not a valid url", status: 200, durationMs: 30, error: nil)
        #expect(entry.displayPath == "not a valid url")
    }

    // MARK: - formattedDuration

    @Test func formattedDurationUnderOneSecond() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "https://example.com/", status: 200, durationMs: 123, error: nil)
        #expect(entry.formattedDuration == "123ms")
    }

    @Test func formattedDurationAtExactlyOneSecond() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "https://example.com/", status: 200, durationMs: 1000, error: nil)
        #expect(entry.formattedDuration == "1.0s")
    }

    @Test func formattedDurationOverOneSecond() {
        let entry = NetworkRequestEntry(method: "GET", urlString: "https://example.com/", status: 200, durationMs: 2450, error: nil)
        #expect(entry.formattedDuration == "2.5s")
    }

    // MARK: - Initialisation

    @Test func entryStoresAllFields() {
        let entry = NetworkRequestEntry(method: "POST", urlString: "https://api.example.com/data", status: 201, durationMs: 88, error: nil)
        #expect(entry.method == "POST")
        #expect(entry.urlString == "https://api.example.com/data")
        #expect(entry.status == 201)
        #expect(entry.durationMs == 88)
        #expect(entry.error == nil)
    }

    @Test func eachEntryHasUniqueID() {
        let a = NetworkRequestEntry(method: "GET", urlString: "https://example.com/a", status: 200, durationMs: 10, error: nil)
        let b = NetworkRequestEntry(method: "GET", urlString: "https://example.com/b", status: 200, durationMs: 10, error: nil)
        #expect(a.id != b.id)
    }

    // MARK: - Message body parsing (mirrors WeakScriptMessageHandler logic)

    @Test func parsesValidSuccessBody() {
        let body: [String: Any] = ["method": "GET", "url": "https://example.com/api", "status": 200, "duration": 45.0]
        let method = body["method"] as? String
        let urlString = body["url"] as? String
        let status = body["status"] as? Int
        let durationMs = body["duration"] as? Double ?? 0
        let error = body["error"] as? String

        #expect(method == "GET")
        #expect(urlString == "https://example.com/api")
        #expect(status == 200)
        #expect(durationMs == 45.0)
        #expect(error == nil)
    }

    @Test func parsesValidErrorBody() {
        let body: [String: Any] = ["method": "POST", "url": "https://example.com/api", "duration": 12.0, "error": "TypeError: Failed to fetch"]
        let status = body["status"] as? Int
        let error = body["error"] as? String

        #expect(status == nil)
        #expect(error == "TypeError: Failed to fetch")
    }

    @Test func rejectsBodyMissingMethodKey() {
        let body: [String: Any] = ["url": "https://example.com/api", "status": 200, "duration": 10.0]
        #expect(body["method"] as? String == nil)
    }

    @Test func rejectsBodyMissingURLKey() {
        let body: [String: Any] = ["method": "GET", "status": 200, "duration": 10.0]
        #expect(body["url"] as? String == nil)
    }
}
