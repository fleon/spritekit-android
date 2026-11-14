package com.fleon.switchlings;

import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.content.Context;
import android.view.View;
import android.view.WindowInsets;
import android.view.KeyEvent;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;
import android.util.Log;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import android.content.ClipboardManager;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.PopupWindow;
import android.widget.TextView;

import org.libsdl.app.SDLActivity;
import org.libsdl.app.SDLSurface;

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
        exportVersion();
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
        List<String> all = new ArrayList<>(Arrays.asList(arguments == null ? super.getArguments() : arguments));
        // A link that started the game: the shell hands `-OpenLink` to the
        // game's launch, as iOS's scene delegate hands its URL contexts.
        String link = gameLink(intent);
        if (link != null) {
            all.add("-OpenLink");
            all.add(link);
        }
        return all.toArray(new String[0]);
    }

    // MARK: Links

    /**
     * The link an intent opens, as the game reads links: its own
     * {@code switchlings://level/<code>} and {@code switchlings://world/<id>},
     * and a level's page, {@code https://switchlings.fleon.com/l/<code>},
     * which is the same level's {@code switchlings://} link.
     */
    static String gameLink(Intent intent) {
        if (intent == null || !Intent.ACTION_VIEW.equals(intent.getAction())) return null;
        Uri uri = intent.getData();
        if (uri == null || uri.getScheme() == null) return null;
        String scheme = uri.getScheme().toLowerCase();
        if (scheme.equals("switchlings")) return uri.toString();
        List<String> path = uri.getPathSegments();
        if (scheme.equals("https") && path.size() == 2 && path.get(0).equals("l")) {
            return "switchlings://level/" + path.get(1);
        }
        return null;
    }

    /** Links that arrived before the shell registered its natives. */
    private final List<String> heldLinks = new ArrayList<>();
    private volatile boolean nativesReady;

    /** A link opened while the game runs ({@code singleInstance}). */
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        String link = gameLink(intent);
        if (link == null) return;
        synchronized (heldLinks) {
            if (!nativesReady) {
                heldLinks.add(link);
                return;
            }
        }
        nativeOpenLink(link);
    }

    /** The shell has registered the natives below (on SDL's thread). */
    public void nativesRegistered() {
        synchronized (heldLinks) {
            nativesReady = true;
            for (String link : heldLinks) nativeOpenLink(link);
            heldLinks.clear();
        }
    }

    // Registered by the shell on this class (`switchlings_register_natives`),
    // since SDL loads libAndroidShell.so itself.
    static native void nativeOpenLink(String link);
    static native void nativePaste(String text);
    static native void nativeKeyboard(int height, int viewHeight);

    // MARK: Paste

    private PopupWindow pastePopup;

    /**
     * What a long press on the Level Designer's code boxes offers, as iOS's
     * edit menu does over its text field: Android's Paste, over the point
     * pressed (view pixels). Picking it hands the clipboard's text to the
     * field as a paste. Nothing shows when the clipboard holds no text.
     */
    public void offerPaste(final float x, final float y) {
        runOnUiThread(() -> {
            final String text = clipboardText();
            if (text == null || text.isEmpty() || mSurface == null) return;
            if (pastePopup != null) pastePopup.dismiss();
            float dp = getResources().getDisplayMetrics().density;
            TextView paste = new TextView(this);
            paste.setText(android.R.string.paste);
            paste.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
            paste.setTextColor(0xFFFFFFFF);
            int padH = Math.round(16 * dp), padV = Math.round(10 * dp);
            paste.setPadding(padH, padV, padH, padV);
            GradientDrawable pill = new GradientDrawable();
            pill.setColor(0xF0303030);
            pill.setCornerRadius(20 * dp);
            paste.setBackground(pill);
            final PopupWindow popup = new PopupWindow(paste, ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, false);
            popup.setOutsideTouchable(true);
            popup.setElevation(6 * dp);
            paste.setOnClickListener(v -> {
                popup.dismiss();
                nativePaste(text);
            });
            paste.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED);
            int[] origin = new int[2];
            mSurface.getLocationOnScreen(origin);
            int px = origin[0] + Math.round(x) - paste.getMeasuredWidth() / 2;
            int py = origin[1] + Math.round(y) - paste.getMeasuredHeight() - Math.round(12 * dp);
            popup.showAtLocation(mSurface, Gravity.NO_GRAVITY, px, Math.max(origin[1], py));
            pastePopup = popup;
        });
    }

    private String clipboardText() {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboard == null || !clipboard.hasPrimaryClip() || clipboard.getPrimaryClip() == null) return null;
        if (clipboard.getPrimaryClip().getItemCount() == 0) return null;
        CharSequence text = clipboard.getPrimaryClip().getItemAt(0).coerceToText(this);
        return text == null ? null : text.toString();
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

    /**
     * Android's back goes to the game first, which treats it as the Apple TV
     * remote's Back (Escape): it closes a popup or goes back, and leaves the
     * game only from the title.
     *
     * <p>Targeting Android 16, the system no longer sends a back key or calls
     * {@code onBackPressed} (predictive back), so the gesture is caught here
     * and handed to SDL as the back key it used to be. Older versions send
     * the key themselves, and SDL's trap hint (set by the shell) keeps
     * {@code onBackPressed} from finishing the activity.
     */
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        services = new PlatformServices(this);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            OnBackInvokedCallback callback = () -> {
                SDLActivity.onNativeKeyDown(KeyEvent.KEYCODE_BACK);
                SDLActivity.onNativeKeyUp(KeyEvent.KEYCODE_BACK);
            };
            backCallback = callback;
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback);
        }
    }

    /** Kept so the dispatcher's callback lives as long as the activity. */
    private Object backCallback;

    /** Play Billing, Play Games and the device, for the game (see {@link PlatformServices}). */
    private PlatformServices services;

    /**
     * Tells the frame loop that platform events are waiting. Registered by
     * the shell ({@code switchlings_platform_install}, RegisterNatives) as
     * it starts: SDL dlopens libAndroidShell.so, so the JVM would never find
     * the symbol by name.
     */
    static native void nativePlatformEventsReady();

    /** Set by the shell once it has registered the method above. */
    static volatile boolean nativePlatformRegistered;

    /** A platform call from Swift, on SDL's thread. */
    public byte[] platformCall(String name, byte[] args) {
        return services == null ? null : services.call(name, args);
    }

    /** The events waiting for Swift, as a JSON array, or null. */
    public byte[] platformDrain() {
        return services == null ? null : services.drainEvents();
    }

    @Override
    protected void onResume() {
        // Before SDL resumes the game, so audio focus is settled first.
        if (services != null) services.onResume();
        super.onResume();
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (services != null) services.onPause();
    }

    @Override
    protected void onDestroy() {
        if (services != null) services.onDestroy();
        super.onDestroy();
    }

    /**
     * What the game asks for when nothing took the back button
     * ({@code SDL_SendAndroidBackButton}): leave, as back from a launcher
     * app's first screen does — to the background, not finished.
     */
    @Override
    public void superOnBackPressed() {
        moveTaskToBack(true);
    }

    @Override
    protected SDLSurface createSDLSurface(Context context) {
        return new GameSurface(context);
    }

    /**
     * SDL's surface, with the safe area iOS would give: the system bars and
     * the display cutout, and at the bottom the gesture-navigation handle,
     * as iOS counts the home indicator. SDL's own adds the back-gesture
     * edges (about 30 dp each side), which an iPhone's safe area has no
     * counterpart for, so every screen came out 60 points narrower than the
     * same screen on iOS; and with the bars hidden (full screen) the bottom
     * read 0, so the game took a phone with a home handle for one without
     * rounded corners. SDL's listener still runs first, for the keyboard;
     * the insets it reports are then replaced.
     */
    static final class GameSurface extends SDLSurface {
        private int lastKeyboard;

        GameSurface(Context context) {
            super(context);
        }

        @Override
        public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
            WindowInsets result = super.onApplyWindowInsets(v, insets);
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets safe = insets.getInsets(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                android.graphics.Insets handle = insets.getInsets(WindowInsets.Type.mandatorySystemGestures());
                int bottom = Math.max(safe.bottom, handle.bottom);
                SDLActivity.onNativeInsetsChanged(safe.left, safe.right, safe.top, bottom);
                if (Build.VERSION.SDK_INT >= 31) {
                    android.view.RoundedCorner corner = insets.getRoundedCorner(android.view.RoundedCorner.POSITION_TOP_LEFT);
                    Log.i("Switchlings", "insets: safe " + safe + ", handle " + handle.bottom
                        + " px, corner radius " + (corner == null ? "none" : corner.getRadius() + " px"));
                }
                // The soft keyboard's height, which the game hears as UIKit's
                // keyboard notifications: the code prompt rises clear of it.
                int ime = insets.isVisible(WindowInsets.Type.ime())
                    ? insets.getInsets(WindowInsets.Type.ime()).bottom : 0;
                MainActivity activity = (MainActivity) getContext();
                if (activity.nativesReady && ime != lastKeyboard) {
                    lastKeyboard = ime;
                    nativeKeyboard(ime, v.getHeight());
                }
            }
            return result;
        }
    }

    /**
     * The APK's {@code versionName} and {@code versionCode}, in the
     * environment for the shim's {@code Bundle.infoDictionary} (the title's
     * version line), set before the Swift libraries load.
     */
    private void exportVersion() {
        try {
            android.content.pm.PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            long code = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ? info.getLongVersionCode() : info.versionCode;
            android.system.Os.setenv("SWITCHLINGS_VERSION_NAME", info.versionName == null ? "" : info.versionName, true);
            android.system.Os.setenv("SWITCHLINGS_VERSION_CODE", String.valueOf(code), true);
        } catch (Exception e) {
            Log.w("Switchlings", "no version for Bundle.main: " + e);
        }
    }
}
