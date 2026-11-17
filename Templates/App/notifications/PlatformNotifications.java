package PACKAGE_NAME;

import android.Manifest;
import android.app.Activity;
import android.app.AlarmManager;
import android.app.Application;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.service.notification.StatusBarNotification;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.TimeZone;

/**
 * Local notifications for the game's {@code UNUserNotificationCenter}
 * (spritekit-android's {@code PlatformShim/UserNotifications.swift}): asking
 * to notify, scheduling, what's pending, and the player tapping one.
 *
 * <p>Calls ({@code notifications.*}), each answered at once:
 * <ul>
 *   <li>{@code start} → {@code {status}}; Swift's center is listening, so taps
 *       held until now are posted.</li>
 *   <li>{@code authorization} → {@code {status}}: {@code notDetermined},
 *       {@code denied} or {@code authorized}.</li>
 *   <li>{@code request {options, request}} → {@code {status, granted}}, or
 *       {@code {status}} alone while the system's prompt is up; a
 *       {@code status} event with the same {@code request} follows.</li>
 *   <li>{@code schedule {request}} → {@code {ok}};
 *       {@code remove {identifiers}}; {@code removeAll};
 *       {@code pending} → {@code {requests}};
 *       {@code delivered} → {@code {notifications: [{request, date}]}};
 *       {@code removeDelivered {identifiers}}; {@code removeAllDelivered};
 *       {@code badge {count}} (a no-op: Android's launchers count for
 *       themselves); {@code present {request, options}}.</li>
 * </ul>
 *
 * <p>Events: {@code status {status, granted?, request?}},
 * {@code willPresent {request, date}} (one fired while the game is in
 * front: Swift asks its delegate and answers with {@code present}, as iOS
 * shows nothing in front unless the delegate says so),
 * {@code opened {request, date, action}} (the player tapped one).
 *
 * <p>A request is {@code {identifier, content: {title, subtitle, body, sound?,
 * badge?, threadIdentifier, categoryIdentifier, userInfo}, trigger?}}; a
 * trigger {@code {type: "calendar", repeats, year?, month?, day?, hour?,
 * minute?, second?, weekday?, timeZone?, fireAt?}} or {@code {type:
 * "interval", seconds, repeats, fireAt?}}, {@code fireAt} in milliseconds
 * since 1970. Requests are kept in SharedPreferences, so {@code pending},
 * repeats and rescheduling after a reboot ({@link NotificationBootReceiver})
 * all read the same list.
 *
 * <p><b>Alarms.</b> {@code setAndAllowWhileIdle}: delivered in Doze, and
 * with no permission to ask for. Exact alarms need
 * {@code SCHEDULE_EXACT_ALARM} from Android 12, which is off by default from
 * Android 14 and a Play policy declaration besides; a reminder doesn't
 * need to the minute. Android may deliver an inexact alarm up to an hour
 * late. Where exact alarms are allowed anyway (before Android 12, or an app
 * that declares and holds the permission) they're used.
 *
 * <p><b>Permission.</b> {@code POST_NOTIFICATIONS} from Android 13, asked
 * through the activity; its answer is read as the activity resumes after
 * the prompt, so the activity needs no forwarding of its own. Before 13
 * notifications are on unless the player turned them off: authorized, or
 * denied.
 *
 * <p>Wiring: construct it in {@code PlatformServices}' constructor and
 * dispatch {@code "notifications"} calls to {@link #call}; it follows the
 * activity's lifecycle itself.
 */
final class PlatformNotifications {
    static final String SERVICE = "notifications";

    static final String ACTION_FIRE = "platformNotifications.FIRE";
    static final String EXTRA_IDENTIFIER = "platformNotifications.identifier";
    /** On the launch intent a tap opens: {@code {request, date}}. */
    static final String EXTRA_TAP = "platformNotifications.tap";
    /** Every notification this posts carries this ID and its request's identifier as tag. */
    static final int NOTIFICATION_ID = 0x554E;

