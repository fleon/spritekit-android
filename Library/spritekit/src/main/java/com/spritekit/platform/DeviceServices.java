package com.spritekit.platform;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.BatteryManager;
import android.os.Build;
import android.os.PowerManager;
import android.os.VibrationAttributes;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.os.VibratorManager;
import android.util.Base64;
import android.util.Log;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;

/**
 * The device's part: haptics, audio focus, battery saver, the status bar,
 * the app's settings page, the battery and the connection, and re-encoding
 * images between JPEG and PNG.
 *
 * <p><b>Haptics.</b> The game's five feedback kinds (UIKit's light, medium
 * and soft impacts, selection, success and warning) as Android's haptic
 * primitives where the vibrator has them, its predefined effects where not,
 * and a short buzz on the oldest. Played as touch feedback, so the system's
 * own "vibration & haptics" switch silences them as it does every app's.
 *
 * <p><b>Audio focus,</b> to the iOS build's ambient session: the player's
 * own music wins. If something else is playing music as the game comes to
 * the front, the game asks for no focus and keeps its soundtrack quiet
 * (its sounds still mix in); otherwise it takes focus for the soundtrack and
 * steps aside the moment another app takes it, and pauses for a call. It
 * holds focus until it stops, not merely pauses ({@link AudioFocusPolicy}).
 * Events: {@code audio} with {@code otherAudio} and {@code interrupted}.
 *
 * <p><b>Battery saver</b> is iOS's Low Power Mode: the game holds its frame
 * rate to 60 while it is on. Event: {@code powerSave}.
 */
public final class DeviceServices implements AudioManager.OnAudioFocusChangeListener, PlatformService {
    public static final String SERVICE = "device";

    private final Activity activity;
    private final PlatformServices services;
    private final Vibrator vibrator;
    private final AudioManager audio;
    private final PowerManager power;
    private AudioFocusRequest focusRequest;
    private boolean hasFocus;
    private final AudioFocusPolicy focusPolicy = new AudioFocusPolicy();

