package com.spritekit.platform;

import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentLinkedQueue;

/**
 * The game's way to Google Play and the device: the platform channel's Java
 * end, and the services behind it. {@link SpriteKitActivity} adds the
 * built-in ones ({@code device}, {@code games}, {@code review}); a game adds
 * the rest ({@code billing}, {@code notifications}, its own) in
 * {@link SpriteKitActivity#addServices}.
 *
 * <p>One door each way, both JSON in UTF-8 bytes, so the JNI stays two calls
 * wide however many services sit behind it:
 *
 * <ul>
 *   <li>Swift calls {@link #call} on SDL's thread with a name such as
 *       {@code games.submitScores} and its arguments. Anything slow is started
 *       here and answered later; the return value is only what is known at
 *       once.</li>
 *   <li>Answers and news go into a queue as events ({@link #post}), and
 *       {@link SpriteKitActivity#nativePlatformEventsReady} flips a flag the
 *       frame loop reads; it then calls {@link #drainEvents} on its own
 *       thread. So nothing Java does ever runs Swift on a Java thread.</li>
 * </ul>
 *
 * <p>Bytes rather than {@code jstring}s because JNI's "modified UTF-8"
 * splits characters outside the BMP into surrogate halves — a player's name
 * with an emoji in it would come out mangled.
 */
public final class PlatformServices {
    private static volatile String tag = "SpriteKit";

    /** The logcat tag every service logs under: the app's name once the activity has set it. */
    public static String tag() {
        return tag;
    }

    static void setTag(String newTag) {
        if (newTag != null && !newTag.isEmpty()) tag = newTag;
    }

    private final ConcurrentLinkedQueue<JSONObject> events = new ConcurrentLinkedQueue<>();
    private final Map<String, PlatformService> services = new LinkedHashMap<>();

    PlatformServices() {
    }

    /**
     * Puts {@code service} behind {@code name}, so Swift's
     * {@code name.method} calls reach it, in place of any service already
     * there. Lifecycle calls go to the services in the order they were added.
     * Called as the activity is created, before the game starts.
     */
    public void add(String name, PlatformService service) {
        services.put(name, service);
    }

    /** The service added under {@code name}, or null. */
    public PlatformService get(String name) {
        return services.get(name);
    }

    /** Queues an event for the game and wakes the frame loop. */
    public void post(String service, String event, JSONObject body) {
        try {
            JSONObject message = body != null ? body : new JSONObject();
            message.put("service", service);
            message.put("event", event);
            events.add(message);
        } catch (JSONException e) {
            Log.e(tag, "could not post " + service + "." + event, e);
            return;
        }
        // The shell registers the native method as it starts and drains the
        // queue right after, so nothing posted before then is lost.
        if (SpriteKitActivity.nativePlatformRegistered) SpriteKitActivity.nativePlatformEventsReady();
    }

    /** Everything queued since the last drain, as a JSON array, or null. */
    byte[] drainEvents() {
        if (events.isEmpty()) return null;
        JSONArray batch = new JSONArray();
        JSONObject next;
        while ((next = events.poll()) != null) batch.put(next);
        return batch.toString().getBytes(StandardCharsets.UTF_8);
    }

    /**
     * Runs {@code name} with {@code args} (a JSON object). Returns a JSON
     * object, or null when the call has nothing to say at once.
     */
    byte[] call(String name, byte[] args) {
        try {
            JSONObject arguments = args == null || args.length == 0
                ? new JSONObject()
                : new JSONObject(new String(args, StandardCharsets.UTF_8));
            int dot = name.indexOf('.');
            String service = dot < 0 ? name : name.substring(0, dot);
            String method = dot < 0 ? "" : name.substring(dot + 1);
            PlatformService handler = services.get(service);
            JSONObject result = null;
            if (handler != null) {
                result = handler.call(method, arguments);
            } else {
                Log.w(tag, "no platform service " + name);
            }
            return result == null ? null : result.toString().getBytes(StandardCharsets.UTF_8);
        } catch (Exception e) {
            Log.e(tag, "platform call " + name + " failed", e);
            return null;
        }
    }

    void onResume() {
        for (PlatformService service : services.values()) service.onResume();
    }

    void onStop() {
        for (PlatformService service : services.values()) service.onStop();
    }

    void onDestroy() {
        for (PlatformService service : services.values()) service.onDestroy();
    }

    /** A JSON object of key, value pairs: {@code object("ok", true, "code", 3)}. */
    public static JSONObject object(Object... pairs) {
        JSONObject object = new JSONObject();
        try {
            for (int i = 0; i + 1 < pairs.length; i += 2) object.put((String) pairs[i], pairs[i + 1]);
        } catch (JSONException e) {
            Log.e(tag, "bad event body", e);
        }
        return object;
    }
}
