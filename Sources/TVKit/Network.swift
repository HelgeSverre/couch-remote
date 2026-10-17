import Darwin
import Foundation
import Network

public enum WakeOnLAN {
    /// 6 × 0xFF followed by the MAC repeated 16 times.
    public static func packet(mac: String) -> Data? {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        return Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in bytes })
    }

    /// Sends the magic packet to the global broadcast and, when `host` is given, to its /24 broadcast.
    public static func send(mac: String, near host: String? = nil) throws {
        guard let packet = packet(mac: mac) else { throw URLError(.badURL) }
        var targets = ["255.255.255.255"]
        if let host, case let parts = host.split(separator: "."), parts.count == 4 {
            targets.append(parts.prefix(3).joined(separator: ".") + ".255")
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        for target in targets {
            var addr = sockaddr_in.ipv4(target, port: 9)
            _ = packet.withUnsafeBytes { buffer in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }
}

public struct DiscoveredTV: Sendable, Hashable, Identifiable {
    public let host: String
    public let name: String
    public let modelName: String
    public var id: String { host }
}

public enum Discovery {
    /// Looks for Samsung TVs two ways at once, then confirms each with the REST API:
    /// Bonjour (`_samsungmsf._tcp`, answered by the system's mDNS service) and an SSDP search.
    /// Some networks and macOS privacy settings block one of them; Bonjour proved the more reliable.
    public static func find(timeout: TimeInterval = 2.5) async -> [DiscoveredTV] {
        async let ssdp = Task.detached { ssdpHosts(timeout: timeout) }.value
        async let bonjour = bonjourHosts(timeout: timeout)
        let hosts = Set(await ssdp + bonjour)
        return await withTaskGroup(of: DiscoveredTV?.self) { group in
            for host in hosts {
                group.addTask {
                    guard let info = try? await TVRest.deviceInfo(host: host) else { return nil }
                    return DiscoveredTV(host: host, name: info.name, modelName: info.modelName)
                }
            }
            var found: [DiscoveredTV] = []
            for await tv in group { if let tv { found.append(tv) } }
            return found.sorted { $0.host < $1.host }
        }
    }

    /// IPv4 addresses of every `_samsungmsf._tcp` service (Samsung's multiscreen API, port 8001).
    static func bonjourHosts(timeout: TimeInterval) async -> [String] {
        let collector = BonjourCollector()
        let browser = NWBrowser(for: .bonjour(type: "_samsungmsf._tcp", domain: nil), using: .tcp)
        let queue = DispatchQueue(label: "TVKit.Discovery.bonjour")
        browser.browseResultsChangedHandler = { results, _ in
            for result in results { collector.resolve(result.endpoint, on: queue) }
        }
        browser.start(queue: queue)
        try? await Task.sleep(for: .seconds(timeout))
        browser.cancel()
        return collector.hosts
    }

    static func ssdpHosts(timeout: TimeInterval) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }

        let search = """
            M-SEARCH * HTTP/1.1\r
            HOST: 239.255.255.250:1900\r
            MAN: "ssdp:discover"\r
            MX: 2\r
            ST: urn:samsung.com:device:RemoteControlReceiver:1\r
            \r

            """
        let message = Array(search.utf8)
        var group = sockaddr_in.ipv4("239.255.255.250", port: 1900)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &group) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hosts = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(deadline.timeIntervalSinceNow * 1000)) > 0 else { break }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            if count > 0 { hosts.insert(String(cString: inet_ntoa(from.sin_addr))) }
        }
        return hosts.sorted()
    }
}

/// Turns Bonjour service endpoints into IPv4 addresses by briefly connecting to each.
private final class BonjourCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var found = Set<String>()
    private var started = Set<String>()

    var hosts: [String] { lock.withLock { found.sorted() } }

    func resolve(_ endpoint: NWEndpoint, on queue: DispatchQueue) {
        let key = "\(endpoint)"
        guard lock.withLock({ started.insert(key).inserted }) else { return }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready:
                if case .hostPort(let host, _)? = connection?.currentPath?.remoteEndpoint {
                    let address = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                    self?.lock.withLock { _ = self?.found.insert(address) }
                }
                connection?.cancel()
            case .failed, .waiting:
                connection?.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

extension sockaddr_in {
    static func ipv4(_ address: String, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(address)
        return addr
    }
}