    private static final String PREFS = "platformNotifications";
    private static final String KEY_REQUESTS = "requests";
    private static final String KEY_ASKED = "askedPermission";
    private static final String CHANNEL_ID = "notifications";
    private static final String SMALL_ICON = "ic_stat_notification";
    private static final String SILENT_GROUP = "platformNotifications.silent";
    private static final int PERMISSION_REQUEST = 0x554E;
    /** How long to wait for the prompt to cover the activity before reading the answer anyway. */
    private static final long PROMPT_GRACE_MS = 1500;
    /** How far ahead a calendar trigger is looked for (past one leap day). */
    private static final int SEARCH_DAYS = 366 * 9;

    private static final Object STORE = new Object();
    /** The running game's, for fired notifications to ask Swift about. */
    private static volatile PlatformNotifications live;
    /** Swift's center has started: taps go straight to it. */
    private static volatile boolean swiftListening;
    private static final List<JSONObject> heldTaps = new ArrayList<>();

    private final Activity activity;
    private final PlatformServices services;
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile boolean resumed;
    private volatile String lastStatus;
    /** The {@code request} awaiting the prompt's answer, 0 for none. */
    private int awaitingPrompt;
    private boolean pausedSincePrompt;

    private final Application.ActivityLifecycleCallbacks lifecycle = new Application.ActivityLifecycleCallbacks() {
        @Override public void onActivityResumed(Activity resumedActivity) {
            if (resumedActivity == activity) onResume();
        }
        @Override public void onActivityPaused(Activity pausedActivity) {
            if (pausedActivity == activity) onPause();
        }
        @Override public void onActivityDestroyed(Activity destroyedActivity) {
            if (destroyedActivity == activity) onDestroy();
        }
        @Override public void onActivityCreated(Activity created, Bundle state) {}
        @Override public void onActivityStarted(Activity started) {}
        @Override public void onActivityStopped(Activity stopped) {}
        @Override public void onActivitySaveInstanceState(Activity saving, Bundle state) {}
    };

    PlatformNotifications(Activity activity, PlatformServices services) {
        this.activity = activity;
        this.services = services;
        live = this;
        activity.getApplication().registerActivityLifecycleCallbacks(lifecycle);
        // Alarms don't survive a force stop; set them again.
        rearmAll(activity, false);
    }

    JSONObject call(String method, JSONObject args) throws JSONException {
        switch (method) {
            case "start":
                start();
                return statusAnswer();
            case "authorization":
                return statusAnswer();
            case "request":
                return requestPermission(args.optInt("request"));
            case "schedule":
                return schedule(activity, args.optJSONObject("request"));
            case "remove":
                remove(activity, strings(args.optJSONArray("identifiers")));
                return null;
            case "removeAll":
                remove(activity, null);
                return null;
            case "pending":
                synchronized (STORE) {
                    return PlatformServices.object("requests", load(activity));
                }
            case "delivered":
                return PlatformServices.object("notifications", delivered());
            case "removeDelivered":
                for (String identifier : strings(args.optJSONArray("identifiers"))) {
                    manager(activity).cancel(identifier, NOTIFICATION_ID);
                }
                return null;
            case "removeAllDelivered":
                removeAllDelivered();
                return null;
            case "badge":
                return null;
            case "present":
                present(args.optJSONObject("request"), strings(args.optJSONArray("options")));
                return null;
            default:
                Log.w(PlatformServices.TAG, "no notifications." + method);
                return null;
        }
    }

    // MARK: Lifecycle

    private void onResume() {
        resumed = true;
        if (awaitingPrompt != 0 && pausedSincePrompt) answerPrompt();
        takeTap(activity.getIntent());
        String status = status(activity);
        if (lastStatus != null && !status.equals(lastStatus)) {
            services.post(SERVICE, "status", PlatformServices.object("status", status));
        }
        lastStatus = status;
    }

    private void onPause() {
        resumed = false;
        if (awaitingPrompt != 0) pausedSincePrompt = true;
    }

    private void onDestroy() {
        activity.getApplication().unregisterActivityLifecycleCallbacks(lifecycle);
        if (live == this) live = null;
    }

    private void start() {
        List<JSONObject> taps;
        synchronized (heldTaps) {
            swiftListening = true;
            taps = new ArrayList<>(heldTaps);
            heldTaps.clear();
        }
        for (JSONObject tap : taps) services.post(SERVICE, "opened", tap);
    }

