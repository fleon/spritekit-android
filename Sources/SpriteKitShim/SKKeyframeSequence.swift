#if SPRITEKIT_SHIM
import Foundation

public enum SKInterpolationMode: Int, Sendable {
    case linear = 1, spline = 2, step = 3
}

public enum SKRepeatMode: Int, Sendable {
    case clamp = 1, loop = 2
}

/// Values over time, as an emitter's sequences take them: times run 0 to 1
/// across a particle's life. The game builds every one from numbers
/// (`[0, alpha, alpha, 0]`), which arrive as `Any` and may be `Int`,
/// `Double`, `CGFloat` or `NSNumber` in one array; colours are sampled too.
public final class SKKeyframeSequence {
    private var values: [Any]
    private var times: [CGFloat]

    public var interpolationMode: SKInterpolationMode = .linear
    public var repeatMode: SKRepeatMode = .clamp

    public init(keyframeValues values: [Any], times: [NSNumber]) {
        precondition(values.count == times.count, "one time for each keyframe value")
        let pairs = zip(values, times.map { CGFloat($0.doubleValue) })
            .enumerated()
            .sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 < $1.element.1 }
        self.values = pairs.map(\.element.0)
        self.times = pairs.map(\.element.1)
    }

    public init(capacity numItems: Int) {
        values = []
        times = []
        values.reserveCapacity(numItems)
        times.reserveCapacity(numItems)
    }

    public func count() -> Int { values.count }

    public func addKeyframeValue(_ value: Any, time: CGFloat) {
        let index = times.firstIndex { $0 > time } ?? times.count
        values.insert(value, at: index)
        times.insert(time, at: index)
    }

    public func removeLastKeyframe() {
        guard !values.isEmpty else { return }
        values.removeLast()
        times.removeLast()
    }

    public func removeKeyframe(at index: Int) {
        values.remove(at: index)
        times.remove(at: index)
    }

    public func getKeyframeValue(for index: Int) -> Any { values[index] }
    public func getKeyframeTime(for index: Int) -> CGFloat { times[index] }

    public func setKeyframeValue(_ value: Any, for index: Int) { values[index] = value }
    public func setKeyframeTime(_ time: CGFloat, for index: Int) {
        let value = values.remove(at: index)
        times.remove(at: index)
        addKeyframeValue(value, time: time)
    }

    /// The value at `time`: a number (as `CGFloat`) or a colour, interpolated
    /// as the sequence says; nil for an empty sequence. Anything else comes
    /// back as the keyframe at or before `time`.
    public func sample(atTime time: CGFloat) -> Any? {
        guard let (i, j, t) = bracket(at: time) else { return nil }
        if let number = sampleNumber(at: time) { return number }
        if let colour = sampleColour(i, j, t) { return colour }
        return values[i]
    }

    // MARK: - For the emitter

    /// `sample(atTime:)` as a number, without boxing it.
    func sampleNumber(at time: CGFloat) -> CGFloat? {
        guard let (i, j, t) = bracket(at: time) else { return nil }
        return curve(i, j, t, SKKeyframeSequence.number)
    }

    private func sampleColour(_ i: Int, _ j: Int, _ t: CGFloat) -> SKColor? {
        guard values[i] is SKColor else { return nil }
        if i == j || interpolationMode == .step { return values[i] as? SKColor }
        func channel(_ read: @escaping (SKColor) -> CGFloat) -> CGFloat? {
            curve(i, j, t) { ($0 as? SKColor).map(read) }
        }
        guard let red = channel(\.red), let green = channel(\.green),
              let blue = channel(\.blue), let alpha = channel(\.alpha) else { return values[i] as? SKColor }
        return SKColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The keyframes either side of `time` and how far between them it lies.
    ///
    /// Clamped, a time before the first keyframe takes the first's value and
    /// one after the last the last's. Looped, time wraps over the span from
    /// the first keyframe's time to the last's.
    private func bracket(at time: CGFloat) -> (Int, Int, CGFloat)? {
        guard let first = times.first, let last = times.last else { return nil }
        var time = time
        if repeatMode == .loop, last > first {
            let span = last - first
            time = first + (time - first).truncatingRemainder(dividingBy: span)
            if time < first { time += span }
        }
        if time <= first { return (0, 0, 0) }
        if time >= last { return (times.count - 1, times.count - 1, 0) }
        // Times are sorted, so the first one past `time` closes the bracket.
        let j = times.firstIndex { $0 > time } ?? times.count - 1
        let i = j - 1
        let span = times[j] - times[i]
        return (i, j, span > 0 ? (time - times[i]) / span : 0)
    }

    /// One channel between keyframes `i` and `j`, `t` of the way: held
    /// (`step`), straight (`linear`) or on a Catmull-Rom curve through the
    /// keyframes either side (`spline`, the ends repeated), which passes
    /// through every keyframe with no corner at any of them.
    private func curve(_ i: Int, _ j: Int, _ t: CGFloat, _ read: (Any) -> CGFloat?) -> CGFloat? {
        guard let a = read(values[i]) else { return nil }
        if i == j || interpolationMode == .step { return a }
        guard let b = read(values[j]) else { return a }
        guard interpolationMode == .spline else { return a + (b - a) * t }
        let p0 = read(values[max(0, i - 1)]) ?? a
        let p3 = read(values[min(values.count - 1, j + 1)]) ?? b
        let t2 = t * t, t3 = t2 * t
        return 0.5 * (2 * a + (b - p0) * t + (2 * p0 - 5 * a + 4 * b - p3) * t2 + (3 * a - p0 - 3 * b + p3) * t3)
    }

    private static func number(_ value: Any) -> CGFloat? {
        switch value {
        case let value as CGFloat: return value
        case let value as Double: return CGFloat(value)
        case let value as Float: return CGFloat(value)
        case let value as Int: return CGFloat(value)
        case let value as NSNumber: return CGFloat(value.doubleValue)
        default: return nil
        }
    }
}

#endif
