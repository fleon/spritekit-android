import CAndroidShell
import Foundation
import PlatformShim
import SDLAudio
import SpriteKitShim
import ShellCore

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

    /// The audio backend, opened once SDL is up and installed here for the
    /// game's `AudioManager` to stand on. Nil when Android gives no audio
    /// device, which the game must survive: it runs silent, not broken.
    public private(set) static var audio: AudioBackend = NullAudioBackend()

    /// Run until Android tells us to stop. Returns the process exit status.
    @discardableResult
    public static func run(
        makeRenderer factory: ((RenderContext) -> FrameRenderer)? = nil
    ) -> Int32 {
        Log.info("Switchlings Android shell starting (SDL \(sdlVersion))")
        // `DispatchQueue.main` and the main actor run on this thread, drained
        // once a frame below — but only if libdispatch bound its main queue
        // here, which it does to whichever thread loaded it first. That is
        // this one because `MainActivity.loadLibraries` leaves
        // libAndroidShell.so to SDL's own dlopen. Without it every
        // `DispatchQueue.main.async` in the game waits for ever.
        let ownsMainQueue = switchlings_owns_main_queue()
        if ownsMainQueue {
            DispatchQueue.main.async { Log.info("the main queue runs on the game's thread") }
        } else {
            Log.error("libdispatch's main queue belongs to another thread — DispatchQueue.main and the main actor will never run")
        }
        // One clock. The shim answers `CACurrentMediaTime()` out of this, so
        // the action system, `u_time` and the frame loop cannot drift apart.
        MediaTime.source = { ShellClock.now }

        // The back button comes to the game, which decides whether it goes
        // back or leaves (`SDL_SendAndroidBackButton` when it leaves).
        SDL_SetHint(SDL_HINT_ANDROID_TRAP_BACK_BUTTON, "1")

        guard SDL_Init(SWITCHLINGS_INIT_FLAGS) else {
            Log.error("SDL_Init failed: \(sdlError)")
            return 1
        }
        defer { SDL_Quit() }

        // Audio before the window: opening the device is the slow part and
        // nothing on screen waits for it. A device that will not open leaves
        // the null backend in place.
        let soundtrack = SDLAudioBackend()
        if let soundtrack { audio = soundtrack }
        defer { audio = NullAudioBackend() }
        let probe = AudioProbe(audio: audio)

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
        var info = RenderContext(
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
        info.displayScale = CGFloat(SDL_GetWindowDisplayScale(window))
        Log.info("display scale \(info.displayScale) px a point")

        SystemBridge.install(window: window)
        // Links while running, the soft keyboard and Paste come from
        // `MainActivity` outside SDL's events (`SystemInbox`).
        if !switchlings_register_natives() { Log.error("could not register MainActivity's native methods: no links while running, keyboard frame or Paste") }
        let renderer = (factory ?? makeRenderer ?? { ClearScreenRenderer(context: $0) })(info)
        renderer.rendererDidStart(info)
        renderer.drawableSizeDidChange(to: size)
        var metrics = windowMetrics(of: window)
        renderer.windowMetricsDidChange(metrics)
        defer { renderer.rendererWillStop() }
        let gamepads = GamepadBridge()

        var running = true
        var foreground = true
        var index: UInt64 = 0
        var previous = ShellClock.now
        var lastReport = previous

        while running {
            // What the game queued for the main thread since the last
            // frame: a film's progress and its finish, a sync's catch-up.
            if ownsMainQueue { switchlings_drain_main_queue() }
            // Play's and the device's news: a purchase, a sign-in, a saved game.
            PlatformBridge.deliverPendingEvents()

            var event = SDL_Event()
            while SDL_PollEvent(&event) {
                switch event.type {
                case SDL_EVENT_QUIT.rawValue, SDL_EVENT_TERMINATING.rawValue:
                    GameEnvironment.save()
                    Log.info("shutting down on \(eventName(event.type))")
                    running = false
                case SDL_EVENT_WILL_ENTER_BACKGROUND.rawValue:
                    foreground = false
                    // The soundtrack stops with the game, as it does on
                    // Apple: nothing plays over the launcher.
                    audio.suspend()
                    // A share film waits meanwhile, as nothing draws for it.
                    UIApplication.shared.resignActive()
                    // Android may end a backgrounded app without a word:
                    // what the game saved goes to disk now.
                    GameEnvironment.save()
                    renderer.applicationStateDidChange(active: false)
                case SDL_EVENT_DID_ENTER_FOREGROUND.rawValue:
                    foreground = true
                    previous = ShellClock.now
                    audio.resume()
                    UIApplication.shared.becomeActive()
                    renderer.applicationStateDidChange(active: true)
                case SDL_EVENT_KEY_DOWN.rawValue:
                    let key = event.key
                    if key.scancode == SDL_SCANCODE_AC_BACK {
                        // Nothing took it on the title: Android's own back,
                        // which leaves the game.
                        if !renderer.receive(.back) { SDL_SendAndroidBackButton() }
                    } else if !key.repeat {
                        _ = renderer.receive(.key(usage: Int(key.scancode.rawValue), modifiers: modifierFlags(key.mod)))
                    }
                case SDL_EVENT_TEXT_INPUT.rawValue:
                    if let text = event.text.text { _ = renderer.receive(.text(String(cString: text))) }
                case SDL_EVENT_GAMEPAD_ADDED.rawValue,
                     SDL_EVENT_GAMEPAD_REMOVED.rawValue,
                     SDL_EVENT_GAMEPAD_BUTTON_DOWN.rawValue,
                     SDL_EVENT_GAMEPAD_BUTTON_UP.rawValue,
                     SDL_EVENT_GAMEPAD_AXIS_MOTION.rawValue:
                    for input in gamepads.translate(event) { _ = renderer.receive(.gamepad(input)) }
                case SDL_EVENT_WINDOW_SAFE_AREA_CHANGED.rawValue,
                     SDL_EVENT_DISPLAY_ORIENTATION.rawValue,
                     SDL_EVENT_WINDOW_DISPLAY_CHANGED.rawValue:
                    let updated = windowMetrics(of: window)
                    if updated != metrics {
                        metrics = updated
                        renderer.windowMetricsDidChange(metrics)
                    }
                case SDL_EVENT_FINGER_DOWN.rawValue,
                     SDL_EVENT_FINGER_MOTION.rawValue,
                     SDL_EVENT_FINGER_UP.rawValue,
                     SDL_EVENT_FINGER_CANCELED.rawValue:
                    renderer.receive(touchEvent(event.tfinger))
                case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED.rawValue:
                    let updated = drawableSize(of: window)
                    if updated != size {
                        size = updated
                        Log.info("drawable \(Int(size.width)) x \(Int(size.height)) px")
                        renderer.drawableSizeDidChange(to: size)
                        metrics = windowMetrics(of: window)
                        renderer.windowMetricsDidChange(metrics)
                    }
                default:
                    break
                }
            }

            MainActor.assumeIsolated { SystemInbox.drain(into: renderer, window: window) }

            // Backgrounded: Android has taken the surface away, so there is
            // nothing to draw into. Idle rather than spin.
            if !foreground {
                SDL_Delay(100)
                continue
            }

            // What was sent to the main actor since the last pass, as the
            // main run loop would run it between frames (`MainActorJobs`).
            MainActorJobs.drain()

            let now = ShellClock.now
            let frame = Frame(
                time: now,
                delta: index == 0 ? 0 : now - previous,
                size: size,
                index: index
            )
            // A frame skipped is not drawn or swapped, so nothing waits on
            // the display: wait a little here instead of spinning.
            guard renderer.shouldDraw(frame) else {
                SDL_Delay(Self.skippedFrameWait)
                continue
            }
            previous = now

            probe?.tick(at: now)
            renderer.drawFrame(frame)
            SDL_GL_SwapWindow(window)
            index += 1

            // Proof the loop is live, not one frame stuck on screen. Saved
            // data goes to disk on the same beat, as Apple's user defaults
            // write themselves out a moment after each change.
            if now - lastReport >= 5 {
                GameEnvironment.save()
                Log.info("\(index) frames, \(String(format: "%.1f", Double(index) / now)) fps average")
                lastReport = now
            }
        }

        Log.info("shell stopped after \(index) frames")
        return 0
    }

    // MARK: - Odds and ends

    /// How long a pass that skips its frame waits before asking again, in
    /// milliseconds: a fraction of the shortest frame, so the next frame due
    /// is never late by more than that.
    static let skippedFrameWait: UInt32 = 2

    static var sdlError: String { String(cString: SDL_GetError()) }

    /// The safe area, which way up, the refresh rate and the density.
    static func windowMetrics(of window: OpaquePointer) -> WindowMetrics {
        var safe = SDL_Rect()
        var w: Int32 = 0, h: Int32 = 0
        SDL_GetWindowSize(window, &w, &h)
        let scale = CGFloat(SDL_GetWindowPixelDensity(window))
        _ = SDL_GetWindowSafeArea(window, &safe)
        let display = SDL_GetDisplayForWindow(window)
        let refresh = SDL_GetCurrentDisplayMode(display).map { Int($0.pointee.refresh_rate.rounded()) } ?? 60
        // The safe area is in window coordinates; the drawable is in pixels.
        return WindowMetrics(
            safeArea: (
                top: CGFloat(safe.y) * scale,
                left: CGFloat(safe.x) * scale,
                bottom: CGFloat(h - safe.y - safe.h) * scale,
                right: CGFloat(w - safe.x - safe.w) * scale
            ),
            orientation: Int(SDL_GetCurrentDisplayOrientation(display).rawValue),
            refreshRate: max(refresh, 1),
            displayScale: CGFloat(SDL_GetWindowDisplayScale(window))
        )
    }

    /// SDL's modifier bits as UIKit's `UIKeyModifierFlags` raw values.
    static func modifierFlags(_ mod: SDL_Keymod) -> Int {
        var flags = 0
        if mod & SDL_Keymod(SDL_KMOD_CAPS) != 0 { flags |= 1 << 16 }
        if mod & SDL_Keymod(SDL_KMOD_SHIFT) != 0 { flags |= 1 << 17 }
        if mod & SDL_Keymod(SDL_KMOD_CTRL) != 0 { flags |= 1 << 18 }
        if mod & SDL_Keymod(SDL_KMOD_ALT) != 0 { flags |= 1 << 19 }
        if mod & SDL_Keymod(SDL_KMOD_GUI) != 0 { flags |= 1 << 20 }
        return flags
    }

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

    /// SDL's finger event as the renderer's seam wants it. SDL already
    /// gives x and y normalised from the window's top left, which is what
    /// `TouchEvent` carries, so nothing here needs the drawable size.
    static func touchEvent(_ finger: SDL_TouchFingerEvent) -> TouchEvent {
        let phase: TouchEvent.Phase
        switch finger.type {
        case SDL_EVENT_FINGER_DOWN: phase = .began
        case SDL_EVENT_FINGER_MOTION: phase = .moved
        case SDL_EVENT_FINGER_UP: phase = .ended
        default: phase = .cancelled
        }
        return TouchEvent(
            phase: phase,
            location: CGPoint(x: CGFloat(finger.x), y: CGFloat(finger.y)),
            finger: Int(bitPattern: UInt(finger.fingerID)),
            time: TimeInterval(finger.timestamp) / 1_000_000_000
        )
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
