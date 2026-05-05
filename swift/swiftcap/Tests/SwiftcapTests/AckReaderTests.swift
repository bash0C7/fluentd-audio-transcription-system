// swift/swiftcap/Tests/SwiftcapTests/AckReaderTests.swift
import Foundation
import Testing
@testable import Swiftcap

@Suite
struct AckReaderTests {
    @Test
    func emitsConsumedPaths() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ackUrl = tmp.appendingPathComponent("ack.jsonl")
        let line1 = #"{"ts":1.0,"kind":"consumed","path":"/spool/mic-1.caf"}"# + "\n"
        let line2 = #"{"ts":2.0,"kind":"consumed","path":"/spool/screen-2.caf"}"# + "\n"
        try (line1 + line2).data(using: .utf8)!.write(to: ackUrl)

        let reader = AckReader(url: ackUrl)
        let consumed = try reader.readNew()
        #expect(consumed == ["/spool/mic-1.caf", "/spool/screen-2.caf"])

        let again = try reader.readNew()
        #expect(again == [])
    }
}
