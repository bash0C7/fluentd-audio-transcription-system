// swift/swiftcap/Sources/Swiftcap/ControlReader.swift
import Foundation

@available(macOS 26.0, *)
final class ControlReader {
    let controlURL: URL
    let posURL: URL

    init(controlURL: URL, posURL: URL) {
        self.controlURL = controlURL
        self.posURL = posURL
    }

    func readNew() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: controlURL.path) else { return [] }
        let off = readOffset()
        let handle = try FileHandle(forReadingFrom: controlURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: off)
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty else { return [] }
        var parsed: [[String: Any]] = []
        var consumed: UInt64 = 0
        let endsWithNewline = data.hasSuffix(Data([0x0A]))
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (idx, line) in lines.enumerated() {
            let isLast = idx == lines.count - 1
            // Trailing empty element produced by split when data ends with \n — not a real line.
            if isLast && endsWithNewline && line.isEmpty { break }
            // Trailing partial line (no newline yet) — skip without consuming.
            if isLast && !endsWithNewline { break }
            consumed += UInt64(line.count) + 1
            if line.isEmpty { continue }
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                parsed.append(obj)
            }
        }
        writeOffset(off + consumed)
        return parsed
    }

    private func readOffset() -> UInt64 {
        guard let data = try? Data(contentsOf: posURL),
              let s = String(data: data, encoding: .utf8),
              let v = UInt64(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 0 }
        return v
    }

    private func writeOffset(_ off: UInt64) {
        try? "\(off)".data(using: .utf8)!.write(to: posURL, options: .atomic)
    }
}

private extension Data {
    func hasSuffix(_ other: Data) -> Bool {
        guard count >= other.count else { return false }
        return suffix(other.count) == other
    }
}
