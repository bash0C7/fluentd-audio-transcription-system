// swift/swiftcap/Sources/Swiftcap/SpoolWriter.swift
import Foundation

final class SpoolWriter {
    private let url: URL
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "swiftcap.spoolwriter")

    init(url: URL) {
        self.url = url
    }

    func append(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try queue.sync {
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try FileHandle(forWritingTo: url)
                try handle?.seekToEnd()
            }
            try handle?.write(contentsOf: data)
            try handle?.write(contentsOf: Data([0x0A]))
        }
    }

    func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }
}
