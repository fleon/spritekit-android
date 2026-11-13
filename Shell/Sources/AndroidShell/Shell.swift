import CAndroidShell
import Foundation
import SpriteKitShim

/// The Android app shell: SDL window, GLES 3 context, lifecycle, run loop.
///
/// The APK reaches this through SDL's `nativeRunMain`, which dlopens
/// `libAndroidShell.so` and calls the `SDL_main` exported in `Entry.swift`.
/// Everything above the context — scene graph, draw calls, assets, text — is
/// somebody else's module; see `FrameRenderer`.
public enum Shell {
    /// The renderer the shell draws with, read once after the context is
    /// current. Left nil, the shell uses `ClearScreenRenderer`, which is this
    /// track's proof that the context works.
    ///
    /// The renderer module links into this same shared library, so it can set
    /// this from its own entry point and call `run()`, or call
    /// `run(makeRenderer:)` directly. Both doors are open on purpose: which
    /// one the renderer wants is its call, not the shell's.
    public static var makeRenderer: ((RenderContext) -> FrameRenderer)?

    /// Run until Android tells us to stop. Returns the process exit status.
    @discardableResult
    public static func run(
        makeRenderer factory: ((RenderContext) -> FrameRenderer)? = nil
    ) -> Int32 {
        Log.info("Switchlings Android shell starting (SDL \(sdlVersion))")

        guard SDL_Init(SWITCHLINGS_INIT_FLAGS) else {
            Log.error("SDL_Init failed: \(sdlError)")
            return 1
        }
        defer { SDL_Quit() }

        // GLES 3.0. Chosen over Vulkan because the game's 31 shaders are
        // GLSL ES 1.0, which maps almost 1:1 onto ES 3.0.
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0)
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, Int32(SDL_GL_CONTEXT_PROFILE_ES))
        // The game draws no depth, and SKCropNode wants a stencil.
        SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 0)
        SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8)

        // Android picks the size; the 0 × 0 is ignored for a fullscreen window.
        guard let window = SDL_CreateWindow("Switchlings", 0, 0, SWITCHLINGS_WINDOW_FLAGS) else {
            Log.error("SDL_CreateWindow failed: \(sdlError)")
            return 1
        }
        defer { SDL_DestroyWindow(window) }

        guard let context = SDL_GL_CreateContext(window) else {
            Log.error("SDL_GL_CreateContext failed: \(sdlError)")
            return 1
        }
        defer { SDL_GL_DestroyContext(context) }

        guard SDL_GL_MakeCurrent(window, context) else {
            Log.error("SDL_GL_MakeCurrent failed: \(sdlError)")
            return 1
        }
        // Vsync. The game's own frame-rate setting is a later ring.
        SDL_GL_SetSwapInterval(1)

        var size = drawableSize(of: window)
        let info = RenderContext(
            vendor: glString(GLenum(GL_VENDOR)),
            renderer: glString(GLenum(GL_RENDERER)),
            version: glString(GLenum(GL_VERSION)),
            shadingLanguageVersion: glString(GLenum(GL_SHADING_LANGUAGE_VERSION)),
            size: size
        )
        Log.info("GL_VENDOR   \(info.vendor)")
        Log.info("GL_RENDERER \(info.renderer)")
        Log.info("GL_VERSION  \(info.version)")
        Log.info("GL_SHADING_LANGUAGE_VERSION \(info.shadingLanguageVersion)")
        Log.info("drawable \(Int(size.width)) x \(Int(size.height)) px")

        let renderer = (factory ?? makeRenderer ?? { ClearScreenRenderer(context: $0) })(info)
        renderer.rendererDidStart(info)
        renderer.drawableSizeDidChange(to: size)
        defer { renderer.rendererWillStop() }

        var running = true
        var foreground = true
        var index: UInt64 = 0
        var previous = ShellClock.now
        var lastReport = previous

        while running {
            var event = SDL_Event()
            while SDL_PollEvent(&event) {
                switch event.type {
                case SDL_EVENT_QUIT.rawValue, SDL_EVENT_TERMINATING.rawValue:
                    Log.info("shutting down on \(eventName(event.type))")
                    running = false
                case SDL_EVENT_WILL_ENTER_BACKGROUND.rawValue:
                    foreground = false
                case SDL_EVENT_DID_ENTER_FOREGROUND.rawValue:
                    foreground = true
                    previous = ShellClock.now
                case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED.rawValue:
                    let updated = drawableSize(of: window)
                    if updated != size {
                        size = updated
                        Log.info("drawable \(Int(size.width)) x \(Int(size.height)) px")
                        renderer.drawableSizeDidChange(to: size)
                    }
                default:
                    break
                }
            }

            // Backgrounded: Android has taken the surface away, so there is
            // nothing to draw into. Idle rather than spin.
            if !foreground {
                SDL_Delay(100)
                continue
            }

            let now = ShellClock.now
            let frame = Frame(
                time: now,
                delta: index == 0 ? 0 : now - previous,
                size: size,
                index: index
            )
            previous = now

            renderer.drawFrame(frame)
            SDL_GL_SwapWindow(window)
            index += 1

            // Proof the loop is live, not one frame stuck on screen.
            if now - lastReport >= 5 {
                Log.info("\(index) frames, \(String(format: "%.1f", Double(index) / now)) fps average")
                lastReport = now
            }
        }

        Log.info("shell stopped after \(index) frames")
        return 0
    }

    // MARK: - Odds and ends

    static var sdlError: String { String(cString: SDL_GetError()) }

    static var sdlVersion: String {
        "\(SDL_MAJOR_VERSION).\(SDL_MINOR_VERSION).\(SDL_MICRO_VERSION)"
    }

    static func drawableSize(of window: OpaquePointer) -> CGSize {
        var w: Int32 = 0, h: Int32 = 0
        SDL_GetWindowSizeInPixels(window, &w, &h)
        return CGSize(width: CGFloat(w), height: CGFloat(h))
    }

    /// `glGetString` hands back unsigned bytes; Swift wants signed ones.
    static func glString(_ name: GLenum) -> String {
        guard let bytes = glGetString(name) else { return "(null)" }
        return String(cString: UnsafeRawPointer(bytes).assumingMemoryBound(to: CChar.self))
    }

    static func eventName(_ type: UInt32) -> String {
        switch type {
        case SDL_EVENT_QUIT.rawValue: return "SDL_EVENT_QUIT"
        case SDL_EVENT_TERMINATING.rawValue: return "SDL_EVENT_TERMINATING"
        default: return "event \(type)"
        }
    }
}

/// The shell's clock: monotonic seconds since SDL started.
///
/// This is what stands in for `CACurrentMediaTime()` on Android. The game
/// reads that clock in `MediaClock`, in every shader's `u_time`, and in the
/// board's action timings, so there needs to be exactly one of it.
public enum ShellClock {
    public static var now: TimeInterval { TimeInterval(SDL_GetTicksNS()) / 1_000_000_000 }
}
