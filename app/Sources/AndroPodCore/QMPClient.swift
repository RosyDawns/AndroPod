import Darwin
import Foundation

public enum QMPError: LocalizedError {
    case socket(String)
    case server(String)
    case protocolViolation(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .socket(let detail): return "连接失败：\(detail)"
        case .server(let detail): return "QEMU 拒绝：\(detail)"
        case .protocolViolation(let detail): return "协议异常：\(detail)"
        case .closed: return "QMP 连接已关闭"
        }
    }
}

/// Minimal QMP client over a unix socket.
///
/// This is the only place in the app that speaks QEMU's wire protocol. Nothing
/// here links against QEMU — that separation is what keeps the GPL boundary
/// intact (see docs/01-license-boundary.md).
public final class QMPClient {
    private var descriptor: Int32 = -1
    private var buffer: [UInt8] = []
    private var nextID = 0

    public init() {}

    deinit { close() }

    public var isConnected: Bool { descriptor >= 0 }

    public func connect(unixPath: String, timeout: TimeInterval = 5) throws {
        close()

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw QMPError.socket("无法创建 socket（errno \(errno)）")
        }
        descriptor = socketFD

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(unixPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw QMPError.socket("socket 路径过长")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source.prefix(destination.count))
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close()
            throw QMPError.socket(message)
        }

        _ = try readMessage()          // greeting
        _ = try execute("qmp_capabilities")
    }

    public func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        buffer.removeAll(keepingCapacity: false)
    }

    @discardableResult
    public func execute(_ command: String, arguments: [String: Any]? = nil) throws -> Any? {
        guard descriptor >= 0 else { throw QMPError.closed }
        nextID += 1
        let requestID = nextID
        var message: [String: Any] = ["execute": command, "id": requestID]
        if let arguments { message["arguments"] = arguments }
        try send(message)

        while true {
            let reply = try readMessage()
            if reply["event"] != nil { continue }
            guard let replyID = reply["id"] as? Int, replyID == requestID else { continue }
            if let error = reply["error"] as? [String: Any] {
                let description = (error["desc"] as? String) ?? "未知错误"
                throw QMPError.server(description)
            }
            return reply["return"]
        }
    }

    /// Human monitor command. Needed for `savevm` / `loadvm`, which carry full
    /// VM state and have no equivalent native QMP command.
    @discardableResult
    public func hmp(_ commandLine: String) throws -> String {
        let result = try execute("human-monitor-command", arguments: ["command-line": commandLine])
        return (result as? String) ?? ""
    }

    public func status() throws -> String {
        let result = try execute("query-status") as? [String: Any]
        return (result?["status"] as? String) ?? "unknown"
    }

    // MARK: - transport

    private func send(_ message: [String: Any]) throws {
        var payload = try JSONSerialization.data(withJSONObject: message)
        payload.append(0x0A)

        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                } else {
                    throw QMPError.socket(String(cString: strerror(errno)))
                }
            }
        }
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let count = Darwin.read(descriptor, &chunk, chunk.count)
        if count > 0 {
            buffer.append(contentsOf: chunk[0..<count])
        } else if count == 0 {
            throw QMPError.closed
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
            throw QMPError.socket("读取超时")
        } else {
            throw QMPError.socket(String(cString: strerror(errno)))
        }
    }

    private func readMessage() throws -> [String: Any] {
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[0..<end])
                buffer.removeFirst(end + 1)
                guard !line.isEmpty else { continue }
                let object = try JSONSerialization.jsonObject(with: Data(line))
                guard let dictionary = object as? [String: Any] else {
                    throw QMPError.protocolViolation("响应不是 JSON 对象")
                }
                return dictionary
            }
            try fill()
        }
    }
}
