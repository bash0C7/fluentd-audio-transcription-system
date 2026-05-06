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

        let url = await withCheckedContinuation { (cont: CheckedContinuation<URL, Never>) in
            recorder.finalize { url in cont.resume(returning: url) }
        }
        #expect(url.lastPathComponent.hasPrefix("mic-"))
        #expect(url.lastPathComponent.hasSuffix(".caf"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func appendedBufferProducesNonEmptyCAF() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = RotatingRecorder(channel: "mic", spoolDir: tmp)
        try recorder.start(at: Date(timeIntervalSince1970: 1735689600))
        try recorder.append(try makeSilentBuffer(seconds: 1))

        let url = await withCheckedContinuation { (cont: CheckedContinuation<URL, Never>) in
            recorder.finalize { url in cont.resume(returning: url) }
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        // 1 second of any reasonable PCM/AAC config produces well over 1 KB.
        // Empty-encoder failure on macOS 26 leaves the file at 0 bytes.
        #expect(bytes > 1024, "expected encoded CAF to be > 1KB, got \(bytes) bytes")

        let opened = try AVAudioFile(forReading: url)
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
