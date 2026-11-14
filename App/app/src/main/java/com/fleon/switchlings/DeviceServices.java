package com.fleon.switchlings;

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

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;

/**
 * The device's part: haptics, audio focus, battery saver, and the battery
 * and connection the beta's solve log records.
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
 * steps aside the moment another app takes it, and pauses for a call.
 * Events: {@code audio} with {@code otherAudio} and {@code interrupted}.
 *
 * <p><b>Battery saver</b> is iOS's Low Power Mode: the game holds its frame
 * rate to 60 while it is on. Event: {@code powerSave}.
 */
final class DeviceServices implements AudioManager.OnAudioFocusChangeListener {
    private static final String SERVICE = "device";

    private final Activity activity;
    private final PlatformServices services;
    private final Vibrator vibrator;
    private final AudioManager audio;
    private final PowerManager power;
    private AudioFocusRequest focusRequest;
    private boolean hasFocus;

    private final BroadcastReceiver powerSaveReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            postPowerSave();
        }
    };

    DeviceServices(Activity activity, PlatformServices services) {
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

    JSONObject call(String method, JSONObject args) {
        switch (method) {
            case "haptic":
                haptic(args.optString("kind"));
                return null;
            case "jpegToPng":
                return convert(args.optString("data"), Bitmap.CompressFormat.PNG, 100);
            case "pngToJpeg":
                return convert(args.optString("data"), Bitmap.CompressFormat.JPEG, args.optInt("quality", 85));
            case "battery":
                return PlatformServices.object("level", batteryLevel());
            case "connection":
                return PlatformServices.object("kind", connection());
            case "state":
                return PlatformServices.object(
                    "powerSave", power != null && power.isPowerSaveMode(),
                    "haptics", vibrator != null && vibrator.hasVibrator());
            default:
                Log.w(PlatformServices.TAG, "no device." + method);
                return null;
        }
    }

    /** The battery's charge from 0 to 1, or -1 where there's none to read (the solve log's). */
    private double batteryLevel() {
        BatteryManager battery = (BatteryManager) activity.getSystemService(Context.BATTERY_SERVICE);
        int percent = battery == null ? -1 : battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
        return percent < 0 || percent > 100 ? -1 : percent / 100.0;
    }

    /**
     * How the device reaches the internet, as the solve log names it (iOS's
     * path monitor): {@code wifi}, {@code cellular}, {@code wired},
     * {@code other} or {@code none}.
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

    void onResume() {
        postPowerSave();
        // Before SDL resumes the game's own stream, so only another app's
        // music counts here.
        if (audio != null && audio.isMusicActive()) {
            services.post(SERVICE, "audio", PlatformServices.object("otherAudio", true, "interrupted", false));
        } else {
            requestFocus();
        }
    }

    void onPause() {
        abandonFocus();
    }

    void onDestroy() {
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

    /**
     * Re-encodes an image (base64 in, base64 out), synchronously: the shim
     * decodes PNG itself but has no JPEG codec, and a shared level's maker
     * photo travels as a JPEG (UIKit's {@code jpegData}, as on iOS).
     */
    private static JSONObject convert(String base64, Bitmap.CompressFormat format, int quality) {
        byte[] bytes = Base64.decode(base64, Base64.NO_WRAP);
        Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (bitmap == null) return null;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        if (!bitmap.compress(format, quality, out)) return null;
        return PlatformServices.object("data", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP));
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
