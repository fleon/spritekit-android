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

#endif /* CANDROIDSHELL_H */
