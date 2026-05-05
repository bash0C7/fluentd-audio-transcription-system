// swift/swiftcap/Tests/SwiftcapTests/SpoolWriterTests.swift
import Foundation
import Testing
@testable import Swiftcap

@Suite
struct SpoolWriterTests {
    @Test
    func appendsEachLineWithTrailingNewline() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = SpoolWriter(url: tmp.appendingPathComponent("quick.jsonl"))
        try writer.append(["ts": 1.0, "ch": "mic", "text": "hi"])
        try writer.append(["ts": 2.0, "ch": "mic", "text": "hello"])
        writer.close()

        let contents = try String(contentsOf: tmp.appendingPathComponent("quick.jsonl"), encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"text\":\"hi\""))
        #expect(lines[1].contains("\"text\":\"hello\""))
    }
}
