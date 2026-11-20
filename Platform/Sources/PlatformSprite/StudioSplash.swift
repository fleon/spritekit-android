import Foundation
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
import UIKit
#endif

/// When a launch splash is done: once its minimum time has passed and the
/// game has reported every condition it waits for ready, or once its
/// maximum time has passed, whichever comes first, and only once. Kept apart
/// from SpriteKit's actions so it can be checked on its own.
public struct StudioSplashGate: Equatable, Sendable {
    /// What the splash still waits for.
    public private(set) var pending: Set<String>
    public private(set) var minimumPassed = false
    public private(set) var finished = false

    public init(waitingFor conditions: Set<String> = []) {
        pending = conditions
    }

    /// The minimum time passed. True when the splash should finish now.
    public mutating func minimumElapsed() -> Bool {
        minimumPassed = true
        return finishIfReady()
    }

    /// The maximum time passed: it finishes now, ready or not, unless it has.
    public mutating func maximumElapsed() -> Bool {
        finish()
    }

    /// `condition` is ready. True when the splash should finish now.
    public mutating func ready(_ condition: String) -> Bool {
        pending.remove(condition)
        return finishIfReady()
    }

    private mutating func finishIfReady() -> Bool {
        guard minimumPassed, pending.isEmpty else { return false }
        return finish()
    }

    private mutating func finish() -> Bool {
        guard !finished else { return false }
        finished = true
        return true
    }
}

#if canImport(UIKit) || !canImport(Darwin)

/// A studio's splash at launch: a logo over a footer line or two on a plain
/// background. It holds at least `Style.minimumDuration` and until the game
/// reports each of its conditions `ready` (signed in to its game service,
/// its feed answered…), never past `Style.maximumDuration`, then calls
/// `onReady`; `present(_:in:)` crossfades from it into the game's first
/// scene. Everything that names the studio is the game's: the logo's asset,
/// the footer's text and font, the colours and the timings.
///
///     let splash = StudioSplashScene(size: view.bounds.size, style: style, waitingFor: ["gameCenter"])
///     splash.scaleMode = .resizeFill
///     splash.onReady = { splash.present(firstScene(), in: view) }
///     view.presentScene(splash)
///     // once the view is on screen:
///     splash.startLoading()
///     // when the game's service first answers:
///     splash.ready("gameCenter")
///
/// It lays itself out for any size, upright or turned: the logo centred, the
/// footer above the bottom of the safe area. Call `layoutFooter()` when the
/// view's safe area changes (`viewDidLayoutSubviews`).
public final class StudioSplashScene: SKScene {
    public struct Style {
        /// The logo's image asset (`sprite(_:)`), shown at its own size.
        public var logo: String
        /// The footer's lines, top to bottom.
        public var footer: [String]
        /// The footer's font, registered by the game (`FontRegistry`).
        public var fontName: String
        public var fontSize: CGFloat
        public var textColor: UIColor
        public var backgroundColor: UIColor
        /// From the bottom of the safe area to the footer's last line.
        public var footerBottomInset: CGFloat
        /// From one footer line to the next.
        public var footerLineSpacing: CGFloat
        /// The splash shows at least this long…
        public var minimumDuration: TimeInterval
        /// …and no longer, whatever it still waits for.
        public var maximumDuration: TimeInterval
        /// The crossfade into the first scene (`present(_:in:)`).
        public var fadeDuration: TimeInterval

        public init(
            logo: String,
            footer: [String],
            fontName: String,
            fontSize: CGFloat = 10,
            textColor: UIColor = .white,
            backgroundColor: UIColor = .black,
            footerBottomInset: CGFloat = 24,
            footerLineSpacing: CGFloat = 16,
            minimumDuration: TimeInterval = 1,
            maximumDuration: TimeInterval = 3,
            fadeDuration: TimeInterval = 1
        ) {
            self.logo = logo
            self.footer = footer
            self.fontName = fontName
            self.fontSize = fontSize
            self.textColor = textColor
            self.backgroundColor = backgroundColor
            self.footerBottomInset = footerBottomInset
            self.footerLineSpacing = footerLineSpacing
            self.minimumDuration = minimumDuration
            self.maximumDuration = maximumDuration
            self.fadeDuration = fadeDuration
        }
    }

    private enum ActionKey {
        static let minimumDuration = "studio_splash.minimum_duration"
        static let maximumDuration = "studio_splash.maximum_duration"
    }

    /// Called once, when the splash is done.
    public var onReady: (() -> Void)?
    public let style: Style

    private var gate: StudioSplashGate
    private let footerNode = SKNode()
    private var isConfigured = false
    /// Whether `startLoading()` has run (it runs once).
    public private(set) var hasStartedLoading = false

    public init(size: CGSize, style: Style, waitingFor conditions: Set<String> = []) {
        self.style = style
        gate = StudioSplashGate(waitingFor: conditions)
        super.init(size: size)
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func didMove(to view: SKView) {
        guard !isConfigured else { return }
        isConfigured = true
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        backgroundColor = style.backgroundColor

        let logo = sprite(style.logo)
        logo.zPosition = 1
        addChild(logo)

        footerNode.zPosition = 1
        addChild(footerNode)
        for (index, text) in style.footer.enumerated() {
            let label = SKLabelNode(text: text)
            label.fontName = style.fontName
            label.fontSize = style.fontSize
            label.fontColor = style.textColor
            label.verticalAlignmentMode = .bottom
            label.position = CGPoint(x: 0, y: CGFloat(style.footer.count - 1 - index) * style.footerLineSpacing)
            footerNode.addChild(label)
        }
        layoutFooter()
    }

    public override func didChangeSize(_ oldSize: CGSize) {
        layoutFooter()
    }

    /// Keeps the footer above the bottom of the safe area.
    public func layoutFooter() {
        footerNode.position = CGPoint(
            x: 0,
            y: -size.height / 2 + (view?.safeAreaInsets.bottom ?? 0) + style.footerBottomInset
        )
    }

    /// Starts the clock: call it once the view is on screen.
    public func startLoading() {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        run(.sequence([
            .wait(forDuration: style.minimumDuration),
            .run { [weak self] in
                guard let self, self.gate.minimumElapsed() else { return }
                self.finish()
            },
        ]), withKey: ActionKey.minimumDuration)
        // What it waits for may never answer (offline, signed out): never
        // past the maximum.
        run(.sequence([
            .wait(forDuration: style.maximumDuration),
            .run { [weak self] in
                guard let self, self.gate.maximumElapsed() else { return }
                self.finish()
            },
        ]), withKey: ActionKey.maximumDuration)
    }

    /// The game's `condition` is ready.
    public func ready(_ condition: String) {
        guard gate.ready(condition) else { return }
        finish()
    }

    /// Crossfades from the splash into `scene` over `Style.fadeDuration`.
    public func present(_ scene: SKScene, in view: SKView) {
        view.presentScene(scene, transition: .crossFade(withDuration: style.fadeDuration))
    }

    private func finish() {
        removeAction(forKey: ActionKey.minimumDuration)
        removeAction(forKey: ActionKey.maximumDuration)
        let completion = onReady
        onReady = nil
        completion?()
    }
}

#endif
