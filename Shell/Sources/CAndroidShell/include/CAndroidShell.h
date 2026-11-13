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
void switchlings_log(int priority, const char *tag, const char *message);

/// SDL3 spells its window flags as 64-bit macros built from `SDL_UINT64_C`,
/// which the clang importer does not turn into Swift constants. Naming the
/// combinations here keeps magic numbers out of the Swift side.
static const SDL_InitFlags SWITCHLINGS_INIT_FLAGS =
    SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_GAMEPAD;

/// Fullscreen and resizable: Android decides the size, and it changes on
/// rotation and on a fold. `SDL_WINDOW_OPENGL` is what makes the window
/// carry a GL surface.
static const SDL_WindowFlags SWITCHLINGS_WINDOW_FLAGS =
    SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN | SDL_WINDOW_RESIZABLE;

/// `SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK` is a cast macro, which the clang
/// importer does not turn into a Swift constant either.
static const SDL_AudioDeviceID SWITCHLINGS_DEFAULT_PLAYBACK = SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK;

/// Signed 16-bit host-endian samples: what the AAC decoder hands back and
/// what the sound effects' WAVs already are, so nothing is converted twice.
static const SDL_AudioFormat SWITCHLINGS_AUDIO_FORMAT = SDL_AUDIO_S16;

/// Reads an Android system property into `out`, returning its length.
/// `__system_property_get` lives behind a header Swift's importer will not
/// take, and it is how a run is configured without a rebuild:
///
///     adb shell setprop debug.switchlings.scene sky
///
/// Debug-only plumbing: nothing in the game reads a property.
int switchlings_property(const char *name, char *out, int capacity);

/// Makes the serial executor whose reference is `identity` and
/// `implementation` (an `UnownedSerialExecutor`'s two words) the main
/// actor's, through the concurrency runtime's
/// `swift_task_getMainExecutor_hook` — whose functions take and return a
/// two-word struct in Swift's calling convention, which Swift itself cannot
/// spell as a `@convention(c)` function. Returns 0 if the runtime has no
/// such hook. See `MainActorJobs` in the shim.
int switchlings_set_main_executor(const void *identity, uintptr_t implementation);

/// Whether libdispatch's main queue belongs to the calling thread: it binds
/// the queue to whichever thread ran its constructor, so this says whether
/// `libAndroidShell.so` (and with it libdispatch) first loaded on SDL's
/// thread, as `MainActivity.loadLibraries` arranges.
bool switchlings_owns_main_queue(void);

/// Runs what `DispatchQueue.main` (and with it the main actor) has queued.
/// Only on the thread that owns the queue: libdispatch traps otherwise.
void switchlings_drain_main_queue(void);

/// Opens Android's share sheet with a file under the app's cache directory,
/// through `MainActivity.shareFile` (JNI, on SDL's activity). `text` may be
/// NULL. False if the call could not be made.
bool switchlings_share_file(const char *path, const char *mime, const char *text);

/// Google Play and the device, through `PlatformServices` on the Java side
/// (`MainActivity.platformCall` / `platformDrain`). Both directions carry
/// JSON as UTF-8 bytes.
///
/// `switchlings_platform_install` registers
/// `MainActivity.nativePlatformEventsReady`, which Java calls (on any thread)
/// when it queues events: it only sets a flag, which
/// `switchlings_platform_take_pending` reads and clears once a frame, so no
/// Swift ever runs on a Java thread.
bool switchlings_platform_install(void);
bool switchlings_platform_take_pending(void);

/// Calls `name` with `args` (`length` bytes of JSON). Returns the answer's
/// bytes in a buffer the caller frees with `free`, or NULL, with its length
/// in `*out_length`.
unsigned char *switchlings_platform_call(const char *name, const unsigned char *args, int length, int *out_length);

/// The events Java has queued, as a JSON array: freed by the caller, or NULL.
unsigned char *switchlings_platform_drain(int *out_length);

#endif /* CANDROIDSHELL_H */
