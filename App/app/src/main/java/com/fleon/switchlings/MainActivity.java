package com.fleon.switchlings;

import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.util.Log;

import java.io.File;

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
     * Loads every library but the main one, which SDL's {@code nativeRunMain}
     * then dlopens on its own thread.
     *
     * <p>That is the point: loading libAndroidShell.so here would run its
     * dependencies' constructors on Android's UI thread, and libdispatch
     * binds its main queue to whichever thread runs its constructor. The
     * game lives on SDL's thread, so {@code DispatchQueue.main} and the main
     * actor have to be bound there, or nothing the game queues for the main
     * thread ever runs. The shell drains the queue once a frame.
     */
    @Override
    public void loadLibraries() {
        String[] libraries = getLibraries();
        for (int i = 0; i < libraries.length - 1; i++) {
            System.loadLibrary(libraries[i]);
        }
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

    /**
     * Opens Android's share sheet with a file the game wrote — a share film
     * or its picture — and the line and link that go with it. Called from
     * Swift (`ShareSheet`, through JNI) on SDL's thread, so the intent is
     * started on the UI thread.
     *
     * @param path a file under the cache directory, handed out through
     *             {@link FilmProvider}
     * @param mime {@code video/mp4} or {@code image/png}
     * @param text the line and link, or null
     */
    public void shareFile(final String path, final String mime, final String text) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                try {
                    Uri uri = FilmProvider.uriFor(MainActivity.this, new File(path));
                    Intent send = new Intent(Intent.ACTION_SEND);
                    send.setType(mime);
                    send.putExtra(Intent.EXTRA_STREAM, uri);
                    if (text != null && !text.isEmpty()) {
                        send.putExtra(Intent.EXTRA_TEXT, text);
                    }
                    // The grant rides on the clip data too, so the chooser's
                    // preview and whichever app is picked can both read it.
                    send.setClipData(ClipData.newRawUri(null, uri));
                    send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    Intent chooser = Intent.createChooser(send, null);
                    chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    startActivity(chooser);
                    Log.i("Switchlings", "share sheet: " + uri);
                } catch (Exception e) {
                    Log.e("Switchlings", "could not share " + path, e);
                }
            }
        });
    }
}
