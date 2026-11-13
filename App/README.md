# The Android app shell

What turns the port into something you can install: a Gradle project, SDL3
cross-compiled for two ABIs, and a Swift shared library that opens a GLES 3.0
context and runs a frame loop.

It draws nothing but a cleared screen. That is the whole visual bar for this
part — the renderer that turns a `DrawList` into draw calls meets it at
`FrameRenderer`, below.

```
Android/
  App/        this: the Gradle project, and the staged .so files
  Shell/      the Swift side — AndroidShell, built as libAndroidShell.so
  Scripts/    cross-compiling SDL and the shell
  Vendor/     fetched and built, never committed
```

## What the pieces are

**SDL3 `release-3.4.20`**, pinned in `Scripts/config.sh` and fetched by
`Scripts/build-sdl.sh`. No binaries are checked in. SDL owns the window, the
Android activity lifecycle, the GL surface, touch, keyboard, gamepads and
audio — the gamepad part matters, because the game already supports
controllers through `GameController` on Apple platforms.

**No JNI of our own, and no `swift-java`.** SDL ships the Java and the JNI for
all of the above, and its `SDLActivity.nativeRunMain` dlopens the last library
named by `MainActivity.getLibraries()` and calls the `SDL_main` it finds
there. `Entry.swift` exports that symbol with `@_cdecl`, which is the entire
bridge. `swift-java` would have added a dependency, a Gradle plugin and a
generation step to produce a seam SDL already provides; if a later ring needs
to call Java that SDL does not wrap, that is the moment to reach for it.

**minSdk 24, compiled against API 23.** The native code links against API 23
stubs (`ANDROID_API` in `Scripts/config.sh`), which is the level the merged
shim work proved; the app itself declares `minSdk 24`. A binary may require
less than the app declares, and the two numbers are deliberately separate so
the app's floor can move without re-proving the toolchain.

## Building

Needs: the open-source Swift 6.4.2 toolchain via swiftly (**not** Xcode's,
which cannot cross-compile), the `swift-6.4.2-RELEASE_android` SDK, NDK r30,
JDK 17, cmake and ninja.

```bash
export ANDROID_NDK_HOME=$HOME/Library/Android/android-ndk-r30
Android/Scripts/build-sdl.sh          # fetch + cross-compile SDL, both ABIs
Android/Scripts/build-shell.sh        # cross-compile the Swift shell
cd Android/App && ./gradlew assembleDebug
```

The first script takes a few minutes; the second is seconds after that.
Either accepts an ABI to do just one (`build-shell.sh arm64-v8a`), and
`build-shell.sh --debug` builds the Swift side unoptimised.

`build-shell.sh` stages `libAndroidShell.so` into
`app/src/main/jniLibs/<abi>/` along with every library it needs, found by
walking `DT_NEEDED` — the Swift runtime, SDL and `libc++_shared`, but not the
libraries Android itself provides. Everything is stripped with the NDK's
`llvm-strip`. Gradle fails early with a readable message if the `.so` files
are not there, because an APK missing them installs and launches fine and
then dies in the linker with nothing useful in logcat.

The APK lands at `Android/App/app/build/outputs/apk/debug/app-debug.apk`.

## Installing and running

```bash
adb install -r Android/App/app/build/outputs/apk/debug/app-debug.apk
```

```bash
adb shell am start -n com.fleon.switchlings/.MainActivity
```

```bash
adb logcat -s Switchlings
```

Everything the shell logs goes under the `Switchlings` tag. SDL logs under
`SDL`, which is worth adding (`-s Switchlings:V SDL:V`) when something fails
before the first frame.

A good run looks like this:

```
Switchlings Android shell starting (SDL 3.4.20)
GL_VENDOR   Google (Google Inc. (Google))
GL_RENDERER Android Emulator OpenGL ES Translator (ANGLE ... SwiftShader ...)
GL_VERSION  OpenGL ES 3.1 (OpenGL ES 3.1.0 (ANGLE 2.1.1 ...))
GL_SHADING_LANGUAGE_VERSION OpenGL ES GLSL ES 3.10
drawable 1080 x 2400 px
clearing to rgba(0.85, 0.11, 0.55, 1.0)
264 frames, 51.0 fps average
```

and the screen is solid magenta.

## Which ABI, which emulator

| ABI | runs on |
|---|---|
| `arm64-v8a` | every Android phone worth shipping to, **and** an arm64-v8a system image on an Apple Silicon Mac, where it runs natively with no translation |
| `x86_64` | x86_64 system images, i.e. an emulator on an Intel Mac or a Linux CI box |

On an Apple Silicon Mac, pick the **arm64-v8a** image (`google_apis` or
`google_apis_playstore`). It is the same ABI as a real phone, so it is the
one that matters, and it is the fast one here. An x86_64 image on Apple
Silicon would be emulating a foreign architecture on top of an emulator; the
`x86_64` slice exists for Intel hosts and CI, not for this Mac.

What the emulator will *not* tell you is whether the game is fast enough. Its
GL goes through ANGLE onto SwiftShader — a software rasteriser — or onto the
host GPU. Neither resembles the Mali-G57 / Adreno 610 class hardware this
port is aimed at. Use it to find out whether something works, never whether
it holds 60 fps.

## The seam with the renderer

`Shell/Sources/AndroidShell/FrameRenderer.swift` is the whole contract, and
it is meant to stay small. The shell owns the window, the context, the
drawable size, the clock and the lifecycle; the renderer owns every draw
call.

```swift
public protocol FrameRenderer: AnyObject {
    func rendererDidStart(_ context: RenderContext)
    func drawableSizeDidChange(to size: CGSize)
    func drawFrame(_ frame: Frame)
    func rendererWillStop()
}
```

Every method runs on the frame thread with the context current. The shell
swaps buffers after `drawFrame` returns, so a renderer never swaps itself.
`Frame` carries the monotonic time, the delta, the drawable size in physical
pixels and the frame index. `RenderContext` carries the four driver strings,
of which `shadingLanguageVersion` is the one that decides which `#version`
line the game's GLSL gets rewritten with.

Install a renderer by setting `Shell.makeRenderer`, or by calling
`Shell.run(makeRenderer:)` from an entry point of your own. Left alone, the
shell uses `ClearScreenRenderer`, which is the magenta above and nothing
else: no sprites, no textures, no shaders, deliberately.

`ShellClock.now` is the one monotonic clock — Android's stand-in for
`CACurrentMediaTime()`, which the game reads in `MediaClock`, in every
shader's `u_time` and in the board's action timings.

## Known gaps

- **The APK is 138 MB**, and 80 MB of that is two copies of
  `lib_FoundationICU.so`. It comes in through Foundation, which the shim
  needs for `CGFloat` and friends. Splitting the APK per ABI halves it
  immediately; getting off full Foundation onto `FoundationEssentials` is the
  real fix and is a question for the shim, not for the shell.
- **The `x86_64` slice is built and packaged but has not been run** — the
  only system image installed here is arm64-v8a.
- **No app icon.** The launcher shows Android's default. The real one comes
  from `Tools/Art/Sources/icon-master.psd` when there is a pipeline for it.
- **Audio and gamepads are initialised but unused.** `SDL_INIT_AUDIO` and
  `SDL_INIT_GAMEPAD` are passed so the subsystems exist; nothing reads them
  yet.
