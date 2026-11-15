import Foundation
import SpriteKitShim

// ---------------------------------------------------------------------------
// The seam between the app shell and the GLES 3 renderer.
//
// The shell owns the window, the GL context, the drawable size, the clock and
// the Android lifecycle. The renderer owns every draw call. These four types
// are the whole of what passes between them, and they are deliberately small:
// nothing here mentions sprites, textures, shaders or DrawList, because the
// renderer decides all of that.
//
// A renderer is handed a current context on the thread that will call
// `drawFrame`, and may assume it stays current for its whole life.
// ---------------------------------------------------------------------------

/// What the shell draws with. The renderer session implements this; until it
/// does, the shell uses `ClearScreenRenderer`.
///
/// Every method is called on the shell's frame thread with the GLES 3 context
/// current. The shell swaps buffers after `drawFrame` returns, so a renderer
/// never calls `eglSwapBuffers` or `SDL_GL_SwapWindow` itself.
public protocol FrameRenderer: AnyObject {
    /// Called once, before the first frame, with the context already current.
    /// Compile programs and upload static resources here rather than in
    /// `init`, which may run before there is a context.
    func rendererDidStart(_ context: RenderContext)

    /// The drawable changed size: first layout, a rotation, or a fold.
    /// Always called at least once before the first `drawFrame`.
    ///
    /// `size` is in physical pixels, which is what `glViewport` wants. The
    /// scene's own size in design points is the game's business, not the
    /// shell's.
    func drawableSizeDidChange(to size: CGSize)

    /// Whether to draw `frame` at all. Asked before each one; no means the
    /// shell neither draws nor swaps, so what is on screen stays there, and
    /// the next frame drawn carries the time since the last one drawn as its
    /// `delta`. This is `SKView`'s `preferredFramesPerSecond`, `isPaused` and
    /// its delegate's `view(_:shouldRenderAtTime:)`.
    func shouldDraw(_ frame: Frame) -> Bool

    /// With `-FixedFrameStep`, whether the game is waiting on work off the
    /// main thread: the shell then draws nothing and holds the clock still,
    /// asking again before each frame.
    var holdsClock: Bool { get }

    /// Draw one frame. The viewport has not been set — a renderer that cares
    /// sets it from `frame.size`.
    func drawFrame(_ frame: Frame)

    /// The activity is going away. Delete GL objects here; the context is
    /// still current, and is destroyed as soon as this returns.
    func rendererWillStop()

    /// A finger went down, moved, came up or was taken away. Called on the
    /// frame thread between frames, never during one.
    ///
    /// The shell reads these from SDL and passes them straight on: where a
    /// touch lands in a scene depends on the projection, and the projection
    /// is the renderer's, so undoing it is the renderer's job too.
    func receive(_ touch: TouchEvent)

    /// Everything else the player does: the back button, a key, typing, a
    /// gamepad, a link. Returns whether the game took it; the shell does
    /// Android's own thing with what it does not (back leaves the app).
    func receive(_ input: InputEvent) -> Bool

    /// The window's safe area, way up or refresh rate changed (or are known
    /// for the first time). Always called before the first frame.
    func windowMetricsDidChange(_ metrics: WindowMetrics)

    /// The activity came back to the front, or went away.
    func applicationStateDidChange(active: Bool)

    /// The share of the drawable the window's buffers should be, each side:
    /// below 1 the shell sizes them `SurfaceGeometry.pixels(of:scale:)` and
    /// the display's compositor stretches them onto the screen, and each
    /// frame's `surfaceSize` says what the buffer drawn into really is.
    var surfaceScale: CGFloat { get }

    /// The frames a second the game wants (its frame-rate setting), told to
    /// Android so a screen that can switch rates runs at it; 0 for no say.
    var preferredFrameRate: Int { get }
}

public extension FrameRenderer {
    func rendererDidStart(_ context: RenderContext) {}
    func drawableSizeDidChange(to size: CGSize) {}
    func shouldDraw(_ frame: Frame) -> Bool { true }
    var holdsClock: Bool { false }
    func rendererWillStop() {}
    func receive(_ touch: TouchEvent) {}
    func receive(_ input: InputEvent) -> Bool { false }
    func windowMetricsDidChange(_ metrics: WindowMetrics) {}
    func applicationStateDidChange(active: Bool) {}
    var surfaceScale: CGFloat { 1 }
    var preferredFrameRate: Int { 0 }
}

/// How a scaled surface is sized, in one place for the shell (which sizes
/// the window's buffers) and the renderer (which falls back to a target of
/// the same size while they aren't yet).
public enum SurfaceGeometry {
    /// `size` scaled, in whole pixels; `size` itself at 1 or more.
    public static func pixels(of size: CGSize, scale: CGFloat) -> CGSize {
        let scale = min(max(scale, 0.25), 1)
        guard scale < 1 else { return size }
        return CGSize(
            width: CGFloat(max(1, Int((size.width * scale).rounded()))),
            height: CGFloat(max(1, Int((size.height * scale).rounded())))
        )
    }
}

