import Foundation
import PlatformCore
import SpriteKitShim

/// How many frames a second the game draws, and how many of the screen's
/// pixels (`Graphics`), kept on this device (screens and GPUs differ). Each
/// is Auto until the player picks a value. Auto draws at 60 (or the fastest
/// the screen paces evenly below it: `autoFrameRate`), never slower, and
/// between Highest and Medium, as `RenderScaleGovernor` chooses once for the
/// device and keeps (`autoScale`). What it runs at now (`running`) is for
/// the settings to show. The renderer applies `choices`: on Apple
/// `RenderScaleController`, on Android the shell's renderer, through
/// `GameHost` (`DisplaySettingsHost` gives a game's controller those
/// members).
public enum DisplaySettings {
    public typealias Rung = RenderScaleGovernor.Rung

    /// What a game says about its display settings. Set it at launch,
    /// before anything reads them.
    public struct Configuration {
        /// The rates the player can pick, slowest first.
        public var frameRates = [30, 60, 120]
        /// The rate a screen that says nothing of its own draws at.
        public var defaultFrameRate = 60
        /// The fastest a picked rate draws in Low Power Mode.
        public var lowPowerFrameRate = 60
        /// Where the settings are kept: the store and the key prefix
        /// (`<prefix>frameRate`, `<prefix>renderScale`,
        /// `<prefix>graphicsAuto<rate>`; `<prefix>graphics` was a tier
        /// picked when there were three, which still reads).
        public var defaults: UserDefaults = .standard
        public var keyPrefix = "settings."
        /// Keys kept by an earlier way of choosing, removed once.
        public var obsoleteKeys: [String] = []
        /// Called with each key a pick wrote (or removed), for a game that
        /// syncs its settings across devices; `savedDataDidSync` hears them
        /// coming back.
        public var didSave: ((String) -> Void)?
        /// A scale nothing moves (a capture running, a test's pin), if any.
        public var pinnedRenderScale: () -> Double? = { nil }
        /// Whether the frames of `scene` measure how the game draws: not a
        /// loading screen's or a splash's, which say nothing of the scenes.
        public var isMeasured: (SKScene?) -> Bool = { $0 != nil }
        /// Whether Low Power Mode (Android's battery saver) is on.
        public var isLowPower: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
        /// Whether frames run late for reasons of their own (a simulator):
        /// Auto chooses nothing there and draws every pixel unless picked.
        public var isSimulator: Bool = {
            #if targetEnvironment(simulator)
            true
            #else
            false
            #endif
        }()
        /// Where it notes what it runs at and what Auto chose.
        public var log: ((String) -> Void)?

        public init() {}
    }

    public static var configuration = Configuration() {
        didSet { obsoleteKeysForgotten = false }
    }

    // MARK: Frame rate

    /// The rates the player can pick, as far as the screen goes
    /// (`screenMaximum`).
    public static var frameRates: [Int] {
        let configuration = configuration
        return configuration.frameRates.filter { $0 <= max(screenMaximum, configuration.defaultFrameRate) }
    }

    /// The fastest the screen draws, told by the view's controller once its
    /// view is on one (ProMotion's 120, a 50 Hz television's 50).
    public static var screenMaximum = Configuration().defaultFrameRate {
        didSet { if screenMaximum != oldValue { post(choicesDidChange) } }
    }

    /// The rate Auto draws at on this screen, on every device: 60, or 50 on
    /// a 50 Hz television (as if 60 Hz in Low Power Mode).
    public static var autoFrameRate: Int {
        RenderScaleGovernor.autoRates(refresh: screenMaximum, lowPower: configuration.isLowPower()).first ?? RenderScaleGovernor.fastestAutoRate
    }

    /// The rate picked, nil for Auto; a rate the screen can't draw falls
    /// back to the fastest it can.
    public static var pickedFrameRate: Int? {
        get {
            guard let saved = configuration.defaults.object(forKey: Key.frameRate) as? Int else { return nil }
            return frameRates.last { $0 <= saved } ?? frameRates.first
        }
        set {
            if let newValue {
                configuration.defaults.set(newValue, forKey: Key.frameRate)
            } else {
                configuration.defaults.removeObject(forKey: Key.frameRate)
            }
            configuration.didSave?(Key.frameRate)
            post(choicesDidChange)
        }
    }

