package com.fleon.switchlings;

import android.content.Intent;

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

    /**
     * What SDL hands {@code SDL_main} as argv, and therefore what Swift sees
     * in {@code CommandLine.arguments}.
     *
     * <p>The Apple build is driven in testing almost entirely by launch
     * arguments — {@code -StartLevel}, {@code -AutoSolve}, {@code -Markers}
     * and the rest of {@code LaunchArguments} — and Android has no
     * equivalent of {@code xcrun simctl launch}'s trailing arguments. An
     * intent extra is the nearest thing:
     *
     * <pre>
     * adb shell am start -n com.fleon.switchlings/.MainActivity \
     *     --esa args "-AudioProbe"
     * </pre>
     *
     * <p>Nothing is passed when the launcher starts the app, which is what
     * a release build always sees.
     */
    @Override
    protected String[] getArguments() {
        Intent intent = getIntent();
        if (intent == null) {
            return super.getArguments();
        }
        String[] arguments = intent.getStringArrayExtra("args");
        return arguments == null ? super.getArguments() : arguments;
    }
}
