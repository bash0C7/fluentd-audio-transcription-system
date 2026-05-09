// swift/swiftcap/Sources/Swiftcap/StdoutEmitter.swift
import Foundation

protocol RecordEmitter: Sendable {
    func emit(stream: String, record: [String: Any])
}

final class StdoutEmitter: RecordEmitter, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle = FileHandle.standardOutput) {
        self.handle = handle
    }

    func emit(stream: String, record: [String: Any]) {
        var withStream = record
        withStream["stream"] = stream
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: withStream, options: [.sortedKeys])
        } catch {
            FileHandle.standardError.write(
                "StdoutEmitter: JSONSerialization failed stream=\(stream) error=\(error)\n".data(using: .utf8) ?? Data())
            return
        }
        var line = data
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.write(contentsOf: line)
        } catch {
            FileHandle.standardError.write(
                "StdoutEmitter: write failed stream=\(stream) error=\(error)\n".data(using: .utf8) ?? Data())
        }
    }
}

final class CapturingEmitter: RecordEmitter, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(stream: String, record: [String: Any])] = []

    func emit(stream: String, record: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        records.append((stream, record))
    }

    func snapshot() -> [(stream: String, record: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    func filter(stream: String) -> [[String: Any]] {
        snapshot().filter { $0.stream == stream }.map { $0.record }
    }
}
