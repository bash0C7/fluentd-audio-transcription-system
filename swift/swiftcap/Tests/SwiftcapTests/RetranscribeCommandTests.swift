import Testing
import Foundation
@testable import Swiftcap

@Suite("RetranscribeCommandTests")
struct RetranscribeCommandTests {
    @Test func parseArgsRequiresSessionId() {
        guard #available(macOS 26.0, *) else { return }
        let result = RetranscribeCommand.parse(args: ["--locale", "ja-JP"])
        #expect(result == nil, "missing --session-id should fail to parse")
    }

    @Test func parseArgsHappyPath() {
        guard #available(macOS 26.0, *) else { return }
        let res = RetranscribeCommand.parse(args: [
            "--session-id", "42", "--locale", "ja-JP", "--pass", "2"
        ])
        #expect(res != nil)
        #expect(res?.sessionId == 42)
        #expect(res?.locale.identifier == "ja-JP")
        #expect(res?.pass == 2)
    }

    @Test func parseArgsDefaults() {
        guard #available(macOS 26.0, *) else { return }
        let res = RetranscribeCommand.parse(args: ["--session-id", "7"])
        #expect(res != nil)
        #expect(res?.sessionId == 7)
        #expect(res?.pass == 2)
        #expect(res?.locale.identifier == "ja-JP")
    }
}