    // MARK: Graphics

    /// The graphics tiers the player can pick: the shares of pixels Auto
    /// moves between (`RenderScaleGovernor.steps`), best first. A game
    /// names them in its own strings.
    public enum Graphics: String, CaseIterable, Sendable {
        case highest, high, medium, low, lowest

        public var renderScale: Double {
            let steps = RenderScaleGovernor.steps
            return steps[min(Self.allCases.firstIndex(of: self) ?? 0, steps.count - 1)]
        }

        /// The tier nearest `scale` (a pinned scale may fall between).
        public static func nearest(_ scale: Double) -> Graphics {
            allCases.min { abs($0.renderScale - scale) < abs($1.renderScale - scale) } ?? .highest
        }

        /// A tier picked when there were three (high, medium, low: every
        /// pixel, three quarters and half), as its share now.
        public static func legacyScale(_ raw: String) -> Double? {
            switch raw {
            case "high": Graphics.highest.renderScale
            case "medium": Graphics.medium.renderScale
            case "low": Graphics.lowest.renderScale
            default: nil
            }
        }
    }

    /// The tier picked, nil for Auto. One picked when there were three tiers
    /// keeps its share: High is now Highest, Low is Lowest.
    public static var pickedGraphics: Graphics? {
        get {
            let defaults = configuration.defaults
            if let scale = defaults.object(forKey: Key.renderScale) as? Double { return Graphics.nearest(scale) }
            return defaults.string(forKey: Key.graphics).flatMap(Graphics.legacyScale).map(Graphics.nearest)
        }
        set {
            let defaults = configuration.defaults
            if let newValue {
                defaults.set(newValue.renderScale, forKey: Key.renderScale)
            } else {
                defaults.removeObject(forKey: Key.renderScale)
            }
            defaults.removeObject(forKey: Key.graphics)
            configuration.didSave?(Key.renderScale)
            post(choicesDidChange)
        }
    }

    /// A scale nothing moves (`Configuration.pinnedRenderScale`).
    public static var pinnedRenderScale: Double? {
        configuration.pinnedRenderScale()
    }

    // MARK: Auto

    /// What the game view may draw at.
    public struct Choices: Equatable, Sendable {
        /// The rate: Auto's, or the one picked, Low Power Mode holding it
        /// to its ceiling.
        public var rate: Int
        /// The scales Auto chooses between, largest first (one, where
        /// picked or pinned).
        public var scales: [Double]
        /// Whether Auto still has a scale to choose: not where one's
        /// picked, nor in a simulator, nor while a scale is pinned.
        public var governs: Bool
        /// The scale this device chose before at this rate, which it keeps.
        public var decided: Double?

        public init(rate: Int, scales: [Double], governs: Bool, decided: Double?) {
            self.rate = rate
            self.scales = scales
            self.governs = governs
            self.decided = decided
        }

        /// As the shell's `GameHost.displayChoices` takes them.
        public var tuple: (rate: Int, scales: [Double], governs: Bool, decided: Double?) {
            (rate, scales, governs, decided)
        }
    }

    /// What the game view may draw at now (`Choices`).
    public static var choices: Choices {
        let configuration = configuration
        let lowPower = configuration.isLowPower()
        let rate = pickedFrameRate.map { lowPower ? min($0, configuration.lowPowerFrameRate) : $0 } ?? autoFrameRate
        let pinned = pinnedRenderScale
        let scales = pinned.map { [$0] } ?? pickedGraphics.map { [$0.renderScale] } ?? RenderScaleGovernor.autoSteps
        if configuration.isSimulator {
            let scale = pickedGraphics == nil && pinned == nil ? Graphics.highest.renderScale : scales[0]
            return Choices(rate: rate, scales: [scale], governs: false, decided: nil)
        }
        guard pinned == nil, scales.count > 1 else { return Choices(rate: rate, scales: [scales[0]], governs: false, decided: nil) }
        return Choices(rate: rate, scales: scales, governs: true, decided: autoScale(rate: rate))
    }

