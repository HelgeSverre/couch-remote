import Foundation

/// UPnP RenderingControl on port 9197: read and set volume and mute directly, no pairing needed.
public struct RenderingControl: Sendable {
    public let host: String

    public init(host: String) { self.host = host }

    public func volume() async throws -> Int {
        let xml = try await call("GetVolume", arguments: "<Channel>Master</Channel>")
        guard let value = Self.value(of: "CurrentVolume", in: xml).flatMap(Int.init) else {
            throw URLError(.cannotParseResponse)
        }
        return value
    }

    public func setVolume(_ volume: Int) async throws {
        let clamped = min(100, max(0, volume))
        _ = try await call("SetVolume", arguments: "<Channel>Master</Channel><DesiredVolume>\(clamped)</DesiredVolume>")
    }

    public func isMuted() async throws -> Bool {
        let xml = try await call("GetMute", arguments: "<Channel>Master</Channel>")
        return Self.value(of: "CurrentMute", in: xml) == "1"
    }

    public func setMuted(_ muted: Bool) async throws {
        _ = try await call("SetMute", arguments: "<Channel>Master</Channel><DesiredMute>\(muted ? 1 : 0)</DesiredMute>")
    }

    private func call(_ action: String, arguments: String) async throws -> String {
        guard let url = URL(string: "http://\(host):9197/upnp/control/RenderingControl1") else {
            throw URLError(.badURL)
        }
        let service = "urn:schemas-upnp-org:service:RenderingControl:1"
        var request = URLRequest(url: url, timeoutInterval: 2.5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service)">\
        <InstanceID>0</InstanceID>\(arguments)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
        let (data, response) = try await TVRest.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return String(decoding: data, as: UTF8.self)
    }

    static func value(of tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
