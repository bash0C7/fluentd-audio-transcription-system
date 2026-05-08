import Foundation
import Testing
@testable import Swiftcap

@Suite("StdoutEmitterTests")
struct StdoutEmitterTests {
    @Test
    func emitsJsonLineWithStreamFieldAndTrailingNewline() throws {
        let pipe = Pipe()
        let emitter = StdoutEmitter(handle: pipe.fileHandleForWriting)
        emitter.emit(stream: "quick", record: ["ts": 1.0, "ch": "mic", "text": "hi"])
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)
        let obj = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(obj?["stream"] as? String == "quick")
        #expect(obj?["ch"] as? String == "mic")
        #expect(obj?["text"] as? String == "hi")
        #expect(s.hasSuffix("\n"))
    }

    @Test
    func emitsTwoLinesAsTwoSyscalls() throws {
        let pipe = Pipe()
        let emitter = StdoutEmitter(handle: pipe.fileHandleForWriting)
        emitter.emit(stream: "state", record: ["ts": 1.0, "kind": "session_started"])
        emitter.emit(stream: "final", record: ["ts": 2.0, "ch": "mic", "kind": "final", "text": "ok"])
        try pipe.fileHandleForWriting.close()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
    }
}
