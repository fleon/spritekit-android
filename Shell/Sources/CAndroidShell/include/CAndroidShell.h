#ifndef CANDROIDSHELL_H
#define CANDROIDSHELL_H

// The only C in the Android shell: the handful of things Swift cannot reach
// through the clang importer on its own.
//
// Including SDL and GLES here (rather than in a system-library module map)
// keeps the include path a build-time flag — `-Xcc -I<sdl prefix>/include` —
// so the same package builds for every ABI without a generated module map
// per ABI.

#include <SDL3/SDL.h>
#include <GLES3/gl3.h>
#include <android/log.h>

/// `__android_log_print` is variadic, which Swift cannot call. This is the
/// one way into logcat; `Log` in Swift is the only caller.
void ska_log(int priority, const char *tag, const char *message);

/// SDL3 spells its window flags as 64-bit macros built from `SDL_UINT64_C`,
/// which the clang importer does not turn into Swift constants. Naming the
/// combinations here keeps magic numbers out of the Swift side.
static const SDL_InitFlags SKA_INIT_FLAGS =
    SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_GAMEPAD;

/// Fullscreen and resizable: Android decides the size, and it changes on
/// rotation and on a fold. `SDL_WINDOW_OPENGL` is what makes the window
/// carry a GL surface.
static const SDL_WindowFlags SKA_WINDOW_FLAGS =
    SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN | SDL_WINDOW_RESIZABLE;

/// `SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK` is a cast macro, which the clang
/// importer does not turn into a Swift constant either.
static const SDL_AudioDeviceID SKA_DEFAULT_PLAYBACK = SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK;

/// Signed 16-bit host-endian samples: what the AAC decoder hands back and
/// what the sound effects' WAVs already are, so nothing is converted twice.
static const SDL_AudioFormat SKA_AUDIO_FORMAT = SDL_AUDIO_S16;

/// Reads an Android system property into `out`, returning its length.
/// `__system_property_get` lives behind a header Swift's importer will not
/// take, and it is how a run is configured without a rebuild:
///
///     adb shell setprop debug.<app>.slowdown 4
///
/// Debug-only plumbing: nothing in the game reads a property.
int ska_property(const char *name, char *out, int capacity);

/// Makes the serial executor whose reference is `identity` and
/// `implementation` (an `UnownedSerialExecutor`'s two words) the main
/// actor's, through the concurrency runtime's
/// `swift_task_getMainExecutor_hook` — whose functions take and return a
/// two-word struct in Swift's calling convention, which Swift itself cannot
/// spell as a `@convention(c)` function. Returns 0 if the runtime has no
/// such hook. See `MainActorJobs` in the shim.
int ska_set_main_executor(const void *identity, uintptr_t implementation);

/// Whether libdispatch's main queue belongs to the calling thread: it binds
/// the queue to whichever thread ran its constructor, so this says whether
/// `libAndroidShell.so` (and with it libdispatch) first loaded on SDL's
/// thread, as `SpriteKitActivity.loadLibraries` arranges.
bool ska_owns_main_queue(void);

/// Runs what `DispatchQueue.main` (and with it the main actor) has queued.
/// Only on the thread that owns the queue: libdispatch traps otherwise.
void ska_drain_main_queue(void);

/// Opens Android's share sheet with a file under the app's cache directory,
/// through `SpriteKitActivity.shareFile` (JNI, on SDL's activity). `text`
/// may be NULL. False if the call could not be made.
bool ska_share_file(const char *path, const char *mime, const char *text);

/// Google Play and the device, through `PlatformServices` on the Java side
/// (`SpriteKitActivity.platformCall` / `platformDrain`). Both directions
/// carry JSON as UTF-8 bytes.
///
/// `ska_platform_install` registers
/// `SpriteKitActivity.nativePlatformEventsReady`, which Java calls (on any
/// thread) when it queues events: it only sets a flag, which
/// `ska_platform_take_pending` reads and clears once a frame, so no
/// Swift ever runs on a Java thread.
bool ska_platform_install(void);
bool ska_platform_take_pending(void);

/// Calls `name` with `args` (`length` bytes of JSON). Returns the answer's
/// bytes in a buffer the caller frees with `free`, or NULL, with its length
/// in `*out_length`.
unsigned char *ska_platform_call(const char *name, const unsigned char *args, int length, int *out_length);

/// The events Java has queued, as a JSON array: freed by the caller, or NULL.
unsigned char *ska_platform_drain(int *out_length);
/// Registers `SpriteKitActivity`'s native methods (`nativeOpenLink`,
/// `nativePaste`, `nativeKeyboard`) on SDL's activity, then tells it they're
/// there (`nativesRegistered`), so it hands over a link it held meanwhile.
/// SDL dlopens this library itself, so JNI would never find them by name.
bool ska_register_natives(void);

/// A link Android handed the running activity, or NULL. The caller frees it.
char *ska_take_link(void);

/// Text the player picked Paste for, or NULL. The caller frees it.
char *ska_take_paste(void);

/// The soft keyboard's height and the view's, in pixels, if either changed
/// since the last call.
bool ska_take_keyboard(int *height, int *viewHeight);

/// Offers Android's Paste at a point in the view, in pixels
/// (`SpriteKitActivity.offerPaste`).
bool ska_offer_paste(float x, float y);

/// Sends what the process prints to standard output and standard error into
/// logcat under `tag`, a line an entry: an Android app's stdout goes nowhere,
/// and a game's `print`ed lines are how tools can time captures.
/// Line buffered, so `print` reaches logcat as each line ends.
bool ska_redirect_stdio(const char *tag);

/// A GL context sharing the current one's objects, current on another
/// thread: what `GLBuilderThread` builds programs in. Made on the thread
/// whose context it shares (the frame thread), with that context current;
/// returns NULL if EGL can't give one.
void *ska_gl_share_create(void);
/// Makes it current on the calling thread; 1 on success.
int ska_gl_share_make_current(void *share);
/// Lets go of it on the calling thread, before it's destroyed.
void ska_gl_share_release(void *share);
void ska_gl_share_destroy(void *share);

/// The display's vsync, through AChoreographer on this thread's looper
/// (prepared here). False where Android has no choreographer to give.
bool ska_vsync_start(void);
/// Runs the vsync callbacks that are due and, given a timeout, waits up to
/// that long for the next one. Returns the latest vsync's timestamp
/// (CLOCK_MONOTONIC nanoseconds, SDL's clock on Android), 0 before any.
int64_t ska_vsync_poll(int timeout_ms);
/// CLOCK_MONOTONIC, in nanoseconds.
int64_t ska_monotonic_ns(void);

/// The window's `ANativeWindow`, or NULL while Android has taken it away.
void *ska_native_window(SDL_Window *window);
/// The window's EGL surface, which SDL makes again (sizing the buffers to the
/// window as it does) when Android hands the window back.
void *ska_egl_surface(SDL_Window *window);
/// Sizes its buffers (0 × 0: the window's own size), which the compositor
/// then stretches onto the window: the hardware scaler. 0 on success.
int ska_native_window_set_buffers(void *window, int width, int height);
/// Tells Android the rate the game draws at (API 30 and later). 0 on success.
int ska_native_window_set_frame_rate(void *window, float rate);
/// The current draw surface's size in pixels, as EGL has it now.
bool ska_surface_size(int *width, int *height);

#endif /* CANDROIDSHELL_H */
