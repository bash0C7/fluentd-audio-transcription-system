// swift/swiftcap/Sources/Swiftcap/ControlSocket.swift
import Foundation
import Network

@available(macOS 26.0, *)
final class ControlSocket: @unchecked Sendable {
    private let socketPath: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "swiftcap.controlsocket")

    init(socketPath: String) throws {
        self.socketPath = socketPath
        // Unlink stale file so bind succeeds.
        try? FileManager.default.removeItem(atPath: socketPath)
        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = endpoint
        self.listener = try NWListener(using: params)
    }

    func start(
        onBoundary: @escaping @Sendable () -> Void,
        onMuteToggle: @escaping @Sendable () -> Void,
        emitter: RecordEmitter
    ) throws {
        let readySemaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                readySemaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn,
                onBoundary: onBoundary,
                onMuteToggle: onMuteToggle,
                emitter: emitter)
        }
        listener.start(queue: queue)
        // Wait up to 2 seconds for the listener to become ready.
        _ = readySemaphore.wait(timeout: .now() + 2)
    }

    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func accept(
        _ conn: NWConnection,
        onBoundary: @escaping @Sendable () -> Void,
        onMuteToggle: @escaping @Sendable () -> Void,
        emitter: RecordEmitter
    ) {
        let buffer = Buffer()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(conn, buffer: buffer,
                              onBoundary: onBoundary,
                              onMuteToggle: onMuteToggle,
                              emitter: emitter)
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(
        _ conn: NWConnection,
        buffer: Buffer,
        onBoundary: @escaping @Sendable () -> Void,
        onMuteToggle: @escaping @Sendable () -> Void,
        emitter: RecordEmitter
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                buffer.append(data)
                while let line = buffer.takeLine() {
                    self?.dispatch(line: line,
                                   onBoundary: onBoundary,
                                   onMuteToggle: onMuteToggle,
                                   emitter: emitter)
                }
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self?.receive(conn, buffer: buffer,
                          onBoundary: onBoundary,
                          onMuteToggle: onMuteToggle,
                          emitter: emitter)
        }
    }

    private func dispatch(
        line: Data,
        onBoundary: @Sendable () -> Void,
        onMuteToggle: @Sendable () -> Void,
        emitter: RecordEmitter
    ) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        switch obj["kind"] as? String {
        case "boundary":
            onBoundary()
        case "mute_toggle":
            onMuteToggle()
        case "emit":
            if let stream = obj["stream"] as? String,
               let record = obj["record"] as? [String: Any] {
                emitter.emit(stream: stream, record: record)
            }
        default:
            FileHandle.standardError.write(
                "ControlSocket: unknown kind \(obj)\n".data(using: .utf8)!)
        }
    }

    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }
        func takeLine() -> Data? {
            lock.lock(); defer { lock.unlock() }
            guard let nl = data.firstIndex(of: 0x0A) else { return nil }
            let line = data[data.startIndex..<nl]
            data = data[data.index(after: nl)...]
            return Data(line)
        }
    }
}
