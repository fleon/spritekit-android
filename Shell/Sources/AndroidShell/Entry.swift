import CAndroidShell
import Foundation
import GLESBackend
import PlatformShim
import ShellCore
import SpriteKitShim

extension Shell {
    /// The APK's way in, for a game to call from its `SDL_main`.
    ///
    /// SDL's `SDLActivity.nativeRunMain` dlopens the last library named by
    /// `MainActivity.getLibraries()` (`libAndroidShell.so`) and looks up
    /// `SDL_main` in it. The game's own entry target exports that symbol
    /// with `@_cdecl`, which is the entire bridge (no JNI of our own: SDL's
    /// Java and JNI already own the activity, the GL surface, input and
    /// audio), and hands over its controller's type, so the shell never
    /// imports a game:
    ///
    ///     @_cdecl("SDL_main")
    ///     nonisolated public func SDL_main(
    ///         _ argc: Int32,
    ///         _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ///     ) -> Int32 {
    ///         Shell.start(argc: argc, argv: argv,
    ///                     app: AppIdentity(name: "My Game", bundleIdentifier: "com.example.mygame", key: "mygame"),
    ///                     fonts: ["MyFont-Regular", "MyFont-Bold"],
    ///                     game: MyGameController.self)
    ///     }
    ///
    /// The signature is fixed by SDL's `SDL_main_func`. `fonts` names the
    /// font files staged in the APK's `fonts/`, without their `.ttf`, the
    /// first being what a label with no `fontName` falls back to (it's
    /// required, since a game with none draws no text). `launchDefaults` are
    /// arguments added on an emulator or outside a beta build where the
    /// launch doesn't name them. `resourceFolder` says where the game's Gradle
    /// project stages each resource in the APK. `configure` runs
    /// once the art and the clock are in place, before the game launches:
    /// for the game's own debug properties, say.
    nonisolated public static func start(
        argc: Int32,
        argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        app: AppIdentity,
        fonts: [String],
        launchDefaults: LaunchDefaults = .none,
        resourceFolder: @escaping ResourceBundle.FolderRule = ResourceBundle.defaultFolder,
        game: any GameHost.Type,
        configure: (@MainActor () -> Void)? = nil
    ) -> Int32 {
        // Who the app is, before anything logs or reads a property.
        AppIdentity.current = app

        // SDL runs this on a thread of its own, not the process's first one,
        // and the game asserts it is on the main thread before it primes a
        // shader. This is where that becomes true; it has to be the first thing
        // the process does in Swift, before anything reads Thread.mainThread.
        if !MainThread.claim() {
            Log.error("could not claim the main thread — anything that primes a shader will trap")
        }

        // What the game prints (lines tools wait for, above all) goes to logcat,
        // under the shell's own tag: an app's standard output goes nowhere.
        _ = ska_redirect_stdio(app.name)

        // `Task { @MainActor in … }` runs on this thread too, between frames.
        let executor = MainActorJobs.executorReference
        if ska_set_main_executor(executor.identity, UInt(executor.implementation)) == 0 || !MainActorJobs.isInstalled {
            Log.error("could not take over the main executor — main-actor work will never run")
        }
        // From here on this thread is the main actor's: everything the game,
        // the renderer and the frame loop do runs on it.
        return MainActor.assumeIsolated {
            // Proof it took: this runs at the top of the frame loop's first pass.
            Task { @MainActor in
                Log.info("main actor: jobs run on the frame thread (\(Thread.isMainThread ? "main" : "not main"))")
            }

            // What SDL was handed by MainActivity.getArguments(). The process's own
            // argv is the zygote's, so this is the only place they exist.
            ShellArguments.install(argc: argc, argv: argv)
            GameEnvironment.install(defaults: launchDefaults)
            // Play Billing, Play Games and the device, before the game's
            // managers start and pick their backends.
            PlatformBridge.install()
            FilmSetup.useCacheForTemporaryFiles()
            FilmSetup.install()

            // Hands the shell a real renderer. If the art is missing from the APK
            // the index does not load and every texture resolves to the white
            // placeholder — tinted rectangles, visibly wrong rather than blank.
            AssetBundle.fontFiles = fonts
            GLESBackend.resourceFolder = resourceFolder
            GLESBackend.game = game
            GLESBackend.configureGame = configure
            GLESBackend.prepare()
            Shell.audioDidOpen = { GLESBackend.useAudio($0) }
            return Shell.run(makeRenderer: GLESBackend.makeRenderer)
        }
    }
}
