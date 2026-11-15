import CAndroidShell
import Foundation
import GLESRenderer
import ShellCore
import SpriteKitShim

/// What a frame cost, reported to logcat every few seconds.
///
/// The question this whole stage exists to answer is whether eight
/// procedural backdrops with live lighting hold 60 fps on a mid-range
/// Android GPU. **The emulator cannot answer it** — it renders through the
/// host Mac's GPU, so its numbers flatter a phone by a wide and unknowable
/// margin. What the emulator *can* give honestly is the shape of the cost:
/// how many draw calls a frame takes, how many times the render target is
/// switched (the expensive thing on a tiler, which the emulator does not
/// model at all), how much of the sky's shader the band cache is actually
/// saving, and whether the CPU side — flattening, batching, the digest —
/// shows up at all.
///
/// So this reports both: the wall-clock frame time, flagged as emulator
/// numbers, and the counts, which carry across to real hardware.
struct FrameReport {
    /// Frames between reports. At 60 fps this is every five seconds.
    static let interval = 300
    /// Frames skipped at the start, while the art uploads, the shaders
    /// compile and the backdrop bakes — all one-off costs that would
    /// otherwise land in the first report's tail.
    static let warmUp = 60

    private var times: [Double] = []
    private var frames = 0
    private var label = ""

    /// GPU work is queued, so the time `drawFrame` takes is the port's own
    /// work plus whatever the driver blocks on — and on an emulator the
    /// second part is mostly the pipe to the host's GL, which tells you
    /// nothing about a phone. `scene` separates out the part that does
    /// carry: ticking the actions, flattening the graph and batching it.
    private var cpuTimes: [Double] = []
    /// Ticking, flattening and batching alone — no GL. The one number here
    /// that carries to a phone unchanged.
    private var sceneTimes: [Double] = []
    private var scales: [Double] = []
    /// The frame thread's CPU time from one frame to the next: its work,
    /// whatever it waited on (the GPU, the swap) left out.
    private var threadTimes: [Double] = []
    private var lastThreadTime: Double?

    mutating func begin(_ label: String) {
        self.label = label
    }

    /// One frame. `delta` is the wall clock between frames (so it carries
    /// the GPU and the swap), `cpu` the time inside `drawFrame`.
    mutating func add(delta: Double, cpu: Double, scene: Double, renderScale: Double, renderer: SceneRenderer) {
        frames += 1
        let thread = Self.threadTime()
        defer { lastThreadTime = thread }
        guard frames > Self.warmUp else { return }
        if let last = lastThreadTime { threadTimes.append(thread - last) }
        times.append(delta)
        cpuTimes.append(cpu)
        sceneTimes.append(scene)
        scales.append(renderScale)
        guard times.count >= Self.interval else { return }
        report(renderer)
        times.removeAll(keepingCapacity: true)
        cpuTimes.removeAll(keepingCapacity: true)
        sceneTimes.removeAll(keepingCapacity: true)
        scales.removeAll(keepingCapacity: true)
        threadTimes.removeAll(keepingCapacity: true)
    }

    /// The calling thread's CPU time, in seconds.
    private static func threadTime() -> Double {
        var now = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now)
        return Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000
    }

    private func report(_ renderer: SceneRenderer) {
        let frame = Self.summary(times)
        let cpu = Self.summary(cpuTimes)
        let scene = Self.summary(sceneTimes)
        Log.info(String(
            format: "[frames] %@ n=%d  frame p50 %.2f ms p95 %.2f ms max %.2f ms (%.1f fps)  draw p50 %.2f ms p95 %.2f ms  scene p50 %.2f ms",
            label, times.count,
            frame.median * 1000, frame.p95 * 1000, frame.max * 1000,
            frame.median > 0 ? 1 / frame.median : 0,
            cpu.median * 1000, cpu.p95 * 1000, scene.median * 1000
        ))
        let thread = Self.summary(threadTimes)
        Log.info(String(
            format: "[frames] %@ thread cpu p50 %.2f ms p95 %.2f ms",
            label, thread.median * 1000, thread.p95 * 1000
        ))
        Log.info(String(
            format: "[frames] %@ render scale p50 %.2f min %.2f max %.2f",
            label, Self.summary(scales).median, scales.min() ?? 0, scales.max() ?? 0
        ))
        Log.info(String(
            format: "[frames] %@ draw calls %d  target binds %d  quads %d  effects drawn %d cached %d  buffer maps %d",
            label, renderer.drawCalls, renderer.targetBinds, renderer.quadsDrawn,
            renderer.effectsDrawn, renderer.effectsCached, renderer.streamMaps
        ))
        Log.info(String(
            format: "[frames] %@ nodes %d  texture memory %.1f MB",
            label, renderer.visibleNodeCount, Double(renderer.liveTextureBytes) / 1_048_576
        ))
        let textures = renderer.textureBytes
        Log.info(String(
            format: "[frames] %@ cache textures %d  %.1f MB on the GPU (%.1f MB as RGBA8)",
            label, renderer.textureCount, Double(textures.gpu) / 1_048_576, Double(textures.rgba) / 1_048_576
        ))
    }

    private static func summary(_ values: [Double]) -> (median: Double, p95: Double, max: Double) {
        guard !values.isEmpty else { return (0, 0, 0) }
        let sorted = values.sorted()
        func at(_ share: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * share)))]
        }
        return (at(0.5), at(0.95), sorted[sorted.count - 1])
    }
}

/// Reads an Android system property, so a measuring run can be set up with
/// `adb shell setprop` and no rebuild.
nonisolated enum DebugProperty {
    static func string(_ name: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        let length = switchlings_property(name, &buffer, Int32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
