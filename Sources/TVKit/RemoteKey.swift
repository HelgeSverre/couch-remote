import Foundation

/// A Samsung remote key code, e.g. `KEY_VOLUP`. Any `KEY_*` string the TV knows works.
public struct RemoteKey: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let power = RemoteKey("KEY_POWER")
    public static let up = RemoteKey("KEY_UP")
    public static let down = RemoteKey("KEY_DOWN")
    public static let left = RemoteKey("KEY_LEFT")
    public static let right = RemoteKey("KEY_RIGHT")
    public static let enter = RemoteKey("KEY_ENTER")
    public static let back = RemoteKey("KEY_RETURN")
    public static let home = RemoteKey("KEY_HOME")
    public static let info = RemoteKey("KEY_INFO")
    public static let play = RemoteKey("KEY_PLAY")
    public static let pause = RemoteKey("KEY_PAUSE")
    public static let volumeUp = RemoteKey("KEY_VOLUP")
    public static let volumeDown = RemoteKey("KEY_VOLDOWN")
    public static let mute = RemoteKey("KEY_MUTE")
    public static let channelUp = RemoteKey("KEY_CHUP")
    public static let channelDown = RemoteKey("KEY_CHDOWN")
    public static let source = RemoteKey("KEY_SOURCE")
    public static let tv = RemoteKey("KEY_TV")

    public static func digit(_ n: Int) -> RemoteKey { RemoteKey("KEY_\(n)") }
    public static func hdmi(_ n: Int) -> RemoteKey { RemoteKey("KEY_HDMI\(n)") }
}

/// How a key is sent: a tap, or press-and-hold split into press and release.
public enum KeyAction: String, Sendable {
    case click = "Click"
    case press = "Press"
    case release = "Release"
}
