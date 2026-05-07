import Testing
import Foundation
@testable import Swiftcap

@Suite("ControlReaderTests")
struct ControlReaderTests {
    @Test func readNewParsesAppendedLines() throws {
        guard #available(macOS 26.0, *) else { return }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctrl-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ctrl = tmp.appendingPathComponent("control.jsonl")
        let pos = tmp.appendingPathComponent("control.pos")
        let reader = ControlReader(controlURL: ctrl, posURL: pos)

        try Data().write(to: ctrl) // empty
        let none = try reader.readNew()
        #expect(none.isEmpty)

        let line1 = #"{"ts":1.0,"kind":"boundary"}"# + "\n"
        try line1.data(using: .utf8)!.write(to: ctrl)
        let one = try reader.readNew()
        #expect(one.count == 1)
        #expect(one[0]["kind"] as? String == "boundary")

        let again = try reader.readNew()
        #expect(again.isEmpty, "offset should advance so re-read returns empty")
    }

    @Test func readNewSurvivesProcessRestart() throws {
        guard #available(macOS 26.0, *) else { return }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ctrl-reader-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ctrl = tmp.appendingPathComponent("control.jsonl")
        let pos = tmp.appendingPathComponent("control.pos")
        let line1 = #"{"ts":1.0,"kind":"boundary"}"# + "\n"
        try line1.data(using: .utf8)!.write(to: ctrl)

        let r1 = ControlReader(controlURL: ctrl, posURL: pos)
        _ = try r1.readNew()

        let line2 = #"{"ts":2.0,"kind":"mute_toggle"}"# + "\n"
        let handle = try FileHandle(forWritingTo: ctrl)
        handle.seekToEndOfFile()
        handle.write(line2.data(using: .utf8)!)
        try handle.close()

        let r2 = ControlReader(controlURL: ctrl, posURL: pos)
        let new = try r2.readNew()
        #expect(new.count == 1, "fresh reader should resume from saved offset")
        #expect(new[0]["kind"] as? String == "mute_toggle")
    }
}
