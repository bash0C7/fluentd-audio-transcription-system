// swift/swiftcap/Sources/Swiftcap/ControlSocketClient.swift
import Foundation
import Darwin

@available(macOS 26.0, *)
final class ControlSocketClient {
    private let fd: Int32

    init(socketPath: String) throws {
        let f = socket(AF_UNIX, SOCK_STREAM, 0)
        guard f >= 0 else {
            throw NSError(domain: "ControlSocketClient", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed: \(String(cString: strerror(errno)))"])
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(f)
            throw NSError(domain: "ControlSocketClient", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(socketPath)"])
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            for (i, b) in pathBytes.enumerated() {
                rawBuf[i] = b
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(f, sa, len)
            }
        }
        guard rc == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(f)
            throw NSError(domain: "ControlSocketClient", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "connect() to \(socketPath) failed: \(err)"])
        }
        self.fd = f
    }

    func emit(stream: String, record: [String: Any]) throws {
        let payload: [String: Any] = ["kind": "emit", "stream": stream, "record": record]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        try writeAll(line)
    }

    func sendBoundary() throws { try writeKind("boundary") }
    func sendMuteToggle() throws { try writeKind("mute_toggle") }

    private func writeKind(_ kind: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["kind": kind], options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        try writeAll(line)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buf in
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), remaining)
                if written < 0 {
                    throw NSError(domain: "ControlSocketClient", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "write() failed: \(String(cString: strerror(errno)))"])
                }
                offset += written
                remaining -= written
            }
        }
    }

    func close() {
        Darwin.shutdown(fd, SHUT_WR)  // send FIN before close so NWListener delivers the connection
        Darwin.close(fd)
    }

    deinit { close() }
}
