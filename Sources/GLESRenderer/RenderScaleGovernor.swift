import Foundation

/// Picks the share of the screen's pixels each frame draws (its render
/// scale) for Auto, once for a device, from how frames kept time.
///
/// A phone's GPU can be too slow to fill every pixel of its screen a frame:
/// a Mali-G72 MP3 phone (1080 × 2340) drew a scene of full-screen shaders
/// at 19 fps at full size, 39 at 0.67 and 60 at 0.5, almost exactly in step with the
/// pixels drawn. So the renderer can draw each frame at a scale and stretch
/// it onto the screen.
///
/// Auto never lowers its frame rate (60, or the fastest a screen paces
/// evenly below it: `autoRates`) and moves the scale between Highest and
/// Medium alone (`autoSteps`), and only once: it measures at the largest
/// scale for at least `shortestMeasure` seconds of play, then chooses the
/// largest scale whose share of those pixels would have brought the heavier
/// windows (`heavyShare`) within their budget, as soon as that choice is the
/// same from the first half of what it measured as from all of it, or else
/// at `longestMeasure`. Callers keep the choice for the device, so it never
/// changes again (`decided`). A graphics setting a game lets the player pick
/// takes the choice away; a picked rate has a choice of its own.
///
/// It judges by the wall clock, every `window` frames, from their mean (how
/// many frames a second it kept up: frames paced on whole refreshes mix
/// on-time and doubled ones as the GPU runs past its budget). GPU timer
/// queries can't be trusted for it: a Mali-G72's driver answers a frame that
/// draws into more than one target with nonsense.
///
/// Plain Swift with no GL in it, so a game can use the same governor on
/// Apple for its own view; on Android the renderer runs it (`SceneRenderer`).
nonisolated public struct RenderScaleGovernor: Equatable {
    /// A frame rate and render scale to draw at.
    public struct Rung: Equatable, CustomStringConvertible {
        public var rate: Int
        public var scale: Double

        public init(rate: Int, scale: Double) {
            self.rate = rate
            self.scale = scale
        }

        public var description: String { "\(rate) fps at \(String(format: "%.2f", scale))" }
    }

    /// Five render-scale tiers, Highest to Lowest, evenly spaced in
    /// sharpness, for a game's graphics setting.
    public static let steps: [Double] = [1, 0.875, 0.75, 0.625, 0.5]
    /// The tiers Auto chooses between: Highest to Medium.
    public static let autoSteps: [Double] = Array(steps.prefix(3))
    /// The fastest Auto draws, and the slowest rate it counts as a screen's
    /// even pace.
    public static let fastestAutoRate = 60
    public static let slowestAutoRate = 25
    /// Frames a window looks at.
    public static let window = 30
    /// Windows after a scene starts that judge nothing: its first frames
    /// build and prime what it shows.
    public static let warmUpWindows = 1
    /// Seconds of frames measured before it may choose, and by when it does.
    public static let shortestMeasure = 60.0
    public static let longestMeasure = 180.0
    /// The share of windows, lightest first, the choice must hold in: the
    /// heaviest moments past it may still run a little late.
    static let heavyShare = 0.8
    /// A window's mean frame within this share of its budget is on time.
    static let lateFrame = 1.1
    /// A frame counts at most this many budgets: a stall (a scene building)
    /// says nothing of the pixels.
    static let longestFrame = 4.0

    /// The rates a screen refreshing `refresh` times a second paces evenly
    /// (every frame shown for the same number of refreshes), fastest first,
    /// from the fastest at or below `ceiling` down to half that, never below
    /// `slowestAutoRate`. Auto draws at the first: 60 on a 60 or 120 Hz
    /// screen, 50 on a 50 Hz television. Faster screens that 60 doesn't
    /// divide (90 Hz, 144 Hz: Android's) also offer 60, as Android switches
    /// the display's mode for them. In Low Power Mode, which holds a
    /// ProMotion display to 60 Hz, the screen counts as 60 Hz
    /// (`pacedRefresh`).
    public static func autoRates(refresh: Int, ceiling: Int = fastestAutoRate, lowPower: Bool = false) -> [Int] {
        let refresh = max(pacedRefresh(refresh, lowPower: lowPower), 1)
        var rates = Set((1...refresh).filter { refresh % $0 == 0 }.map { refresh / $0 })
        if refresh > fastestAutoRate, refresh % ceiling != 0 {
            rates.formUnion([ceiling, ceiling / 2])
        }
        let top = rates.filter { $0 <= ceiling }.max() ?? ceiling
        let floor = max(top / 2, min(slowestAutoRate, top))
        return rates.filter { $0 <= top && $0 >= floor }.sorted(by: >)
    }

    /// The refresh rate frames are paced against on a screen whose fastest
    /// is `refresh`: at most 60 in Low Power Mode, which holds a faster
    /// display there.
    public static func pacedRefresh(_ refresh: Int, lowPower: Bool) -> Int {
        lowPower ? min(refresh, lowPowerRefresh) : refresh
    }

    static let lowPowerRefresh = 60

    public let rate: Int
    /// The scales it chooses between, largest first (one: nothing to choose).
    public let scales: [Double]
    public private(set) var scale: Double
    /// Whether the scale is chosen, now or before: it never moves again.
    public private(set) var isDecided: Bool
    /// Seconds of frames measured towards the choice.
    public private(set) var measured = 0.0
    public var rung: Rung { Rung(rate: rate, scale: scale) }

    private var frameTimes: [Double] = []
    /// Each window measured: its mean frame over its budget, at `scales[0]`.
    private var demands: [Double] = []
    private var warmUp = warmUpWindows

    /// Draws at `rate`: at `decided` if this device chose it before (rounded
    /// down to one of `scales`), else measuring at the largest of `scales`.
    public init(rate: Int = fastestAutoRate, scales: [Double] = autoSteps, decided: Double? = nil) {
        self.rate = rate
        let scales = scales.isEmpty ? [1] : scales.sorted(by: >)
        self.scales = scales
        if let decided {
            scale = scales.first { $0 <= decided + 1e-9 } ?? scales[scales.count - 1]
            isDecided = true
        } else {
            scale = scales[0]
            isDecided = scales.count == 1
        }
    }

    /// Forgets a window under way.
    public mutating func restartWindow() {
        frameTimes.removeAll(keepingCapacity: true)
    }

    /// A scene starts: its first frames say nothing of the scene before.
    public mutating func startScene() {
        restartWindow()
        warmUp = Self.warmUpWindows
    }

    /// One frame: the wall clock since the last one (seconds), against its
    /// budget (as many of the screen's refreshes as the rate asks for).
    /// Returns whether it chose the scale just now (`scale`, perhaps the one
    /// it measured at), which the caller keeps for the device and draws
    /// from the next scene on.
    @discardableResult
    public mutating func add(frame: Double, budget: Double) -> Bool {
        guard !isDecided else { return false }
        frameTimes.append(min(frame, budget * Self.longestFrame))
        guard frameTimes.count >= Self.window else { return false }
        let total = frameTimes.reduce(0, +)
        restartWindow()
        guard warmUp == 0 else { warmUp -= 1; return false }
        demands.append(total / Double(Self.window) / budget)
        measured += total
        guard measured >= Self.shortestMeasure - 1e-9 else { return false }
        let choice = Self.choose(scales, demands: demands[...])
        guard measured >= Self.longestMeasure - 1e-9 || choice == Self.choose(scales, demands: demands.prefix(demands.count / 2)) else { return false }
        scale = choice
        isDecided = true
        demands = []
        return true
    }

    /// The largest of `scales` whose share of the first one's pixels would
    /// have brought the heavier of `demands` (measured at it) within their
    /// budget, else the smallest: the GPU's work falls with the pixels, as
    /// on a Mali-G72.
    static func choose(_ scales: [Double], demands: ArraySlice<Double>) -> Double {
        guard !demands.isEmpty else { return scales[0] }
        let sorted = demands.sorted()
        let heavy = sorted[min(Int(Double(sorted.count) * heavyShare), sorted.count - 1)]
        let top = scales[0] * scales[0]
        return scales.first { $0 * $0 / top * heavy <= lateFrame } ?? scales[scales.count - 1]
    }
}
