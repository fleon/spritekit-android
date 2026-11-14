import Foundation

/// Picks the share of the screen's pixels the scene draws at, from how
/// recent frames kept time.
///
/// A phone's GPU can be too slow to fill every pixel of its screen a frame:
/// a Galaxy M31 (Mali-G72 MP3, 1080 × 2340) drew Sunny Garden at 19 fps at
/// full size, 39 at 0.67 and 60 at 0.5, almost exactly in step with the
/// pixels drawn. So the renderer draws at a scale this picks and stretches
/// the frame onto the screen, and a phone that keeps up stays at 1.
///
/// It judges by the wall clock, every `window` frames, from the median
/// frame. GPU timer queries can't be trusted for it: the M31's driver
/// answers a frame that draws into more than one target with nonsense.
///
///  - **Late** (longer than `lateFrame` refreshes): a step down, unless
///    the CPU took most of the frame (`cpuBound`), when fewer pixels
///    wouldn't help.
///  - **On time**: after `patience` windows, a try at a step up. If that
///    runs late it steps back, and the next try waits twice as long (up to
///    `longestWait`), so a scene just over the line isn't tried every few
///    seconds.
public struct RenderScaleGovernor: Equatable {
    /// The scales it moves between, largest first.
    public static let steps: [Double] = [1, 0.85, 0.75, 0.67, 0.58, 0.5]
    /// Frames a decision looks at.
    public static let window = 30
    /// Windows on time before the first try at a step up.
    public static let patience = 8
    static let longestWait = 64
    /// A frame longer than this many refreshes is late.
    static let lateFrame = 1.1
    /// The share of a late frame the CPU took past which it's the CPU, not
    /// the pixels, that held it up.
    static let cpuBound = 0.75

    public private(set) var index = 0
    public var scale: Double { Self.steps[index] }

    private var frameTimes: [Double] = []
    private var cpuTimes: [Double] = []
    /// Windows on time in a row, how many a try at a step up waits for, and
    /// whether the last step was such a try.
    private var onTimeWindows = 0
    private var wait = patience
    private var trying = false

    public init(scale: Double = 1) {
        index = Self.steps.firstIndex { $0 <= scale + 1e-9 } ?? Self.steps.count - 1
    }

    /// One frame: the wall clock since the last one and the CPU time the
    /// renderer spent on it (seconds), against a budget of one refresh.
    /// Returns whether the scale changed.
    @discardableResult
    public mutating func add(frame: Double, cpu: Double, budget: Double) -> Bool {
        frameTimes.append(frame)
        cpuTimes.append(cpu)
        guard frameTimes.count >= Self.window else { return false }
        let frame = Self.median(frameTimes), cpu = Self.median(cpuTimes)
        frameTimes.removeAll(keepingCapacity: true)
        cpuTimes.removeAll(keepingCapacity: true)
        let before = index
        if frame > budget * Self.lateFrame {
            onTimeWindows = 0
            if trying {
                // A try that failed: back down, whatever held it up.
                trying = false
                wait = min(wait * 2, Self.longestWait)
                index = min(index + 1, Self.steps.count - 1)
            } else if cpu < frame * Self.cpuBound {
                index = min(index + 1, Self.steps.count - 1)
            }
        } else {
            if trying { trying = false; wait = Self.patience }
            onTimeWindows += 1
            if index > 0, onTimeWindows >= wait {
                index -= 1
                onTimeWindows = 0
                trying = true
            }
        }
        return index != before
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
