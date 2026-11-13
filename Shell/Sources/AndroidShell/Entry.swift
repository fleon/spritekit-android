import CAndroidShell
import Foundation
import GLESBackend
import ShellCore
import SpriteKitShim

/// The APK's way in.
///
/// SDL's `SDLActivity.nativeRunMain` dlopens the last library named by
/// `MainActivity.getLibraries()` — `libAndroidShell.so` — and looks up
/// `SDL_main` in it. `@_cdecl` is what gives this function that symbol name
/// and C linkage, so no JNI of our own is needed anywhere in the port: SDL's
/// Java and JNI already own the activity, the GL surface, input and audio.
///
/// Signature fixed by SDL's `SDL_main_func`:
///
///     typedef int (SDLCALL *SDL_main_func)(int argc, char *argv[]);
@_cdecl("SDL_main")
public func SDL_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    // SDL runs this on a thread of its own, not the process's first one,
    // and the game asserts it is on the main thread before it primes a
    // shader. This is where that becomes true; it has to be the first thing
    // the process does in Swift, before anything reads Thread.mainThread.
    if !MainThread.claim() {
        Log.error("could not claim the main thread — anything that primes a shader will trap")
    }

    // `Task { @MainActor in … }` runs on this thread too, between frames.
    let executor = MainActorJobs.executorReference
    if switchlings_set_main_executor(executor.identity, UInt(executor.implementation)) == 0 || !MainActorJobs.isInstalled {
        Log.error("could not take over the main executor — main-actor work will never run")
    }
    // Proof it took: this runs at the top of the frame loop's first pass.
    Task { @MainActor in
        Log.info("main actor: jobs run on the frame thread (\(Thread.isMainThread ? "main" : "not main"))")
    }

    // What SDL was handed by MainActivity.getArguments(). The process's own
    // argv is the zygote's, so this is the only place they exist.
    ShellArguments.install(argc: argc, argv: argv)
    FilmSetup.useCacheForTemporaryFiles()
    FilmSetup.install()

    // Hands the shell a real renderer. If the art is missing from the APK
    // the index does not load and every texture resolves to the white
    // placeholder — tinted rectangles, visibly wrong rather than blank.
    GLESBackend.prepare()
    return Shell.run(makeRenderer: GLESBackend.makeRenderer)
}
