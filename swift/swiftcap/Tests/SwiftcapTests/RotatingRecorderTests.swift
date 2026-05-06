// swift/swiftcap/Tests/SwiftcapTests/RotatingRecorderTests.swift
import Foundation
import AVFoundation
import Testing
@testable import Swiftcap

@Suite
struct RotatingRecorderTests {
    @Test
    func finalizeProducesCAFFile() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = RotatingRecorder(channel: "mic", spoolDir: tmp)
        try recorder.start(at: Date(timeIntervalSince1970: 1735689600))
        let buffer = try makeSilentBuffer(seconds: 1)
        try recorder.append(buffer)

        let result: (url: URL, startedAt: TimeInterval, endedAt: TimeInterval) =
            await withCheckedContinuation { (cont: CheckedContinuation<(URL, TimeInterval, TimeInterval), Never>) in
                recorder.finalize { url, startedAt, endedAt in
                    cont.resume(returning: (url, startedAt, endedAt))
                }
            }
        #expect(result.url.lastPathComponent.hasPrefix("mic-"))
        #expect(result.url.lastPathComponent.hasSuffix(".caf"))
        #expect(FileManager.default.fileExists(atPath: result.url.path))
    }

    @Test
    func finalizeCallbackCarriesStartedAndEndedAt() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let startDate = Date(timeIntervalSince1970: 1735689600)
        let recorder = RotatingRecorder(channel: "mic", spoolDir: tmp)
        try recorder.start(at: startDate)
        try recorder.append(try makeSilentBuffer(seconds: 1))

        let beforeFinalize = Date().timeIntervalSince1970
        let result = await withCheckedContinuation { (cont: CheckedContinuation<(URL, TimeInterval, TimeInterval), Never>) in
            recorder.finalize { url, startedAt, endedAt in
                cont.resume(returning: (url, startedAt, endedAt))
            }
        }

        #expect(result.1 == startDate.timeIntervalSince1970, "startedAt must equal start(at:) date")
        #expect(result.2 >= beforeFinalize, "endedAt must be >= time finalize was called")
    }

    @Test
    func appendedBufferProducesNonEmptyCAF() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = RotatingRecorder(channel: "mic", spoolDir: tmp)
        try recorder.start(at: Date(timeIntervalSince1970: 1735689600))
        try recorder.append(try makeSilentBuffer(seconds: 1))

        let result = await withCheckedContinuation { (cont: CheckedContinuation<(URL, TimeInterval, TimeInterval), Never>) in
            recorder.finalize { url, startedAt, endedAt in
                cont.resume(returning: (url, startedAt, endedAt))
            }
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: result.0.path)
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        #expect(bytes > 1024, "expected encoded CAF to be > 1KB, got \(bytes) bytes")

        let opened = try AVAudioFile(forReading: result.0)
        #expect(opened.length > 0, "AVAudioFile reports zero frames")
    }

    private func makeSilentBuffer(seconds: Int) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        return buf
    }
}
