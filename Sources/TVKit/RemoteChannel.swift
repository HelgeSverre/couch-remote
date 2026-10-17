import Foundation

public enum RemoteChannelError: LocalizedError, Equatable {
    case unauthorized
    case timedOut
    case closed(String?)
    case notConnected
    case badAddress

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The TV declined the connection."
        case .timedOut: "The TV did not answer in time."
        case .closed(let reason): reason.map { "The TV closed the connection: \($0)" } ?? "The TV closed the connection."
        case .notConnected: "Not connected to the TV."
        case .badAddress: "The TV address is not valid."
        }
    }
}

public enum PointerButton: String, Sendable {
    case left = "LeftClick"
    case right = "RightClick"
}

public enum RemoteEvent: Sendable {
    /// Reply to `requestInstalledApps()`. Only pre-2020 firmware answers; newer TVs stay silent,
    /// so use `AppCatalog.scan` instead.
    case installedApps([TVApp])
    /// Reply to `requestIcon(path:)`. Pre-2020 firmware only, like `installedApps`.
    case icon(path: String, png: Data)
    /// The TV opened its on-screen keyboard; text sent now lands in that field.
    case keyboardShown
    case keyboardHidden
    case disconnected(String?)
}

/// The TV's remote-control WebSocket.
///
/// TVs that report `TokenAuthSupport: true` (2018 on) use `wss://<tv>:8002/...` with a token: the first
/// connection makes the TV show an Allow prompt, and accepting it returns a token that later connections
/// pass along. Older Tizen TVs use plain `ws://<tv>:8001/...` without a token (`secure: false`).
/// One instance is one connection: after `close()` make a new one.
public final class RemoteChannel: NSObject, @unchecked Sendable {
    public let host: String
    public let clientName: String
    /// `wss` on 8002 with a token, or plain `ws` on 8001 for TVs without token auth.
    public let secure: Bool
    public let events: AsyncStream<RemoteEvent>

    private let continuation: AsyncStream<RemoteEvent>.Continuation
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var waiter: CheckedContinuation<String?, Error>?
    private var connected = false
    private var pingTimer: DispatchSourceTimer?

    public init(host: String, clientName: String = "Couch Remote", secure: Bool = true) {
        self.host = host
        self.clientName = clientName
        self.secure = secure
        (events, continuation) = AsyncStream.makeStream(of: RemoteEvent.self, bufferingPolicy: .bufferingNewest(256))
        super.init()
    }

    public var isConnected: Bool { lock.withLock { connected } }

