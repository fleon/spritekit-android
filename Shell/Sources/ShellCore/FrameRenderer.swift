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
}

public extension FrameRenderer {
    func rendererDidStart(_ context: RenderContext) {}
    func drawableSizeDidChange(to size: CGSize) {}
    func rendererWillStop() {}
    func receive(_ touch: TouchEvent) {}
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
    /// Seconds since the previous frame. Zero on the first frame.
    public var delta: TimeInterval
    /// The drawable size in physical pixels, the same value last passed to
    /// `drawableSizeDidChange(to:)`.
    public var size: CGSize
    /// Frames drawn since the shell started, counting from zero.
    public var index: UInt64

    public init(time: TimeInterval, delta: TimeInterval, size: CGSize, index: UInt64) {
        self.time = time
        self.delta = delta
        self.size = size
        self.index = index
    }
}