/// Input other than touches, as the shell reads it from SDL.
public enum InputEvent: Sendable {
    /// Android's back button or back gesture.
    case back
    /// A hardware key, by its USB HID usage (SDL's scancodes are that table),
    /// with UIKit's modifier bits.
    case key(usage: Int, modifiers: Int)
    /// Text the keyboard typed while a text field takes typing.
    case text(String)
    /// A gamepad, in GameController's terms.
    case gamepad(GamepadEvent)
    /// The game was opened with a link (`switchlings://…`).
    case link(URL)
}

/// What the window knows about where it can draw.
public struct WindowMetrics: Equatable, Sendable {
    /// What system bars and cutouts cover at each edge, in pixels.
    public var safeArea: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat)
    /// Which way up: SDL's `SDL_DisplayOrientation` raw value.
    public var orientation: Int
    /// The display's refresh rate in frames a second, rounded.
    public var refreshRate: Int
    /// Android's display density: pixels per density-independent pixel (160 dpi = 1), for telling a tablet by its smallest width.
    public var displayScale: CGFloat

    public init(safeArea: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat), orientation: Int, refreshRate: Int, displayScale: CGFloat) {
        self.safeArea = safeArea
        self.orientation = orientation
        self.refreshRate = refreshRate
        self.displayScale = displayScale
    }

    public static func == (a: WindowMetrics, b: WindowMetrics) -> Bool {
        a.safeArea == b.safeArea && a.orientation == b.orientation
            && a.refreshRate == b.refreshRate && a.displayScale == b.displayScale
    }
}

/// One finger, one moment.
public struct TouchEvent: Sendable {
    public enum Phase: Sendable {
        case began, moved, ended, cancelled
    }

    public var phase: Phase
    /// Where the finger is in the window, each axis from 0 to 1 with the
    /// origin at the **top left** — SDL's own normalised coordinates, which
    /// are the one thing about a touch that does not change with the
    /// drawable size, the density or the rotation.
    public var location: CGPoint
    /// Which finger, for the length of one gesture.
    public var finger: Int
    /// `ShellClock.now` when it happened.
    public var time: TimeInterval

    public init(phase: Phase, location: CGPoint, finger: Int, time: TimeInterval) {
        self.phase = phase
        self.location = location
        self.finger = finger
        self.time = time
    }
}

/// What the driver reports about itself, read once at startup and logged.
/// Worth keeping: the renderer will want `shadingLanguageVersion` when it
/// decides which `#version` line to put on the game's GLSL.
public struct RenderContext: Sendable {
    public var vendor: String
    public var renderer: String
    public var version: String
    public var shadingLanguageVersion: String
    /// The drawable size in physical pixels at the moment the context became
    /// current.
    public var size: CGSize
    /// The display's pixels per density-independent pixel
    /// (`SDL_GetWindowDisplayScale`): what a point is on Android.
    public var displayScale: CGFloat = 0

    public init(
        vendor: String,
        renderer: String,
        version: String,
        shadingLanguageVersion: String,
        size: CGSize
    ) {
        self.vendor = vendor
        self.renderer = renderer
        self.version = version
        self.shadingLanguageVersion = shadingLanguageVersion
        self.size = size
    }
}

/// One frame's worth of state.
public struct Frame: Sendable {
    /// Monotonic seconds since the shell started — Android's stand-in for
    /// `CACurrentMediaTime()`, and the clock the shim's actions and the
    /// game's shader `u_time` run on. See `ShellClock`.
    public var time: TimeInterval
    /// Seconds since the previous frame. Zero on the first frame. Paced to
    /// the display, a whole number of its refreshes.
    public var delta: TimeInterval
    /// The drawable size in physical pixels, the same value last passed to
    /// `drawableSizeDidChange(to:)`.
    public var size: CGSize
    /// Frames drawn since the shell started, counting from zero.
    public var index: UInt64
    /// The buffer this frame draws into, in pixels: `size`, or less where the
    /// display's compositor stretches it onto the screen (`surfaceScale`).
    public var surfaceSize: CGSize
    /// The wall clock between this frame's start and the last one's, which
    /// `delta` (the step the scene moves, on the display's vsync) may round.
    public var interval: TimeInterval

    public init(time: TimeInterval, delta: TimeInterval, size: CGSize, index: UInt64, surfaceSize: CGSize? = nil, interval: TimeInterval? = nil) {
        self.time = time
        self.delta = delta
        self.size = size
        self.index = index
        self.surfaceSize = surfaceSize ?? size
        self.interval = interval ?? delta
    }
}
