// swift/swiftcap/Tests/SwiftcapTests/SmokeTests.swift
import Testing

@Suite
struct SmokeTests {
    @Test
    func testOnePlusOne() {
        #expect(1 + 1 == 2)
    }
}
