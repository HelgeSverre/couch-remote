import Darwin
import Foundation

public enum SDBError: LocalizedError {
    case unreachable(String)
    case protocolError(String)
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "Can't reach the TV's developer port (26101): \(detail). Is Developer Mode on, with this Mac's IP as Host PC IP?"
        case .protocolError(let detail): "Unexpected reply from the TV: \(detail)"
        case .remote(let message): message
        }
    }
}

/// Client for the TV's Smart Development Bridge, available while Developer Mode is on.
///
/// sdb is Tizen's fork of Android's adb and speaks the same wire protocol on port 26101: 24-byte headers
/// (`CNXN`, `OPEN`, `OKAY`, `WRTE`, `CLSE`) followed by payload. TVs accept no interactive shell, only
/// `shell:0 <command>` with commands like `vd_applist`, `applist`, `execute <app>` and `getduid`.
/// Each call opens its own connection; the TV only allows the host IP set in its Developer Mode dialog.
public struct SDB: Sendable {
    public let host: String
    public var port: UInt16 = 26101
    public var timeout: TimeInterval = 8

    public init(host: String) { self.host = host }

    /// Runs a restricted TV shell command, e.g. `shell("0 vd_applist")`, and returns its output.
    public func shell(_ command: String) async throws -> String {
        let data = try await run { try $0.stream(service: "shell:\(command)") }
        return String(decoding: data, as: UTF8.self)
    }

    /// Copies one file off the TV.
    public func pull(_ path: String) async throws -> Data {
        try await run { try $0.pull(path) }
    }

    /// Starts any app by its Tizen ID, system apps included (`org.volt.apps` is the Apps screen).
    public func execute(_ tizenAppID: String) async throws {
        let output = try await shell("0 execute \(tizenAppID)")
        guard output.contains("successfully launched") else { throw SDBError.remote(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Every user-facing app with its WAS ID, Tizen ID, install date and use count (`0 vd_applist`).
    public func installedApps() async throws -> [InstalledApp] {
        InstalledApp.parse(try await shell("0 vd_applist"))
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (SDBConnection) throws -> T) async throws -> T {
        let (host, port, timeout) = (host, port, timeout)
        return try await Task.detached {
            let connection = try SDBConnection(host: host, port: port, timeout: timeout)
            defer { connection.close() }
            return try body(connection)
        }.value
    }
}

/// One app from `0 vd_applist`.
public struct InstalledApp: Sendable, Equatable {
    public let id: String
    public let title: String
    public let tizenID: String
    public let version: String
    public let installDate: String
    public let useCount: Int
    /// Folder holding the app's Smart Hub tiles (`40x40.png` … `304x304.png`).
    public let iconDirectory: String

    static func parse(_ output: String) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var fields: [String: String] = [:]
        func flush() {
            guard let id = fields["app_id"] else { return }
            apps.append(InstalledApp(
                id: id,
                title: fields["app_title"] ?? id,
                tizenID: fields["app_tizen_id"] ?? "",
                version: fields["app_version"] ?? "",
                installDate: fields["install_date"] ?? "",
                useCount: Int(fields["use_count"] ?? "") ?? 0,
                iconDirectory: fields["app_panel_icon_path"] ?? ""
            ))
        }
        // Lines look like "--------------app_title   =Netflix-------------".
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "- \t\r"))
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
            if key == "app_id" {
                flush()
                fields = [:]
            }
            fields[key] = value
        }
        flush()
        return apps
    }
}

