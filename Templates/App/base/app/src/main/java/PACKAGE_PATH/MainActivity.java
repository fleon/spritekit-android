package PACKAGE_NAME;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Base64;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.PopupWindow;
import android.widget.TextView;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

import androidx.core.content.FileProvider;

import java.io.File;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

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
 * debuggable builds, the version, device and beta flag in the environment,
 * Android's back gesture handed to the game, the safe area as iOS would give
 * it, the share sheet, Paste, and the platform channel. An intent that
 * arrives while the game runs becomes the activity's intent (what a
 * notification tap is read from), and its link, if it has one, goes to
 * {@code nativeOpenLink}. A game that opens links adds only its intent
 * filters.
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
        exportDevice();
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

    /**
     * A tap on a notification or a link while the game runs: the new intent
     * replaces the old one, so whatever reads {@code getIntent()} sees it,
     * and its link goes to the game ({@code GameHost.open}).
     */
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (intent != null && intent.getData() != null) {
            nativeOpenLink(intent.getData().toString());
        }
    }

    // Registered by the shell on this class (`ska_register_natives`, which
    // registers all three or none), since SDL loads libAndroidShell.so itself.
    // A game that opens no links never has the first called.
    static native void nativeOpenLink(String link);
    static native void nativePaste(String text);
    static native void nativeKeyboard(int height, int viewHeight);

    private volatile boolean nativesReady;

    /** The shell has registered the natives above (on SDL's thread). */
    public void nativesRegistered() {
        nativesReady = true;
    }

    private static final float PASTE_TEXT_SP = 15;
    private static final float PASTE_PADDING_H_DP = 16;
    private static final float PASTE_PADDING_V_DP = 10;
    private static final float PASTE_CORNER_DP = 20;
    private static final float PASTE_ELEVATION_DP = 6;
    /** How far above the pressed point the button sits. */
    private static final float PASTE_GAP_DP = 12;
    private static final int PASTE_TEXT_COLOR = 0xFFFFFFFF;
    private static final int PASTE_FILL_COLOR = 0xF0303030;

    private PopupWindow pastePopup;

    /**
     * What a long press on a text field offers, as iOS's edit menu does:
     * Android's Paste, over the point pressed (view pixels). Picking it hands
     * the clipboard's text to the field as a paste ({@code nativePaste}).
     * Nothing shows when the clipboard holds no text. Called from Swift
     * ({@code TextInput.offerPaste}, through JNI) on SDL's thread.
     */
    public void offerPaste(final float x, final float y) {
        runOnUiThread(() -> {
            final String text = clipboardText();
            if (text == null || text.isEmpty() || mSurface == null || !nativesReady) return;
            if (pastePopup != null) pastePopup.dismiss();
            float dp = getResources().getDisplayMetrics().density;
            TextView paste = new TextView(this);
            paste.setText(android.R.string.paste);
            paste.setTextSize(TypedValue.COMPLEX_UNIT_SP, PASTE_TEXT_SP);
            paste.setTextColor(PASTE_TEXT_COLOR);
            int padH = Math.round(PASTE_PADDING_H_DP * dp), padV = Math.round(PASTE_PADDING_V_DP * dp);
            paste.setPadding(padH, padV, padH, padV);
            GradientDrawable pill = new GradientDrawable();
            pill.setColor(PASTE_FILL_COLOR);
            pill.setCornerRadius(PASTE_CORNER_DP * dp);
            paste.setBackground(pill);
            final PopupWindow popup = new PopupWindow(paste,
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, false);
            popup.setOutsideTouchable(true);
            popup.setElevation(PASTE_ELEVATION_DP * dp);
            paste.setOnClickListener(v -> {
                popup.dismiss();
                nativePaste(text);
            });
            paste.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED);
            int[] origin = new int[2];
            mSurface.getLocationOnScreen(origin);
            int px = origin[0] + Math.round(x) - paste.getMeasuredWidth() / 2;
            int py = origin[1] + Math.round(y) - paste.getMeasuredHeight() - Math.round(PASTE_GAP_DP * dp);
            popup.showAtLocation(mSurface, Gravity.NO_GRAVITY, px, Math.max(origin[1], py));
            pastePopup = popup;
        });
    }

    private String clipboardText() {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        ClipData clip = clipboard == null ? null : clipboard.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) return null;
        CharSequence text = clip.getItemAt(0).coerceToText(this);
        return text == null ? null : text.toString();
    }

    /**
     * Opens Android's share sheet with a file the game wrote — a video or a
     * picture — and the words that go with it. Called from Swift
     * ({@code SystemShare.sheet}, through JNI) on SDL's thread, so the intent
     * is started on the UI thread.
     *
     * @param path a file under the cache directory, handed out through
     *             androidx's {@link FileProvider} ({@code res/xml/shared_files.xml})
     * @param mime its type, such as {@code video/mp4} or {@code image/png}
     * @param text the words that go with it, or null
     */
    public void shareFile(final String path, final String mime, final String text) {
        runOnUiThread(() -> {
            try {
                Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".files", new File(path));
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
            } catch (Exception e) {
                Log.e(PlatformServices.TAG, "could not share " + path, e);
            }
        });
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

    /**
     * The device and the build, in the environment for the shim's
     * {@code AndroidDevice} and {@code BetaBuild} (and through them the
     * game's {@code LaunchDefaults}): the maker and model ("Google Pixel 9"),
     * the Android version ("17"), whether this is an emulator, and whether
     * the build is a beta. Set before the Swift libraries load.
     */
    private void exportDevice() {
        try {
            android.system.Os.setenv("SKA_DEVICE_MODEL", deviceModel(), true);
            android.system.Os.setenv("SKA_OS_VERSION", Build.VERSION.RELEASE == null ? "" : Build.VERSION.RELEASE, true);
            android.system.Os.setenv("SKA_EMULATOR", isEmulator() ? "1" : "0", true);
            android.system.Os.setenv("SKA_BETA", isBetaBuild() ? "1" : "0", true);
        } catch (Exception e) {
            Log.w(PlatformServices.TAG, "no device or build in the environment: " + e);
        }
    }

    /**
     * Whether this build is a beta, for Play's testing tracks: Gradle writes
     * {@code -Pgame.beta} into {@code build.json} at the root of the assets
     * ({@code stageBuildInfo}). A build without it is not a beta.
     */
    private boolean isBetaBuild() {
        try (InputStream in = getAssets().open("build.json")) {
            byte[] bytes = new byte[256];
            int length = in.read(bytes);
            return length > 0 && new JSONObject(new String(bytes, 0, length, StandardCharsets.UTF_8)).optBoolean("beta", false);
        } catch (Exception e) {
            Log.w(PlatformServices.TAG, "no build.json, so not a beta build: " + e);
            return false;
        }
    }

    /** "Google Pixel 9": the maker, capitalised, unless the model names it already. */
    private static String deviceModel() {
        String maker = Build.MANUFACTURER == null ? "" : Build.MANUFACTURER;
        String model = Build.MODEL == null ? "" : Build.MODEL;
        if (maker.isEmpty() || model.toLowerCase(Locale.ROOT).startsWith(maker.toLowerCase(Locale.ROOT))) return model;
        return Character.toUpperCase(maker.charAt(0)) + maker.substring(1) + " " + model;
    }

    /** The emulator's build: its goldfish or ranchu hardware, or an SDK image's fingerprint. */
    private static boolean isEmulator() {
        String fingerprint = Build.FINGERPRINT == null ? "" : Build.FINGERPRINT;
        String hardware = Build.HARDWARE == null ? "" : Build.HARDWARE;
        String product = Build.PRODUCT == null ? "" : Build.PRODUCT;
        return hardware.contains("goldfish") || hardware.contains("ranchu")
            || fingerprint.startsWith("generic") || fingerprint.contains("emulator") || fingerprint.contains("/sdk_")
            || product.startsWith("sdk") || product.contains("emulator") || product.contains("simulator");
    }
}
