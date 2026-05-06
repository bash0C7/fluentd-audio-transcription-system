// swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift
@preconcurrency import AVFoundation
import Foundation

final class RotatingRecorder: @unchecked Sendable {
    private let channel: String
    private let spoolDir: URL
    private var currentURL: URL?
    private var assetWriter: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "swiftcap.recorder")
    private var startedAt: TimeInterval = 0

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(channel: String, spoolDir: URL) {
        self.channel = channel
        self.spoolDir = spoolDir
    }

    func start(at date: Date = Date()) throws {
        try queue.sync {
            let stamp = Self.formatter.string(from: date)
            let url = spoolDir.appendingPathComponent("\(channel)-\(stamp).caf")
            currentURL = url
            startedAt = date.timeIntervalSince1970
            let writer = try AVAssetWriter(outputURL: url, fileType: .caf)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC_HE,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 16000,
                AVEncoderBitRateKey: 32000
            ]
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            writerInput.expectsMediaDataInRealTime = true
            writer.add(writerInput)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            self.assetWriter = writer
            self.input = writerInput
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Drop buffers under backpressure — never block the queue. Earlier
        // versions spun on `isReadyForMoreMediaData`, which deadlocked finalize
        // because the HE-AAC encoder leaves the input not-ready while it
        // flushes, and the spinning append then blocked the serial queue
        // forever, preventing finalize's queue.async block from ever starting.
        queue.async { [weak self] in
            guard let self,
                  let input = self.input,
                  input.isReadyForMoreMediaData,
                  let sampleBuffer = buffer.toCMSampleBuffer() else { return }
            input.append(sampleBuffer)
        }
    }

    func finalize(_ completion: @escaping @Sendable (URL, TimeInterval, TimeInterval) -> Void) {
        queue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  let input = self.input,
                  let url = self.currentURL else { return }
            let startedAt = self.startedAt
            input.markAsFinished()
            writer.finishWriting {
                let endedAt = Date().timeIntervalSince1970
                self.assetWriter = nil
                self.input = nil
                self.currentURL = nil
                completion(url, startedAt, endedAt)
            }
        }
    }
}

extension AVAudioPCMBuffer {
    func toCMSampleBuffer() -> CMSampleBuffer? {
        var asbd = format.streamDescription.pointee
        var formatDesc: CMFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil,
                                             asbd: &asbd,
                                             layoutSize: 0,
                                             layout: nil,
                                             magicCookieSize: 0,
                                             magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &formatDesc) == noErr,
              let formatDesc else { return nil }
        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(asbd.mSampleRate)),
                                        presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var timingArray = [timing]
        guard CMSampleBufferCreate(allocator: nil,
                                   dataBuffer: nil,
                                   dataReady: false,
                                   makeDataReadyCallback: nil,
                                   refcon: nil,
                                   formatDescription: formatDesc,
                                   sampleCount: CMItemCount(frameLength),
                                   sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timingArray,
                                   sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil,
                                   sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer,
                                                              blockBufferAllocator: nil,
                                                              blockBufferMemoryAllocator: nil,
                                                              flags: 0,
                                                              bufferList: audioBufferList) == noErr else { return nil }
        return sampleBuffer
    }
}
