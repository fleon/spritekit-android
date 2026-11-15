import CAndroidShell
import Foundation
import ShellCore

/// Starts each frame on the display's vsync and times it there.
///
/// Without it the loop ran as fast as `eglSwapBuffers` let it, timed by the
/// wall clock: frames that finished early queued up behind the swap, and
/// each step the scene moved was however long the last pass happened to
/// take, so motion stuttered whenever a frame ran late. Here AChoreographer
/// hands over each vsync's timestamp, a frame never starts on the same
/// vsync as the last, and its time is the latest vsync at or before it: so
/// every step is a whole number of the display's refreshes.
///
/// `-FixedFrameStep` never comes here: its frames keep stepping their own
/// clock as before.
struct VsyncPacer {
    /// The longest a frame waits for a vsync before going ahead anyway (the
    /// screen off, a choreographer that stopped answering).
    static let waitLimit: Int32 = 50

    /// SDL's clock (`ShellClock`) less CLOCK_MONOTONIC, the choreographer's:
    /// SDL counts from its start, on the same clock.
    private let offset: TimeInterval
    /// One refresh, from the display's rate, then from the vsyncs themselves.
    private(set) var period: TimeInterval
    /// The last frame's time.
    private var last: TimeInterval?
    private var lastVsync: Int64 = 0

    /// Nil where Android gives no choreographer: the loop then runs on the
    /// swap, as it did.
    init?(refreshRate: Int) {
        guard switchlings_vsync_start() else { return nil }
        let monotonic = switchlings_monotonic_ns()
        offset = ShellClock.now - TimeInterval(monotonic) / 1_000_000_000
        period = 1 / Double(max(refreshRate, 1))
    }

    mutating func refreshRateDidChange(to rate: Int) {
        period = 1 / Double(max(rate, 1))
    }

    /// After the app comes back: the next frame starts afresh.
    mutating func reset() { last = nil }

    /// The next frame's time, waiting for a vsync if the last frame's hasn't
    /// passed yet.
    mutating func nextFrame() -> TimeInterval {
        var time = grid(switchlings_vsync_poll(0))
        if let last, time < last + period / 2 {
            time = grid(switchlings_vsync_poll(Self.waitLimit))
            if time < last + period / 2 { time = last + period }
        }
        last = time
        return time
    }

    /// The latest vsync at or before now, on the grid the choreographer's
    /// latest timestamp sets: a callback the frame thread was too busy to
    /// run on time still says where the refreshes fall.
    private mutating func grid(_ vsync: Int64) -> TimeInterval {
        let now = ShellClock.now
        guard vsync > 0 else { return now }
        if lastVsync > 0, vsync > lastVsync {
            // Learn the true period from back-to-back vsyncs.
            let gap = TimeInterval(vsync - lastVsync) / 1_000_000_000
            if abs(gap - period) < period / 4 { period += (gap - period) / 8 }
        }
        lastVsync = vsync
        let base = TimeInterval(vsync) / 1_000_000_000 + offset
        let passed = max(0, ((now - base) / period + 0.02).rounded(.down))
        return base + passed * period
    }
}

/// Sizes the window's buffers to the renderer's scale, so the display's
/// compositor stretches the frame onto the screen and the renderer draws
/// straight into them, with no target of its own and no blit.
///
/// Android drops the size whenever SDL makes the surface again (back from
/// the background) and a turn of the device changes the drawable's, so the
/// size is set again whenever the window or what's wanted changes.
struct SurfaceScaler {
    private var window: UnsafeMutableRawPointer?
    private var surface: UnsafeMutableRawPointer?
    private var applied: CGSize?
    private var frameRate: Int?
    /// Set once Android refuses a size: the renderer keeps its own target.
    private(set) var unsupported = false

    mutating func apply(scale: CGFloat, drawable: CGSize, frameRate rate: Int, window sdlWindow: OpaquePointer) {
        guard !unsupported else { return }
        let native = switchlings_native_window(sdlWindow)
        guard let native else { return }
        let egl = switchlings_egl_surface(sdlWindow)
        if native != window || egl != surface {
            window = native
            surface = egl
            applied = nil
            frameRate = nil
        }
        let wanted = SurfaceGeometry.pixels(of: drawable, scale: scale)
        let pixels = wanted == drawable ? CGSize.zero : wanted
        if pixels != applied {
            let started = ShellClock.now
            if switchlings_native_window_set_buffers(native, Int32(pixels.width), Int32(pixels.height)) == 0 {
                applied = pixels
                let took = (ShellClock.now - started) * 1000
                Log.info(pixels == .zero
                    ? "window buffers \(Int(drawable.width))x\(Int(drawable.height)), the screen's own (\(String(format: "%.2f", took)) ms)"
                    : "window buffers \(Int(pixels.width))x\(Int(pixels.height)), stretched to \(Int(drawable.width))x\(Int(drawable.height)) by the display (\(String(format: "%.2f", took)) ms)")
            } else {
                unsupported = true
                Log.error("the window's buffers can't be sized: the renderer stretches the frame itself")
            }
        }
        if rate > 0, rate != frameRate {
            frameRate = rate
            _ = switchlings_native_window_set_frame_rate(native, Float(rate))
        }
    }

    /// Back from the background: whatever Android kept, size it again.
    mutating func reset() {
        applied = nil
        frameRate = nil
    }

    /// The buffer being drawn into now, as EGL has it.
    static func current(or drawable: CGSize) -> CGSize {
        var width: Int32 = 0, height: Int32 = 0
        guard switchlings_surface_size(&width, &height) else { return drawable }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}
