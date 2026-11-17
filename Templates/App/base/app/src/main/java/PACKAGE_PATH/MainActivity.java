package PACKAGE_NAME;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.os.Build;
import android.os.Bundle;
import android.util.Base64;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowInsets;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import org.json.JSONArray;
import org.json.JSONException;

import org.libsdl.app.SDLActivity;
import org.libsdl.app.SDLSurface;

/**
 * The APK's only activity.
 *
 * <p>SDL owns the Android side of the port — the activity lifecycle, the GL
 * surface, touch, keyboard, gamepads and audio — so this project writes no
 * JNI of its own. Everything above the GL context is Swift, in
 * libAndroidShell.so (SpriteKit for Android's shell, with the game in it).
 *
 * <p>The base the runtime's template gives every game: launch arguments in
 * debuggable builds, Android's back gesture handed to the game, the safe
 * area as iOS would give it, and the platform channel. A game that opens
 * links or takes pasted text adds those halves (`nativeOpenLink`,
 * `nativePaste`).
 */
public class MainActivity extends SDLActivity {

    /**
     * Loaded in order. SDL treats the last entry as the "main shared object":
     * it dlopens libAndroidShell.so and calls the {@code SDL_main} that
     * Entry.swift exports with {@code @_cdecl}.
     */
    @Override
    protected String[] getLibraries() {
        return new String[] { "SDL3", "AndroidShell" };
    }

    /**
     * Loads every library but the main one, which SDL's {@code nativeRunMain}
     * then dlopens on its own thread: libdispatch binds its main queue to
     * whichever thread runs its constructor, and the game lives on SDL's.
     */
    @Override
    public void loadLibraries() {
        exportVersion();
        exportDeterministicHashing();
        String[] libraries = getLibraries();
        for (int i = 0; i < libraries.length - 1; i++) {
            System.loadLibrary(libraries[i]);
        }
    }

    /**
     * What SDL hands {@code SDL_main} as argv: in a debuggable build, the
     * launch arguments in the intent's {@code args} (comma-separated) or
     * {@code args64} (base64 of a JSON array of strings) extras.
     *
     * <pre>
     * adb shell am start -n PACKAGE_NAME/.MainActivity --esa args -FixedFrameStep,0.0333
     * </pre>
     */
    @Override
    protected String[] getArguments() {
        Intent intent = getIntent();
        if (intent == null) {
            return super.getArguments();
        }
        List<String> all = new ArrayList<>(Arrays.asList(super.getArguments()));
        boolean debuggable = (getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
        if (debuggable) {
            String[] plain = intent.getStringArrayExtra("args");
            if (plain != null) {
                all.addAll(Arrays.asList(plain));
            }
            String encoded = intent.getStringExtra("args64");
            if (encoded != null) {
                try {
                    String json = new String(Base64.decode(encoded, Base64.DEFAULT), StandardCharsets.UTF_8);
                    JSONArray array = new JSONArray(json);
                    for (int i = 0; i < array.length(); i++) {
                        all.add(array.getString(i));
                    }
                } catch (IllegalArgumentException | JSONException e) {
                    Log.e(PlatformServices.TAG, "args64 is not base64 of a JSON array of strings", e);
                }
            }
        }
        return all.toArray(new String[0]);
    }

    // Registered by the shell on this class (`ska_register_natives`, which
    // registers all three or none), since SDL loads libAndroidShell.so itself.
    // A game that opens no links and takes no pasted text has only the
    // keyboard's called.
    static native void nativeOpenLink(String link);
    static native void nativePaste(String text);
    static native void nativeKeyboard(int height, int viewHeight);

    private volatile boolean nativesReady;

    /** The shell has registered the natives above (on SDL's thread). */
    public void nativesRegistered() {
        nativesReady = true;
    }

    /**
     * Android's back goes to the game first, which treats it as Escape: it
     * closes a popup or goes back, and leaves the game only from the title.
     *
     * <p>Targeting Android 16, the system no longer sends a back key
     * (predictive back), so the gesture is caught here and handed to SDL as
     * the back key it used to be.
     */
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        holdDebugOrientation();
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

    /** {@code -Orientation portrait|landscape|flipped} (debug builds), held before SDL starts. */
    private void holdDebugOrientation() {
        String[] args = getArguments();
        for (int i = 0; i + 1 < args.length; i++) {
            if (!"-Orientation".equals(args[i])) continue;
            switch (args[i + 1]) {
                case "portrait": setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT); break;
                case "landscape": setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE); break;
                case "flipped": setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE); break;
                default: break;
            }
        }
    }

    /** Kept so the dispatcher's callback lives as long as the activity. */
    private Object backCallback;

    /** Play Games, Play In-App Review and the device, for the game (see {@link PlatformServices}). */
    private PlatformServices services;

    /** Tells the frame loop that platform events are waiting; registered by the shell. */
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
    protected void onStop() {
        super.onStop();
        if (services != null) services.onStop();
    }

    @Override
    protected void onDestroy() {
        if (services != null) services.onDestroy();
        super.onDestroy();
    }

    /** Nothing took the back button: leave to the background, not finished. */
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
     * the display cutout, and at the bottom the gesture-navigation handle, as
     * iOS counts the home indicator. SDL's own adds the back-gesture edges,
     * which an iPhone's safe area has no counterpart for.
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
                android.graphics.Insets nav = insets.getInsetsIgnoringVisibility(WindowInsets.Type.navigationBars());
                android.graphics.Insets tappable = insets.getInsetsIgnoringVisibility(WindowInsets.Type.tappableElement());
                boolean buttons = (nav.bottom > 0 && tappable.bottom > 0)
                    || (nav.left > 0 && tappable.left > 0) || (nav.right > 0 && tappable.right > 0);
                int handle = buttons ? 0 : insets.getInsets(WindowInsets.Type.mandatorySystemGestures()).bottom;
                int bottom = Math.max(safe.bottom, handle);
                SDLActivity.onNativeInsetsChanged(safe.left, safe.right, safe.top, bottom);
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
     * {@code -FixedFrameStep} (debug builds only) also asks Swift for the
     * same {@code Dictionary} and {@code Set} order every launch.
     */
    private void exportDeterministicHashing() {
        if (!Arrays.asList(getArguments()).contains("-FixedFrameStep")) return;
        try {
            android.system.Os.setenv("SWIFT_DETERMINISTIC_HASHING", "1", true);
        } catch (Exception e) {
            Log.w(PlatformServices.TAG, "no deterministic hashing: " + e);
        }
    }

    /**
     * The APK's {@code versionName} and {@code versionCode}, in the
     * environment for the shim's {@code Bundle.infoDictionary}, set before the
     * Swift libraries load.
     */
    private void exportVersion() {
        try {
            android.content.pm.PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            long code = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ? info.getLongVersionCode() : info.versionCode;
            android.system.Os.setenv("SKA_VERSION_NAME", info.versionName == null ? "" : info.versionName, true);
            android.system.Os.setenv("SKA_VERSION_CODE", String.valueOf(code), true);
        } catch (Exception e) {
            Log.w(PlatformServices.TAG, "no version for Bundle.main: " + e);
        }
    }
}
