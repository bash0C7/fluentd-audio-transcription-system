// swift/swiftcap/Sources/Swiftcap/SoundAnalyzerWrapper.swift
import AVFoundation
import Foundation
import SoundAnalysis

final class SoundAnalyzerWrapper: NSObject, SNResultsObserving, @unchecked Sendable {
    private let channel: String
    private let emitter: RecordEmitter
    private let analyzer: SNAudioStreamAnalyzer
    private let format: AVAudioFormat

    init(channel: String, emitter: RecordEmitter, format: AVAudioFormat) throws {
        self.channel = channel
        self.emitter = emitter
        self.analyzer = SNAudioStreamAnalyzer(format: format)
        self.format = format
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        try analyzer.add(request, withObserver: self)
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult, let top = r.classifications.first else { return }
        emitter.emit(stream: "sound", record: [
            "ts": Date().timeIntervalSince1970,
            "ch": channel,
            "started_at": r.timeRange.start.seconds,
            "ended_at": r.timeRange.end.seconds,
            "label": top.identifier,
            "confidence": top.confidence
        ])
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {}
    func requestDidComplete(_ request: SNRequest) {}
}