    private final BroadcastReceiver powerSaveReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            postPowerSave();
        }
    };

    public DeviceServices(Activity activity, PlatformServices services) {
        this.activity = activity;
        this.services = services;
        if (Build.VERSION.SDK_INT >= 31) {
            VibratorManager manager = (VibratorManager) activity.getSystemService(Context.VIBRATOR_MANAGER_SERVICE);
            vibrator = manager != null ? manager.getDefaultVibrator() : null;
        } else {
            vibrator = (Vibrator) activity.getSystemService(Context.VIBRATOR_SERVICE);
        }
        audio = (AudioManager) activity.getSystemService(Context.AUDIO_SERVICE);
        power = (PowerManager) activity.getSystemService(Context.POWER_SERVICE);
        IntentFilter filter = new IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED);
        if (Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(powerSaveReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            activity.registerReceiver(powerSaveReceiver, filter);
        }
    }

    @Override
    public JSONObject call(String method, JSONObject args) {
        switch (method) {
            case "haptic":
                haptic(args.optString("kind"));
                return null;
            case "statusBar": {
                boolean visible = args.optBoolean("visible");
                activity.runOnUiThread(() -> showStatusBar(visible));
                return null;
            }
            case "state":
                return PlatformServices.object(
                    "powerSave", power != null && power.isPowerSaveMode(),
                    "haptics", vibrator != null && vibrator.hasVibrator());
            case "openAppSettings":
                return PlatformServices.object("ok", openAppSettings());
            case "battery":
                return PlatformServices.object("level", batteryLevel());
            case "connection":
                return PlatformServices.object("kind", connection());
            case "jpegToPng":
                return convert(args.optString("data"), Bitmap.CompressFormat.PNG, 100);
            case "pngToJpeg":
                return convert(args.optString("data"), Bitmap.CompressFormat.JPEG, args.optInt("quality", 85));
            default:
                Log.w(PlatformServices.tag(), "no device." + method);
                return null;
        }
    }

    /**
     * The app's page in the system settings, where
     * {@code UIApplication.openSettingsURLString} goes on iOS.
     */
    private boolean openAppSettings() {
        try {
            Intent intent = new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    android.net.Uri.fromParts("package", activity.getPackageName(), null));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity.startActivity(intent);
            return true;
        } catch (RuntimeException e) {
            Log.w(PlatformServices.tag(), "no app settings", e);
            return false;
        }
    }

    /** The battery's charge from 0 to 1, or -1 where there's none to read ({@code UIDevice.batteryLevel}). */
    private double batteryLevel() {
        BatteryManager battery = (BatteryManager) activity.getSystemService(Context.BATTERY_SERVICE);
        int percent = battery == null ? -1 : battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
        return percent < 0 || percent > 100 ? -1 : percent / 100.0;
    }

    /**
     * How the device reaches the internet, as iOS's path monitor names it:
     * {@code wifi}, {@code cellular}, {@code wired}, {@code other} or
     * {@code none}. Needs {@code ACCESS_NETWORK_STATE} in the game's
     * manifest; without it, {@code other}.
     */
    private String connection() {
        ConnectivityManager connectivity = (ConnectivityManager) activity.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (connectivity == null) return "other";
        try {
            Network network = connectivity.getActiveNetwork();
            NetworkCapabilities capabilities = network == null ? null : connectivity.getNetworkCapabilities(network);
            if (capabilities == null || !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return "none";
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return "wifi";
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) return "cellular";
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) return "wired";
            return "other";
        } catch (SecurityException noPermission) {
            return "other";
        }
    }

    /**
     * Re-encodes an image (base64 in, base64 out), synchronously: the shim
     * decodes PNG itself but has no JPEG codec (UIKit's {@code jpegData} and
     * a JPEG's {@code UIImage}).
     */
    private static JSONObject convert(String base64, Bitmap.CompressFormat format, int quality) {
        byte[] bytes = Base64.decode(base64, Base64.NO_WRAP);
        Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (bitmap == null) return null;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        if (!bitmap.compress(format, quality, out)) return null;
        return PlatformServices.object("data", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP));
    }

    /**
     * The settings' status bar switch: the status bar shows over the game or
     * hides, as the iOS build's {@code prefersStatusBarHidden} follows it.
     * Only the status bar: the navigation bar keeps SDL's own setting.
     */
    private void showStatusBar(boolean visible) {
        Window window = activity.getWindow();
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController controller = window.getInsetsController();
            if (controller == null) return;
            if (visible) {
                controller.show(WindowInsets.Type.statusBars());
            } else {
                controller.hide(WindowInsets.Type.statusBars());
                controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else if (visible) {
            window.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
        }
    }

    @Override
    public void onResume() {
        postPowerSave();
        if (audio == null) return;
        // Before SDL resumes the game's own stream, which is stopped only
        // after a stop (`AudioFocusPolicy`).
        switch (focusPolicy.onResume(hasFocus, audio.isMusicActive())) {
            case OTHER_AUDIO:
                services.post(SERVICE, "audio", PlatformServices.object("otherAudio", true, "interrupted", false));
                break;
            case REQUEST:
                requestFocus();
                break;
            case KEEP:
                break;
        }
    }

    @Override
    public void onStop() {
        focusPolicy.onStop();
        abandonFocus();
    }

    @Override
    public void onDestroy() {
        abandonFocus();
        try {
            activity.unregisterReceiver(powerSaveReceiver);
        } catch (IllegalArgumentException alreadyGone) {
            // Never registered, or already unregistered.
        }
    }

    private void postPowerSave() {
        services.post(SERVICE, "powerSave", PlatformServices.object("enabled", power != null && power.isPowerSaveMode()));
    }

    // MARK: - Audio focus

    private void requestFocus() {
        if (audio == null || hasFocus) return;
        int result;
        if (Build.VERSION.SDK_INT >= 26) {
            if (focusRequest == null) {
                focusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_GAME)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                    .setOnAudioFocusChangeListener(this)
                    .build();
            }
            result = audio.requestAudioFocus(focusRequest);
        } else {
            result = audio.requestAudioFocus(this, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
        }
        hasFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
        services.post(SERVICE, "audio", PlatformServices.object("otherAudio", !hasFocus, "interrupted", false));
    }

    private void abandonFocus() {
        if (audio == null || !hasFocus) return;
        if (Build.VERSION.SDK_INT >= 26 && focusRequest != null) {
            audio.abandonAudioFocusRequest(focusRequest);
        } else {
            audio.abandonAudioFocus(this);
        }
        hasFocus = false;
    }

    @Override
    public void onAudioFocusChange(int change) {
        switch (change) {
            case AudioManager.AUDIOFOCUS_GAIN:
                hasFocus = true;
                services.post(SERVICE, "audio", PlatformServices.object("otherAudio", false, "interrupted", false));
                break;
            case AudioManager.AUDIOFOCUS_LOSS:
                // Another app's music: the soundtrack steps aside for good,
                // until the game next comes to the front.
                abandonFocus();
                services.post(SERVICE, "audio", PlatformServices.object("otherAudio", true, "interrupted", false));
                break;
            case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
                // A call or an alarm: everything waits.
                services.post(SERVICE, "audio", PlatformServices.object("otherAudio", false, "interrupted", true));
                break;
            default:
                // LOSS_TRANSIENT_CAN_DUCK: the system ducks us itself.
                break;
        }
    }

    // MARK: - Haptics

    private void haptic(String kind) {
        if (vibrator == null || !vibrator.hasVibrator()) return;
        VibrationEffect effect = Build.VERSION.SDK_INT >= 30 ? composed(kind) : null;
        if (effect == null && Build.VERSION.SDK_INT >= 29) effect = predefined(kind);
        if (effect == null && Build.VERSION.SDK_INT >= 26) effect = VibrationEffect.createOneShot(milliseconds(kind), amplitude(kind));
        if (effect == null) {
            vibrator.vibrate(milliseconds(kind));
        } else if (Build.VERSION.SDK_INT >= 33) {
            vibrator.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH));
        } else {
            vibrator.vibrate(effect, new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION).build());
        }
    }

    /** Haptic primitives (Android 11+), if this vibrator plays them. */
    private VibrationEffect composed(String kind) {
        int click = VibrationEffect.Composition.PRIMITIVE_CLICK;
        int tick = VibrationEffect.Composition.PRIMITIVE_TICK;
        if (!vibrator.areAllPrimitivesSupported(click, tick)) return null;
        VibrationEffect.Composition composition = VibrationEffect.startComposition();
        switch (kind) {
            case "light": composition.addPrimitive(click, 0.5f); break;
            case "medium": composition.addPrimitive(click, 0.8f); break;
            case "soft": composition.addPrimitive(tick, 0.7f); break;
            case "selection": composition.addPrimitive(tick, 0.5f); break;
            case "success":
                composition.addPrimitive(click, 0.6f);
                composition.addPrimitive(click, 1.0f, 80);
                break;
            case "warning":
                composition.addPrimitive(click, 1.0f);
                composition.addPrimitive(click, 0.6f, 120);
                break;
            default: return null;
        }
        return composition.compose();
    }

    private static VibrationEffect predefined(String kind) {
        switch (kind) {
            case "light":
            case "soft":
            case "selection": return VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK);
            case "medium": return VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK);
            case "success": return VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK);
            case "warning": return VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK);
            default: return null;
        }
    }

    private static long milliseconds(String kind) {
        switch (kind) {
            case "medium": return 20;
            case "success":
            case "warning": return 35;
            default: return 10;
        }
    }

    private static int amplitude(String kind) {
        switch (kind) {
            case "medium":
            case "warning": return 200;
            case "success": return 160;
            default: return 90;
        }
    }
}
