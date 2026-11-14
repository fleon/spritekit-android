package com.fleon.switchlings;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.net.Uri;
import android.util.Base64;
import android.util.Log;

import com.google.android.gms.common.ConnectionResult;
import com.google.android.gms.common.GoogleApiAvailability;
import com.google.android.gms.common.images.ImageManager;
import com.google.android.gms.games.AchievementsClient;
import com.google.android.gms.games.PlayGames;
import com.google.android.gms.games.PlayGamesSdk;
import com.google.android.gms.games.SnapshotsClient;
import com.google.android.gms.games.achievement.Achievement;
import com.google.android.gms.games.achievement.AchievementBuffer;
import com.google.android.gms.games.snapshot.Snapshot;
import com.google.android.gms.games.snapshot.SnapshotMetadataChange;
import com.google.android.gms.tasks.Task;
import com.google.android.gms.tasks.Tasks;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Play Games Services v2: signing in (silently, at launch: v2 signs a
 * returning player in by itself and the game never waits on it), the
 * achievements, the player's name and picture for a shared level's credit,
 * and Saved Games, which carry the game's synced saved data between the
 * player's devices.
 *
 * <p>Everything is off when the build has no Play Games project ID
 * ({@code -Pswitchlings.playGamesAppId=…}): sign-in answers "no" at once, so
 * the launch splash never waits for a service that cannot answer.
 *
 * <p>The title's Play Games button ({@code available}, {@code showAchievements})
 * stands where Game Center's does on Apple: it shows only where Play Games can
 * run, and a tap signs a signed-out player in before opening the
 * achievements, as Game Center's button leads to its sign-in.
 *
 * <p>Events, under {@code games}: {@code signIn}, {@code achievements},
 * {@code reported}, {@code player}, {@code snapshotOpened},
 * {@code snapshotCommitted}.
 */
final class PlayGamesServices {
    private static final String SERVICE = "games";
    private static final int DASHBOARD_REQUEST = 7301;
    /** How often a conflict is resolved before an open gives up. */
    private static final int CONFLICT_RETRIES = 5;

    private final Activity activity;
    private final PlatformServices services;
    private final boolean configured;
    private boolean signedIn;
    private int nextHandle = 1;
    private final Map<Integer, Snapshot> openSnapshots = new HashMap<>();

    PlayGamesServices(Activity activity, PlatformServices services) {
        this.activity = activity;
        this.services = services;
        String id = activity.getString(R.string.game_services_project_id);
        configured = id != null && !id.isEmpty();
        if (configured) PlayGamesSdk.initialize(activity);
    }

    JSONObject call(String method, JSONObject args) throws JSONException {
        switch (method) {
            case "available":
                return PlatformServices.object("available", isAvailable());
            case "start":
                activity.runOnUiThread(() -> checkSignIn(false));
                return PlatformServices.object("configured", configured);
            case "signIn":
                activity.runOnUiThread(() -> checkSignIn(true));
                return null;
            case "loadAchievements":
                activity.runOnUiThread(this::loadAchievements);
                return null;
            case "report": {
                JSONArray items = args.getJSONArray("items");
                int request = args.optInt("request");
                activity.runOnUiThread(() -> report(items, request));
                return null;
            }
            case "showAchievements":
                activity.runOnUiThread(this::showAchievements);
                return null;
            case "player":
                activity.runOnUiThread(this::loadPlayer);
                return null;
            case "openSnapshot": {
                String name = args.getString("name");
                int request = args.optInt("request");
                activity.runOnUiThread(() -> openSnapshot(name, request, 0));
                return null;
            }
            case "commitSnapshot": {
                int handle = args.getInt("handle");
                byte[] data = Base64.decode(args.getString("data"), Base64.NO_WRAP);
                String description = args.optString("description", "");
                activity.runOnUiThread(() -> commitSnapshot(handle, data, description));
                return null;
            }
            case "discardSnapshot": {
                int handle = args.getInt("handle");
                activity.runOnUiThread(() -> discardSnapshot(handle));
                return null;
            }
            default:
                Log.w(PlatformServices.TAG, "no games." + method);
                return null;
        }
    }

    void onResume() {
        // A player who signed in from Play Games' own app meanwhile.
        if (configured && !signedIn) checkSignIn(false);
    }

