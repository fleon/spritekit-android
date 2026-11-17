package PACKAGE_NAME;

import android.app.Activity;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.util.concurrent.ConcurrentLinkedQueue;

/**
 * The game's way to Google Play and the device: Play Billing, Play Games
 * Services (sign-in, achievements, leaderboards, Saved Games), Play In-App
 * Review, haptics, audio focus, battery saver and the status bar.
 *
 * <p>One door each way, both JSON in UTF-8 bytes, so the JNI stays two calls
 * wide however many services sit behind it:
 *
 * <ul>
 *   <li>Swift calls {@link #call} on SDL's thread with a name such as
 *       {@code games.submitScores} and its arguments. Anything slow is started
 *       here and answered later; the return value is only what is known at
 *       once.</li>
 *   <li>Answers and news go into a queue as events, and
 *       {@link MainActivity#nativePlatformEventsReady} flips a flag the frame
 *       loop reads; it then calls {@link #drainEvents} on its own thread. So
 *       nothing Java does ever runs Swift on a Java thread.</li>
 * </ul>
 *
 * <p>Bytes rather than {@code jstring}s because JNI's "modified UTF-8"
 * splits characters outside the BMP into surrogate halves — a player's name
 * with an emoji in it would come out mangled.
 *
 * <p>A game that sells nothing removes {@code billing} (the field, its
 * construction, its case and its lifecycle calls) and {@link PlayBilling}.
 */
final class PlatformServices {
    static final String TAG = "APP_NAME";

    private final ConcurrentLinkedQueue<JSONObject> events = new ConcurrentLinkedQueue<>();
    final PlayBilling billing;
    final PlayGamesServices games;
    final PlayReview review;
    final DeviceServices device;

    PlatformServices(Activity activity) {
        billing = new PlayBilling(activity, this);
        games = new PlayGamesServices(activity, this);
        review = new PlayReview(activity, this);
        device = new DeviceServices(activity, this);
    }

    /** Queues an event for the game and wakes the frame loop. */
    void post(String service, String event, JSONObject body) {
        try {
            JSONObject message = body != null ? body : new JSONObject();
            message.put("service", service);
            message.put("event", event);
            events.add(message);
        } catch (JSONException e) {
            Log.e(TAG, "could not post " + service + "." + event, e);
            return;
        }
        // The shell registers the native method as it starts and drains the
        // queue right after, so nothing posted before then is lost.
        if (MainActivity.nativePlatformRegistered) MainActivity.nativePlatformEventsReady();
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
            JSONObject result;
            switch (service) {
                case "billing": result = billing.call(method, arguments); break;
                case "games": result = games.call(method, arguments); break;
                case "review": result = review.call(method, arguments); break;
                case "device": result = device.call(method, arguments); break;
                default: result = null; Log.w(TAG, "no platform service " + name);
            }
            return result == null ? null : result.toString().getBytes(StandardCharsets.UTF_8);
        } catch (Exception e) {
            Log.e(TAG, "platform call " + name + " failed", e);
            return null;
        }
    }

    void onResume() {
        device.onResume();
        billing.onResume();
        games.onResume();
    }

    void onStop() {
        device.onStop();
    }

    void onDestroy() {
        billing.onDestroy();
        device.onDestroy();
    }

    static JSONObject object(Object... pairs) {
        JSONObject object = new JSONObject();
        try {
            for (int i = 0; i + 1 < pairs.length; i += 2) object.put((String) pairs[i], pairs[i + 1]);
        } catch (JSONException e) {
            Log.e(TAG, "bad event body", e);
        }
        return object;
    }
}
