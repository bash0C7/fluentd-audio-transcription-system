// swift/swiftcap/Sources/Swiftcap/AckReader.swift
import Foundation

final class AckReader: @unchecked Sendable {
    private let url: URL
    private var offset: UInt64 = 0
    private var leftover: Data = Data()

    init(url: URL) {
        self.url = url
    }

    func readNew() throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let chunk = Data(handle.readDataToEndOfFile())
        offset += UInt64(chunk.count)
        var data = leftover
        data.append(chunk)
        leftover = Data()

        var paths: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<nl]
            data = data[data.index(after: nl)...]
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["kind"] as? String == "consumed",
                  let path = obj["path"] as? String else { continue }
            paths.append(path)
        }
        leftover = data
        return paths
    }
}