    /**
     * Whether Play Games can run here: the build names a project, and Google
     * Play services are on the device and up to date. Without them the title
     * leaves its Play Games button out.
     */
    private boolean isAvailable() {
        if (!configured) return false;
        int status = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity);
        return status == ConnectionResult.SUCCESS;
    }

    private void checkSignIn(boolean ask) {
        checkSignIn(ask, null);
    }

    /** Signs in (asking the player when {@code ask}), then runs {@code then} if that worked. */
    private void checkSignIn(boolean ask, Runnable then) {
        if (!configured) {
            services.post(SERVICE, "signIn", PlatformServices.object("signedIn", false, "configured", false));
            return;
        }
        Task<com.google.android.gms.games.AuthenticationResult> task = ask
            ? PlayGames.getGamesSignInClient(activity).signIn()
            : PlayGames.getGamesSignInClient(activity).isAuthenticated();
        task.addOnCompleteListener(done -> {
            boolean authenticated = done.isSuccessful() && done.getResult().isAuthenticated();
            if (!done.isSuccessful()) Log.w(PlatformServices.TAG, "Play Games sign-in failed", done.getException());
            signedIn = authenticated;
            services.post(SERVICE, "signIn", PlatformServices.object("signedIn", authenticated, "configured", true));
            if (authenticated && then != null) then.run();
        });
    }

    private void loadAchievements() {
        if (!signedIn) {
            services.post(SERVICE, "achievements", PlatformServices.object("ok", false));
            return;
        }
        PlayGames.getAchievementsClient(activity).load(false).addOnCompleteListener(done -> {
            JSONObject body = PlatformServices.object("ok", done.isSuccessful());
            if (done.isSuccessful()) {
                AchievementBuffer buffer = done.getResult().get();
                JSONArray items = new JSONArray();
                try {
                    for (Achievement achievement : buffer) {
                        boolean incremental = achievement.getType() == Achievement.TYPE_INCREMENTAL;
                        items.put(PlatformServices.object(
                            "id", achievement.getAchievementId(),
                            "unlocked", achievement.getState() == Achievement.STATE_UNLOCKED,
                            "currentSteps", incremental ? achievement.getCurrentSteps() : 0,
                            "totalSteps", incremental ? achievement.getTotalSteps() : 0));
                    }
                } finally {
                    if (buffer != null) buffer.release();
                }
                put(body, "items", items);
            } else {
                Log.w(PlatformServices.TAG, "could not load achievements", done.getException());
            }
            services.post(SERVICE, "achievements", body);
        });
    }

    /** Unlocks or sets the steps of each item: {@code {id, unlock}} or {@code {id, steps}}. */
    private void report(JSONArray items, int request) {
        if (!signedIn) {
            services.post(SERVICE, "reported", PlatformServices.object("request", request, "ok", false));
            return;
        }
        AchievementsClient achievements = PlayGames.getAchievementsClient(activity);
        List<Task<?>> tasks = new ArrayList<>();
        for (int i = 0; i < items.length(); i++) {
            JSONObject item = items.optJSONObject(i);
            if (item == null) continue;
            String id = item.optString("id");
            if (item.optBoolean("unlock")) {
                tasks.add(achievements.unlockImmediate(id));
            } else if (item.has("steps")) {
                tasks.add(achievements.setStepsImmediate(id, item.optInt("steps")));
            }
        }
        Tasks.whenAll(tasks).addOnCompleteListener(done -> {
            if (!done.isSuccessful()) Log.w(PlatformServices.TAG, "achievements did not all arrive", done.getException());
            services.post(SERVICE, "reported", PlatformServices.object("request", request, "ok", done.isSuccessful()));
        });
    }

    /**
     * Play Games' achievements over the game. A signed-out player is asked to
     * sign in first, and the achievements open once they have; turned down,
     * nothing opens.
     */
    private void showAchievements() {
        if (!configured) return;
        if (!signedIn) {
            Log.i(PlatformServices.TAG, "Play Games: signing in before the achievements");
            checkSignIn(true, this::showAchievements);
            return;
        }
        Log.i(PlatformServices.TAG, "Play Games: opening the achievements");
        PlayGames.getAchievementsClient(activity).getAchievementsIntent()
            .addOnSuccessListener(intent -> activity.startActivityForResult(intent, DASHBOARD_REQUEST))
            .addOnFailureListener(error -> Log.w(PlatformServices.TAG, "could not open achievements", error));
    }

    /** The signed-in player's name and picture (a PNG, base64), for a shared level's credit. */
    private void loadPlayer() {
        if (!signedIn) {
            services.post(SERVICE, "player", PlatformServices.object("ok", false));
            return;
        }
        PlayGames.getPlayersClient(activity).getCurrentPlayer().addOnCompleteListener(done -> {
            if (!done.isSuccessful() || done.getResult() == null) {
                services.post(SERVICE, "player", PlatformServices.object("ok", false));
                return;
            }
            String name = done.getResult().getDisplayName();
            Uri image = done.getResult().hasHiResImage()
                ? done.getResult().getHiResImageUri()
                : done.getResult().getIconImageUri();
            if (image == null) {
                services.post(SERVICE, "player", PlatformServices.object("ok", true, "name", name));
                return;
            }
            ImageManager.create(activity).loadImage((uri, drawable, isRequestedDrawable) -> {
                JSONObject body = PlatformServices.object("ok", true, "name", name);
                byte[] png = png(drawable);
                if (png != null) put(body, "photo", Base64.encodeToString(png, Base64.NO_WRAP));
                services.post(SERVICE, "player", body);
            }, image);
        });
    }

    private static byte[] png(Drawable drawable) {
        if (drawable == null) return null;
        Bitmap bitmap;
        if (drawable instanceof BitmapDrawable && ((BitmapDrawable) drawable).getBitmap() != null) {
            bitmap = ((BitmapDrawable) drawable).getBitmap();
        } else {
            int width = Math.max(1, drawable.getIntrinsicWidth());
            int height = Math.max(1, drawable.getIntrinsicHeight());
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);
            drawable.setBounds(0, 0, width, height);
            drawable.draw(canvas);
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        return out.toByteArray();
    }

    /**
     * Opens the named snapshot (creating it the first time) and hands its
     * bytes to the game, which merges and answers with a commit or a
     * discard. A conflict — two devices wrote without seeing each other —
     * is resolved to Play's copy: the game's merge keeps every device's own
     * changes in its saved data, so the next commit puts this device's back.
     */
    private void openSnapshot(String name, int request, int attempt) {
        if (!signedIn) {
            services.post(SERVICE, "snapshotOpened", PlatformServices.object("request", request, "ok", false));
            return;
        }
        SnapshotsClient snapshots = PlayGames.getSnapshotsClient(activity);
        snapshots.open(name, true, SnapshotsClient.RESOLUTION_POLICY_MANUAL).addOnCompleteListener(done ->
            handleOpen(snapshots, done, name, request, attempt));
    }

    private void handleOpen(SnapshotsClient snapshots, Task<SnapshotsClient.DataOrConflict<Snapshot>> done,
                            String name, int request, int attempt) {
        if (!done.isSuccessful()) {
            Log.w(PlatformServices.TAG, "could not open saved game", done.getException());
            services.post(SERVICE, "snapshotOpened", PlatformServices.object("request", request, "ok", false));
            return;
        }
        SnapshotsClient.DataOrConflict<Snapshot> result = done.getResult();
        if (result.isConflict()) {
            if (attempt >= CONFLICT_RETRIES) {
                services.post(SERVICE, "snapshotOpened", PlatformServices.object("request", request, "ok", false));
                return;
            }
            SnapshotsClient.SnapshotConflict conflict = result.getConflict();
            snapshots.resolveConflict(conflict.getConflictId(), conflict.getSnapshot())
                .addOnCompleteListener(resolved -> handleOpen(snapshots, resolved, name, request, attempt + 1));
            return;
        }
        Snapshot snapshot = result.getData();
        int handle = nextHandle++;
        openSnapshots.put(handle, snapshot);
        JSONObject body = PlatformServices.object("request", request, "ok", true, "handle", handle);
        try {
            byte[] data = snapshot.getSnapshotContents().readFully();
            put(body, "data", Base64.encodeToString(data, Base64.NO_WRAP));
        } catch (Exception e) {
            Log.w(PlatformServices.TAG, "could not read saved game", e);
        }
        services.post(SERVICE, "snapshotOpened", body);
    }

    private void commitSnapshot(int handle, byte[] data, String description) {
        Snapshot snapshot = openSnapshots.remove(handle);
        if (snapshot == null) {
            services.post(SERVICE, "snapshotCommitted", PlatformServices.object("handle", handle, "ok", false));
            return;
        }
        snapshot.getSnapshotContents().writeBytes(data);
        SnapshotMetadataChange change = new SnapshotMetadataChange.Builder().setDescription(description).build();
        PlayGames.getSnapshotsClient(activity).commitAndClose(snapshot, change).addOnCompleteListener(done -> {
            if (!done.isSuccessful()) Log.w(PlatformServices.TAG, "could not save game", done.getException());
            services.post(SERVICE, "snapshotCommitted", PlatformServices.object("handle", handle, "ok", done.isSuccessful()));
        });
    }

    private void discardSnapshot(int handle) {
        Snapshot snapshot = openSnapshots.remove(handle);
        if (snapshot != null) PlayGames.getSnapshotsClient(activity).discardAndClose(snapshot);
    }

    private static void put(JSONObject object, String key, Object value) {
        try {
            object.put(key, value);
        } catch (JSONException e) {
            Log.e(PlatformServices.TAG, "bad games event", e);
        }
    }
}