    /// The rate and scale the game view draws at now, which the settings
    /// show as Auto's (set by whatever applies them).
    public static var running = Rung(rate: RenderScaleGovernor.fastestAutoRate, scale: Graphics.highest.renderScale) {
        didSet {
            guard running != oldValue else { return }
            configuration.log?("[graphics] \(running)")
            post(runningDidChange)
        }
    }

    /// The scale Auto chose on this device at `rate`, kept for good.
    public static func autoScale(rate: Int) -> Double? {
        forgetObsoleteKeys()
        return configuration.defaults.object(forKey: Key.autoScale(rate)) as? Double
    }

    /// Auto chose `rung`'s scale at its rate: this device keeps it, and
    /// Auto never chooses again there.
    public static func noteAutoChosen(_ rung: Rung) {
        guard pinnedRenderScale == nil else { return }
        configuration.log?("[graphics] Auto chose \(rung)")
        configuration.defaults.set(rung.scale, forKey: Key.autoScale(rung.rate))
    }

    /// How long a frame at `rate` has on a screen refreshing `refresh`
    /// times a second at most: as many refreshes as the rate asks for,
    /// rounded up, since a frame can only show on one. A 50 Hz television
    /// shows 60 a second every 20 ms and 30 every 40 ms, which a budget of
    /// 1/60 or 1/30 would count late however light the scene, stepping the
    /// scale all the way down. In Low Power Mode a ProMotion display
    /// refreshes at 60 Hz at most.
    public static func frameBudget(rate: Int, refresh: Int?) -> Double {
        let rate = Double(max(rate, 1))
        guard let refresh, refresh > 0 else { return 1 / rate }
        let paced = RenderScaleGovernor.pacedRefresh(refresh, lowPower: configuration.isLowPower())
        let refreshes = max((Double(paced) / rate - 1e-6).rounded(.up), 1)
        return refreshes / Double(paced)
    }

    // MARK: Changes

    /// The player picked a rate or quality (or Auto), or what's on offer
    /// changed (the screen): whatever applies them does so at once. Low
    /// Power Mode posts `NSProcessInfoPowerStateDidChange` instead.
    public static let choicesDidChange = Notification.Name("DisplaySettings.choicesDidChange")
    /// What the view draws at changed (`running`).
    public static let runningDidChange = Notification.Name("DisplaySettings.runningDidChange")

    /// The keys a pick writes, for a game that syncs them.
    public static var pickKeys: [String] { [Key.frameRate, Key.renderScale] }

    /// Another device's picks arrived (`keys` changed): applied at once.
    public static func savedDataDidSync(_ keys: Set<String>) {
        guard !keys.isDisjoint(with: pickKeys) else { return }
        post(choicesDidChange)
    }

    /// Calls `changed` on the main actor whenever the choices may have
    /// changed: a pick, the screen, Low Power Mode. Returns the observers,
    /// to remove when done.
    @discardableResult
    public static func observeChoices(_ changed: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        [choicesDidChange, .NSProcessInfoPowerStateDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { changed() } }
            }
        }
    }

    private static func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private static var obsoleteKeysForgotten = false

    private static func forgetObsoleteKeys() {
        guard !obsoleteKeysForgotten else { return }
        obsoleteKeysForgotten = true
        for key in configuration.obsoleteKeys { configuration.defaults.removeObject(forKey: key) }
    }

    enum Key {
        static var frameRate: String { configuration.keyPrefix + "frameRate" }
        static var graphics: String { configuration.keyPrefix + "graphics" }
        static var renderScale: String { configuration.keyPrefix + "renderScale" }
        static func autoScale(_ rate: Int) -> String { configuration.keyPrefix + "graphicsAuto\(rate)" }
    }
}