/// A blocking adb-protocol connection. Used from a detached task by `SDB`.
final class SDBConnection: @unchecked Sendable {
    private let fd: Int32
    private var nextLocalID: UInt32 = 1
    private var maxPayload = 4096

    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SDBError.unreachable("no socket") }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        try connect(host: host, port: port, timeout: timeout)

        try send("CNXN", 0x0200_0000, 256 * 1024, Data("host::\0".utf8))
        let reply = try receive()
        guard reply.command == "CNXN" else { throw SDBError.protocolError("expected CNXN, got \(reply.command)") }
        maxPayload = Int(min(reply.arg1, 256 * 1024))
    }

    func close() { Darwin.close(fd) }

    /// Opens a service and collects everything it writes until it closes.
    func stream(service: String) throws -> Data {
        let local = try open(service)
        var output = Data()
        while true {
            let message = try receive()
            switch message.command {
            case "WRTE":
                output.append(message.payload)
                try send("OKAY", local, message.arg0)
            case "OKAY": continue
            case "CLSE": return output
            default: throw SDBError.protocolError("unexpected \(message.command)")
            }
        }
    }

    /// adb sync protocol: `RECV <path>`, answered by `DATA` chunks then `DONE`, or `FAIL <reason>`.
    func pull(_ path: String) throws -> Data {
        let local = try open("sync:")
        var remote: UInt32 = 0
        // Wait for the OKAY that tells us the device-side ID.
        while remote == 0 {
            let message = try receive()
            guard message.command == "OKAY" else { throw SDBError.protocolError("sync: \(message.command)") }
            remote = message.arg0
        }
        var request = Data("RECV".utf8)
        request.append(le32(UInt32(path.utf8.count)))
        request.append(Data(path.utf8))
        try send("WRTE", local, remote, request)

        var buffer = Data()
        var file = Data()
        while true {
            let message = try receive()
            switch message.command {
            case "OKAY": continue
            case "CLSE": throw SDBError.protocolError("sync closed early")
            case "WRTE":
                buffer.append(message.payload)
                try send("OKAY", local, remote)
            default: throw SDBError.protocolError("unexpected \(message.command)")
            }
            // Consume whole sync records from the buffer.
            while buffer.count >= 8 {
                let id = String(decoding: buffer.prefix(4), as: UTF8.self)
                let length = Int(readLE32(buffer, at: 4))
                if id == "DONE" {
                    try? send("CLSE", local, remote)
                    return file
                }
                guard buffer.count >= 8 + length else { break }
                let body = buffer.subdata(in: buffer.startIndex + 8 ..< buffer.startIndex + 8 + length)
                buffer.removeFirst(8 + length)
                switch id {
                case "DATA": file.append(body)
                case "FAIL": throw SDBError.remote(String(decoding: body, as: UTF8.self))
                default: throw SDBError.protocolError("sync record \(id)")
                }
            }
        }
    }

    // MARK: Framing

    private func open(_ service: String) throws -> UInt32 {
        let local = nextLocalID
        nextLocalID += 1
        try send("OPEN", local, 0, Data((service + "\0").utf8))
        return local
    }

    private func send(_ command: String, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data = Data()) throws {
        let code = readLE32(Data(command.utf8), at: 0)
        var packet = Data()
        for value in [code, arg0, arg1, UInt32(payload.count), payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }, ~code] {
            packet.append(le32(value))
        }
        packet.append(payload)
        try writeAll(packet)
    }

    private func receive() throws -> (command: String, arg0: UInt32, arg1: UInt32, payload: Data) {
        let header = try readExactly(24)
        let command = String(decoding: header.prefix(4), as: UTF8.self)
        let length = Int(readLE32(header, at: 12))
        let payload = length > 0 ? try readExactly(length) : Data()
        return (command, readLE32(header, at: 4), readLE32(header, at: 8), payload)
    }

    // MARK: Socket

    private func connect(host: String, port: UInt16, timeout: TimeInterval) throws {
        var addr = sockaddr_in.ipv4(host, port: port)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 && errno != EINPROGRESS { throw SDBError.unreachable(String(cString: strerror(errno))) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { throw SDBError.unreachable("timed out") }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        guard error == 0 else { throw SDBError.unreachable(String(cString: strerror(error))) }
        _ = fcntl(fd, F_SETFL, flags)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                guard written > 0 else { throw SDBError.unreachable("connection lost") }
                offset += written
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < count {
                let read = recv(fd, buffer.baseAddress! + offset, count - offset, 0)
                guard read > 0 else { throw SDBError.unreachable(read == 0 ? "connection closed" : "timed out") }
                offset += read
            }
        }
        return data
    }
}

private func le32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func readLE32(_ data: Data, at offset: Int) -> UInt32 {
    data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + 4)
        .withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
}
