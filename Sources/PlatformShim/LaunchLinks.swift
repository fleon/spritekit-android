import Foundation

/// What a scene delegate's `scene(_:willConnectTo:options:)` decides on
/// Apple about the links a launch carries, as values: the link the game
/// opened with (a real one, from the intent that started it), the debug
/// launch arguments `-OpenLink`, `-OpenLinkAfter` and `-OpenCode`. The
/// game's own code then reads the strings.
public struct LaunchLinks: Equatable, Sendable {
    /// The link to open as the game starts: the real one, else `-OpenLink`
    /// unless `-OpenLinkAfter` holds it back.
    public var atLaunch: String?
    /// `-OpenCode`'s text (a code, a link or a message holding one), which
    /// the game uses only when the link at launch isn't one it opens.
    public var code: String?
    /// `-OpenLink`, opened `delay` seconds in with the game running, when
    /// `-OpenLinkAfter` gives the delay.
    public var later: String?
    public var delay: TimeInterval?

    public init(atLaunch: String? = nil, code: String? = nil, later: String? = nil, delay: TimeInterval? = nil) {
        self.atLaunch = atLaunch
        self.code = code
        self.later = later
        self.delay = delay
    }

    public static func plan(link: String?, openLink: String?, openLinkAfter: TimeInterval?, openCode: String?) -> LaunchLinks {
        let held = openLinkAfter != nil && openLink != nil
        return LaunchLinks(
            atLaunch: link ?? (openLinkAfter == nil ? openLink : nil),
            code: openCode,
            later: held ? openLink : nil,
            delay: held ? openLinkAfter : nil
        )
    }

    /// The argument the Android shell hands a real link under (MainActivity
    /// adds it to the launch's arguments), apart from the debug `-OpenLink`.
    public static let launchLinkArgument = "-LaunchLink"
}
