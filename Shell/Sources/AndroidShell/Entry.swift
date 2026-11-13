import CAndroidShell
import GLESBackend

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
    // Hands the shell a real renderer. If the art is missing from the APK
    // the index does not load and every texture resolves to the white
    // placeholder — tinted rectangles, visibly wrong rather than blank.
    GLESBackend.prepare()
    return Shell.run(makeRenderer: GLESBackend.makeRenderer)
}