    /** A launch or new intent from a tapped notification, taken once. */
    private void takeTap(Intent intent) {
        String tap = intent != null ? intent.getStringExtra(EXTRA_TAP) : null;
        if (tap == null) return;
        intent.removeExtra(EXTRA_TAP);
        JSONObject body;
        try {
            body = new JSONObject(tap);
            body.put("action", "default");
        } catch (JSONException e) {
            Log.e(PlatformServices.TAG, "unreadable notification tap", e);
            return;
        }
        synchronized (heldTaps) {
            if (!swiftListening) {
                heldTaps.add(body);
                return;
            }
        }
        services.post(SERVICE, "opened", body);
    }

    // MARK: Permission

    private JSONObject statusAnswer() {
        String status = status(activity);
        lastStatus = status;
        return PlatformServices.object("status", status);
    }

    static String status(Context context) {
        boolean enabled = manager(context).areNotificationsEnabled();
        if (Build.VERSION.SDK_INT >= 33) {
            boolean granted = context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED;
            if (granted && enabled) return "authorized";
            if (!granted && !prefs(context).getBoolean(KEY_ASKED, false)) return "notDetermined";
            return "denied";
        }
        return enabled ? "authorized" : "denied";
    }

    private JSONObject requestPermission(int request) {
        String status = status(activity);
        boolean asked = prefs(activity).getBoolean(KEY_ASKED, false);
        boolean canPrompt = Build.VERSION.SDK_INT >= 33 && !"authorized".equals(status)
            && (!asked || activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS));
        if (!canPrompt) {
            return PlatformServices.object("status", status, "granted", "authorized".equals(status));
        }
        prefs(activity).edit().putBoolean(KEY_ASKED, true).apply();
        main.post(() -> {
            awaitingPrompt = request;
            pausedSincePrompt = false;
            activity.requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, PERMISSION_REQUEST);
            // Should the system answer without covering the activity, read
            // the answer anyway rather than leave Swift waiting.
            main.postDelayed(() -> {
                if (awaitingPrompt == request && !pausedSincePrompt) answerPrompt();
            }, PROMPT_GRACE_MS);
        });
        return PlatformServices.object("status", status);
    }

    private void answerPrompt() {
        int request = awaitingPrompt;
        awaitingPrompt = 0;
        pausedSincePrompt = false;
        String status = status(activity);
        lastStatus = status;
        services.post(SERVICE, "status", PlatformServices.object("status", status, "granted", "authorized".equals(status), "request", request));
    }

    // MARK: Scheduling

    static JSONObject schedule(Context context, JSONObject request) throws JSONException {
        if (request == null) return PlatformServices.object("ok", false);
        String identifier = request.optString("identifier");
        JSONObject trigger = request.optJSONObject("trigger");
        cancelAlarm(context, identifier);
        if (trigger == null) {
            // No trigger: now.
            synchronized (STORE) {
                save(context, without(load(context), identifier));
            }
            deliver(context, request);
            return PlatformServices.object("ok", true);
        }
        long now = System.currentTimeMillis();
        long fireAt = trigger.optLong("fireAt", 0);
        if (fireAt <= now) fireAt = nextFire(trigger, now);
        synchronized (STORE) {
            JSONArray requests = without(load(context), identifier);
            if (fireAt > 0) {
                trigger.put("fireAt", fireAt);
                requests.put(request);
            }
            save(context, requests);
        }
        // A date already past never fires, as on iOS.
        if (fireAt > 0) arm(context, identifier, fireAt);
        return PlatformServices.object("ok", true);
    }

    /** {@code identifiers} null removes every one. */
    static void remove(Context context, List<String> identifiers) {
        synchronized (STORE) {
            JSONArray requests = load(context);
            JSONArray kept = new JSONArray();
            for (int i = 0; i < requests.length(); i++) {
                JSONObject request = requests.optJSONObject(i);
                if (request == null) continue;
                String identifier = request.optString("identifier");
                if (identifiers == null || identifiers.contains(identifier)) {
                    cancelAlarm(context, identifier);
                } else {
                    kept.put(request);
                }
            }
            save(context, kept);
        }
    }

    /** An alarm went off ({@link NotificationReceiver}). */
    static void fired(Context context, String identifier) {
        JSONObject request = null;
        synchronized (STORE) {
            JSONArray requests = load(context);
            for (int i = 0; i < requests.length(); i++) {
                JSONObject candidate = requests.optJSONObject(i);
                if (candidate != null && identifier.equals(candidate.optString("identifier"))) request = candidate;
            }
            if (request == null) return;
            JSONObject trigger = request.optJSONObject("trigger");
            JSONArray rest = without(requests, identifier);
            if (trigger != null && trigger.optBoolean("repeats")) {
                long now = System.currentTimeMillis();
                long next = nextFire(trigger, Math.max(now, trigger.optLong("fireAt", now)));
                if (next > 0) {
                    try {
                        trigger.put("fireAt", next);
                    } catch (JSONException e) {
                        Log.e(PlatformServices.TAG, "could not re-arm " + identifier, e);
                    }
                    rest.put(request);
                    arm(context, identifier, next);
                }
            }
            save(context, rest);
        }
        deliver(context, request);
    }

    /**
     * Sets every pending request's alarm again: after a reboot or an update
     * (which clear them), or as the app starts. When the clock or time zone
     * changed, calendar triggers without a time zone of their own are worked
     * out again in the device's new local time, as iOS's float with it.
     */
    static void rearmAll(Context context, boolean clockChanged) {
        long now = System.currentTimeMillis();
        synchronized (STORE) {
            JSONArray requests = load(context);
            for (int i = 0; i < requests.length(); i++) {
                JSONObject request = requests.optJSONObject(i);
                JSONObject trigger = request != null ? request.optJSONObject("trigger") : null;
                if (trigger == null) continue;
                long fireAt = trigger.optLong("fireAt", 0);
                boolean floating = "calendar".equals(trigger.optString("type")) && !trigger.has("timeZone");
                if (fireAt <= 0 || (clockChanged && floating)) {
                    long next = nextFire(trigger, now);
                    if (next > 0) fireAt = next;
                }
                if (fireAt <= 0) continue;
                try {
                    trigger.put("fireAt", fireAt);
                } catch (JSONException e) {
                    continue;
                }
                // One missed while the phone was off fires now.
                arm(context, request.optString("identifier"), fireAt);
            }
            save(context, requests);
        }
    }

    // MARK: Next fire

    static long nextFire(JSONObject trigger, long after) {
        if ("interval".equals(trigger.optString("type"))) {
            double seconds = trigger.optDouble("seconds", 0);
            return seconds > 0 ? after + (long) (seconds * 1000) : -1;
        }
        return nextCalendarFire(trigger, after);
    }

    private static final String[] UNITS = {"year", "month", "day", "hour", "minute", "second"};

    /**
     * The first time after {@code after} matching the trigger's components, in
     * its time zone or the device's: units left out below the smallest given
     * are zero, those above it any value, as {@code UNCalendarNotificationTrigger}
     * matches. -1 when nothing matches any more. A day the month lacks (the
     * 31st, 29 February) waits for a month that has it, where iOS moves on to
     * the next day; Swift's {@code fireAt} sets the first alarm, so only a
     * repeat of such a trigger can differ.
     */
    static long nextCalendarFire(JSONObject trigger, long after) {
        TimeZone zone = trigger.has("timeZone") ? TimeZone.getTimeZone(trigger.optString("timeZone")) : TimeZone.getDefault();
        int smallest = -1;
        for (int i = 0; i < UNITS.length; i++) {
            if (trigger.has(UNITS[i])) smallest = i;
        }
        if (trigger.has("weekday")) smallest = Math.max(smallest, 2);
        if (smallest < 0) return -1;
        int[] hours = candidates(trigger, "hour", smallest < 3, 24);
        int[] minutes = candidates(trigger, "minute", smallest < 4, 60);
        int[] seconds = candidates(trigger, "second", smallest < 5, 60);

        Calendar day = Calendar.getInstance(zone);
        day.setTimeInMillis(after);
        day.set(Calendar.HOUR_OF_DAY, 0);
        day.set(Calendar.MINUTE, 0);
        day.set(Calendar.SECOND, 0);
        day.set(Calendar.MILLISECOND, 0);
        if (trigger.has("year") && trigger.optInt("year") < day.get(Calendar.YEAR)) return -1;
        Calendar time = Calendar.getInstance(zone);
        for (int d = 0; d < SEARCH_DAYS; d++, day.add(Calendar.DAY_OF_MONTH, 1)) {
            if (!matches(trigger, "year", day.get(Calendar.YEAR))
                || !matches(trigger, "month", day.get(Calendar.MONTH) + 1)
                || !matches(trigger, "day", day.get(Calendar.DAY_OF_MONTH))
                || !matches(trigger, "weekday", day.get(Calendar.DAY_OF_WEEK))) continue;
            for (int hour : hours) {
                for (int minute : minutes) {
                    for (int second : seconds) {
                        time.setTimeInMillis(day.getTimeInMillis());
                        time.set(Calendar.HOUR_OF_DAY, hour);
                        time.set(Calendar.MINUTE, minute);
                        time.set(Calendar.SECOND, second);
                        if (time.getTimeInMillis() > after) return time.getTimeInMillis();
                    }
                }
            }
        }
        return -1;
    }

    /** The unit's value if given; zero if it's below the smallest given; else every value. */
    private static int[] candidates(JSONObject trigger, String unit, boolean zero, int count) {
        if (trigger.has(unit)) return new int[] {trigger.optInt(unit)};
        if (zero) return new int[] {0};
        int[] all = new int[count];
        for (int i = 0; i < count; i++) all[i] = i;
        return all;
    }

    private static boolean matches(JSONObject trigger, String unit, int value) {
        return !trigger.has(unit) || trigger.optInt(unit) == value;
    }

    // MARK: Alarms

    private static void arm(Context context, String identifier, long fireAt) {
        AlarmManager alarms = (AlarmManager) context.getSystemService(Context.ALARM_SERVICE);
        if (alarms == null) return;
        PendingIntent intent = alarmIntent(context, identifier);
        if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, intent);
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, intent);
        }
    }

    private static void cancelAlarm(Context context, String identifier) {
        AlarmManager alarms = (AlarmManager) context.getSystemService(Context.ALARM_SERVICE);
        if (alarms != null) alarms.cancel(alarmIntent(context, identifier));
    }

    private static PendingIntent alarmIntent(Context context, String identifier) {
        Intent intent = new Intent(context, NotificationReceiver.class)
            .setAction(ACTION_FIRE)
            // One alarm per identifier: intents differing only in extras are the same alarm.
            .setData(Uri.fromParts("notification", identifier, null))
            .putExtra(EXTRA_IDENTIFIER, identifier);
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    // MARK: Showing

    /** Fired: asks Swift while the game is in front and listening, shows it otherwise. */
    private static void deliver(Context context, JSONObject request) {
        PlatformNotifications game = live;
        long now = System.currentTimeMillis();
        if (game != null && game.resumed && swiftListening) {
            game.services.post(SERVICE, "willPresent", PlatformServices.object("request", request, "date", now));
            return;
        }
        JSONObject content = request.optJSONObject("content");
        show(context, request, now, content != null && content.has("sound"));
    }

    private void present(JSONObject request, List<String> options) {
        if (request == null) return;
        if (!options.contains("banner") && !options.contains("list") && !options.contains("alert")) return;
        JSONObject content = request.optJSONObject("content");
        boolean sound = options.contains("sound") && content != null && content.has("sound");
        show(activity, request, System.currentTimeMillis(), sound);
    }

    @SuppressWarnings("deprecation") // the channel-less builder, before Android 8
    static void show(Context context, JSONObject request, long date, boolean sound) {
        NotificationManager manager = manager(context);
        String identifier = request.optString("identifier");
        JSONObject content = request.optJSONObject("content");
        if (content == null) content = new JSONObject();
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= 26) {
            ensureChannel(context, manager);
            builder = new Notification.Builder(context, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(context);
            if (sound) builder.setDefaults(Notification.DEFAULT_SOUND);
        }
        String body = content.optString("body");
        builder.setSmallIcon(smallIcon(context))
            .setContentTitle(content.optString("title"))
            .setContentText(body)
            .setStyle(new Notification.BigTextStyle().bigText(body))
            .setWhen(date)
            .setShowWhen(true)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(tapIntent(context, request, date));
        String subtitle = content.optString("subtitle");
        if (!subtitle.isEmpty()) builder.setSubText(subtitle);
        if (content.has("badge")) builder.setNumber(content.optInt("badge"));
        String thread = content.optString("threadIdentifier");
        if (!thread.isEmpty()) builder.setGroup(thread);
        if (!sound && Build.VERSION.SDK_INT >= 26) {
            // The channel's sound is fixed; a child that defers alerting to
            // its group's summary (there is none) makes no sound.
            if (thread.isEmpty()) builder.setGroup(SILENT_GROUP);
            builder.setGroupAlertBehavior(Notification.GROUP_ALERT_SUMMARY);
        }
        Bundle extras = new Bundle();
        extras.putString(EXTRA_TAP, tap(request, date).toString());
        builder.addExtras(extras);
        manager.notify(identifier, NOTIFICATION_ID, builder.build());
    }

    private static PendingIntent tapIntent(Context context, JSONObject request, long date) {
        Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (launch == null) launch = new Intent();
        // To the running game (onNewIntent), not just its task to the front.
        launch.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        launch.putExtra(EXTRA_TAP, tap(request, date).toString());
        int code = request.optString("identifier").hashCode();
        return PendingIntent.getActivity(context, code, launch, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static JSONObject tap(JSONObject request, long date) {
        return PlatformServices.object("request", request, "date", date);
    }

    /** The app's name for its one channel, which is what the system's settings list. */
    private static void ensureChannel(Context context, NotificationManager manager) {
        if (Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL_ID) != null) return;
        CharSequence name = context.getApplicationInfo().loadLabel(context.getPackageManager());
        manager.createNotificationChannel(new NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_DEFAULT));
    }

    /** {@code res/drawable/ic_stat_notification}, or the app's icon without one. */
    private static int smallIcon(Context context) {
        int icon = context.getResources().getIdentifier(SMALL_ICON, "drawable", context.getPackageName());
        return icon != 0 ? icon : context.getApplicationInfo().icon;
    }

    private JSONArray delivered() {
        JSONArray items = new JSONArray();
        for (StatusBarNotification posted : manager(activity).getActiveNotifications()) {
            if (posted.getId() != NOTIFICATION_ID || posted.getTag() == null) continue;
            String tap = posted.getNotification().extras.getString(EXTRA_TAP);
            if (tap == null) continue;
            try {
                items.put(new JSONObject(tap));
            } catch (JSONException e) {
                Log.w(PlatformServices.TAG, "unreadable delivered notification " + posted.getTag());
            }
        }
        return items;
    }

    private void removeAllDelivered() {
        NotificationManager manager = manager(activity);
        for (StatusBarNotification posted : manager.getActiveNotifications()) {
            if (posted.getId() == NOTIFICATION_ID && posted.getTag() != null) manager.cancel(posted.getTag(), NOTIFICATION_ID);
        }
    }

    // MARK: Store

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static NotificationManager manager(Context context) {
        return (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
    }

    private static JSONArray load(Context context) {
        try {
            return new JSONArray(prefs(context).getString(KEY_REQUESTS, "[]"));
        } catch (JSONException e) {
            Log.e(PlatformServices.TAG, "unreadable scheduled notifications", e);
            return new JSONArray();
        }
    }

    private static void save(Context context, JSONArray requests) {
        prefs(context).edit().putString(KEY_REQUESTS, requests.toString()).apply();
    }

    private static JSONArray without(JSONArray requests, String identifier) {
        JSONArray kept = new JSONArray();
        for (int i = 0; i < requests.length(); i++) {
            JSONObject request = requests.optJSONObject(i);
            if (request != null && !identifier.equals(request.optString("identifier"))) kept.put(request);
        }
        return kept;
    }

    private static List<String> strings(JSONArray array) {
        List<String> strings = new ArrayList<>();
        if (array == null) return strings;
        for (int i = 0; i < array.length(); i++) strings.add(array.optString(i));
        return strings;
    }
}