    /// Opens the socket and waits until the TV accepts it. Returns the token the TV sent, if any.
    public func connect(token: String?, timeout: TimeInterval = 8) async throws -> String? {
        guard let url = Self.url(host: host, clientName: clientName, token: token, secure: secure) else {
            throw RemoteChannelError.badAddress
        }
        return try await withCheckedThrowingContinuation { cont in
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: url)
            task.maximumMessageSize = 32 << 20 // icons arrive as base64 PNGs
            lock.withLock {
                self.session = session
                self.task = task
                self.waiter = cont
            }
            task.resume()
            receive(on: task)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.finishConnect(.failure(RemoteChannelError.timedOut)) else { return }
                self.close()
            }
        }
    }

    public func close() {
        let (task, session) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            defer {
                self.task = nil
                self.session = nil
                connected = false
                pingTimer?.cancel()
                pingTimer = nil
            }
            return (self.task, self.session)
        }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        finishConnect(.failure(RemoteChannelError.closed(nil)))
        continuation.finish()
    }

    // MARK: Commands

    public func sendKey(_ key: RemoteKey, action: KeyAction = .click) throws {
        try send([
            "method": "ms.remote.control",
            "params": ["Cmd": action.rawValue, "DataOfCmd": key.rawValue, "Option": "false", "TypeOfRemote": "SendRemoteKey"],
        ])
    }

    /// Moves the on-screen pointer (TV browser and pointer-aware apps) by a relative amount.
    /// Units are about one pixel of a 1920×1080 screen; negative values move left and up.
    public func movePointer(dx: Int, dy: Int) throws {
        try send([
            "method": "ms.remote.control",
            "params": ["Cmd": "Move", "Position": ["x": dx, "y": dy, "Time": "0"], "TypeOfRemote": "ProcessMouseDevice"],
        ])
    }

    public func clickPointer(_ button: PointerButton) throws {
        try send(["method": "ms.remote.control", "params": ["Cmd": button.rawValue, "TypeOfRemote": "ProcessMouseDevice"]])
    }

    public func requestInstalledApps() throws {
        try emit("ed.installedApp.get")
    }

    public func requestIcon(path: String) throws {
        try emit("ed.apps.icon", data: ["iconPath": path])
    }

    /// Launch over the socket. 2021 firmware ignores this; `TVRest.launch` works there.
    public func launch(appID: String, appType: Int = 2, metaTag: String = "") throws {
        try emit("ed.apps.launch", data: [
            "appId": appID,
            "action_type": appType == 4 ? "NATIVE_LAUNCH" : "DEEP_LINK",
            "metaTag": metaTag,
        ])
    }

    /// Replaces the contents of the TV's focused text field (tested: sending "ab" then "abc" leaves "abc").
    /// Only has an effect while the TV's keyboard is open.
    public func sendText(_ text: String) throws {
        try send([
            "method": "ms.remote.control",
            "params": ["Cmd": Data(text.utf8).base64EncodedString(), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"],
        ])
    }

    /// Confirms the on-screen keyboard, like pressing Done on the TV.
    public func endText() throws {
        try send(["method": "ms.remote.control", "params": ["TypeOfRemote": "SendInputEnd"]])
    }

    public func send(_ message: [String: Any]) throws {
        guard let task = lock.withLock({ connected ? self.task : nil }) else {
            throw RemoteChannelError.notConnected
        }
        let data = try JSONSerialization.data(withJSONObject: message)
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func emit(_ event: String, data: [String: Any]? = nil) throws {
        var params: [String: Any] = ["event": event, "to": "host"]
        if let data { params["data"] = data }
        try send(["method": "ms.channel.emit", "params": params])
    }

    // MARK: Internals

    static func url(host: String, clientName: String, token: String?, secure: Bool = true) -> URL? {
        var comps = URLComponents()
        comps.scheme = secure ? "wss" : "ws"
        comps.host = host
        comps.port = secure ? 8002 : 8001
        comps.path = "/api/v2/channels/samsung.remote.control"
        var items = [URLQueryItem(name: "name", value: Data(clientName.utf8).base64EncodedString())]
        if secure, let token { items.append(URLQueryItem(name: "token", value: token)) }
        comps.queryItems = items
        return comps.url
    }

    @discardableResult
    private func finishConnect(_ result: Result<String?, Error>) -> Bool {
        let pending: CheckedContinuation<String?, Error>? = lock.withLock {
            defer { waiter = nil }
            if case .success = result, waiter != nil { connected = true }
            return waiter
        }
        guard let pending else { return false }
        pending.resume(with: result)
        if case .success = result { startPinging() }
        return true
    }

    private func startPinging() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            self?.lock.withLock { self?.task }?.sendPing { _ in }
        }
        lock.withLock { pingTimer = timer }
        timer.resume()
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handle(Data(text.utf8))
                case .data(let data): self.handle(data)
                @unknown default: break
                }
                self.receive(on: task)
            case .failure(let error):
                self.handleClose(error.localizedDescription, task: task)
            }
        }
    }

    private func handleClose(_ reason: String?, task: URLSessionWebSocketTask) {
        guard lock.withLock({ self.task === task }) else { return }
        if isConnected { continuation.yield(.disconnected(reason)) }
        finishConnect(.failure(RemoteChannelError.closed(reason)))
        close()
    }

    static let debug = ProcessInfo.processInfo.environment["TVKIT_DEBUG"] != nil

    func handle(_ data: Data) {
        if Self.debug { FileHandle.standardError.write(Data("← \(String(decoding: data.prefix(600), as: UTF8.self))\n".utf8)) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String
        else { return }
        let payload = object["data"] as? [String: Any]

        switch event {
        case "ms.channel.connect":
            finishConnect(.success(payload?["token"] as? String))
        case "ms.channel.unauthorized":
            if finishConnect(.failure(RemoteChannelError.unauthorized)) { close() }
        case "ms.channel.timeOut":
            if finishConnect(.failure(RemoteChannelError.timedOut)) { close() }
        case "ed.installedApp.get":
            let list = payload?["data"] as? [[String: Any]] ?? []
            continuation.yield(.installedApps(list.compactMap(TVApp.init(json:))))
        case "ed.apps.icon":
            if let path = payload?["iconPath"] as? String,
               let base64 = payload?["imageBase64"] as? String,
               let png = Data(base64Encoded: base64) {
                continuation.yield(.icon(path: path, png: png))
            }
        case "ms.remote.imeStart":
            continuation.yield(.keyboardShown)
        case "ms.remote.imeEnd":
            continuation.yield(.keyboardHidden)
        default:
            break
        }
    }
}

extension RemoteChannel: URLSessionWebSocketDelegate {
    /// The TV serves a self-signed certificate. Trust it for this host only.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == host,
              let trust = space.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        handleClose(reason.flatMap { String(data: $0, encoding: .utf8) }, task: webSocketTask)
    }
}
