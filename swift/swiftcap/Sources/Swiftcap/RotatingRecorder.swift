// swift/swiftcap/Sources/Swiftcap/RotatingRecorder.swift
import AVFoundation
import Foundation

final class RotatingRecorder: @unchecked Sendable {
    private let channel: String
    private let spoolDir: URL
    private var currentURL: URL?
    private var assetWriter: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "swiftcap.recorder")

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
            let writer = try AVAssetWriter(outputURL: url, fileType: .caf)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 16000,
                AVEncoderBitRateKey: 64000
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

    func append(_ buffer: AVAudioPCMBuffer) throws {
        try queue.sync {
            guard let input = self.input,
                  let sampleBuffer = buffer.toCMSampleBuffer() else { return }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            input.append(sampleBuffer)
        }
    }

    func finalize(_ completion: @escaping @Sendable (URL) -> Void) {
        queue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  let input = self.input,
                  let url = self.currentURL else { return }
            input.markAsFinished()
            writer.finishWriting {
                self.assetWriter = nil
                self.input = nil
                self.currentURL = nil
                completion(url)
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
