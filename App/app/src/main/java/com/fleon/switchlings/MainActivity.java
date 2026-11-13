package com.fleon.switchlings;

import org.libsdl.app.SDLActivity;

/**
 * The APK's only activity.
 *
 * <p>SDL owns the Android side of the port — the activity lifecycle, the GL
 * surface, touch, keyboard, gamepads and audio — so this project writes no
 * JNI of its own. Everything above the GL context is Swift, in
 * libAndroidShell.so.
 */
public class MainActivity extends SDLActivity {

    /**
     * Loaded in order. SDL treats the last entry as the "main shared object":
     * it dlopens libAndroidShell.so and calls the {@code SDL_main} that
     * Entry.swift exports with {@code @_cdecl}.
     *
     * <p>The Swift runtime libraries alongside it are not listed here — the
     * dynamic linker pulls them in from the APK's own library directory by
     * following DT_NEEDED.
     */
    @Override
    protected String[] getLibraries() {
        return new String[] { "SDL3", "AndroidShell" };
    }
}
