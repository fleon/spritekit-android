package PACKAGE_NAME;

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
import com.google.android.gms.games.AnnotatedData;
import com.google.android.gms.games.LeaderboardsClient;
import com.google.android.gms.games.PlayGames;
import com.google.android.gms.games.PlayGamesSdk;
import com.google.android.gms.games.SnapshotsClient;
import com.google.android.gms.games.achievement.Achievement;
import com.google.android.gms.games.achievement.AchievementBuffer;
import com.google.android.gms.games.leaderboard.Leaderboard;
import com.google.android.gms.games.leaderboard.LeaderboardBuffer;
import com.google.android.gms.games.leaderboard.LeaderboardScore;
import com.google.android.gms.games.leaderboard.LeaderboardScoreBuffer;
import com.google.android.gms.games.leaderboard.LeaderboardVariant;
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
 * achievements, leaderboards, the player's name and picture,
 * and Saved Games, which carry the game's synced saved data between the
 * player's devices.
 *
 * <p>Everything is off when the build has no Play Games project ID
 * ({@code -Pgame.playGamesAppId=…}): sign-in answers "no" at once, so
 * the game never waits for a service that cannot answer.
 *
 * <p>A Play Games button in the game ({@code available}, {@code showAchievements})
 * stands where Game Center's does on Apple: it shows only where Play Games can
 * run, and a tap signs a signed-out player in before opening the
 * achievements, as Game Center's button leads to its sign-in.
 *
 * <p>Events, under {@code games}: {@code signIn}, {@code achievements},
 * {@code reported}, {@code scoresSubmitted}, {@code leaderboards},
 * {@code scores}, {@code identity}, {@code player}, {@code snapshotOpened},
 * {@code snapshotCommitted}. A request's answer repeats its {@code request}
 * number, and one refused because nobody is signed in says
 * {@code reason: "signedOut"}.
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
            case "submitScores": {
                JSONArray items = args.getJSONArray("items");
                int request = args.optInt("request");
                activity.runOnUiThread(() -> submitScores(items, request));
                return null;
            }
            case "showLeaderboards": {
                String id = args.optString("id", "");
                int span = timeSpan(args.optString("timeSpan", "allTime"));
                int collection = collection(args.optString("collection", "public"));
                activity.runOnUiThread(() -> showLeaderboards(id.isEmpty() ? null : id, span, collection));
                return null;
            }
            case "loadLeaderboards": {
                JSONArray ids = args.optJSONArray("ids");
                int request = args.optInt("request");
                activity.runOnUiThread(() -> loadLeaderboards(ids, request));
                return null;
            }
            case "loadScores": {
                String id = args.getString("id");
                int span = timeSpan(args.optString("timeSpan", "allTime"));
                int collection = collection(args.optString("collection", "public"));
                int count = args.optInt("count");
                int request = args.optInt("request");
                activity.runOnUiThread(() -> loadScores(id, span, collection, count, request));
                return null;
            }
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
            if (authenticated) loadIdentity();
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

    /**
     * Sends each item's score to its leaderboard: {@code {id, score, tag}},
     * the tag being Game Center's context (empty for none). Play keeps a
     * player's best, as Game Center does, so a lower score is not an error.
     */
    private void submitScores(JSONArray items, int request) {
        if (!signedIn) {
            services.post(SERVICE, "scoresSubmitted", PlatformServices.object("request", request, "ok", false));
            return;
        }
        LeaderboardsClient leaderboards = PlayGames.getLeaderboardsClient(activity);
        List<Task<?>> tasks = new ArrayList<>();
        for (int i = 0; i < items.length(); i++) {
            JSONObject item = items.optJSONObject(i);
            if (item == null) continue;
            String id = item.optString("id");
            long score = item.optLong("score");
            String tag = item.optString("tag", "");
            tasks.add(tag.isEmpty()
                ? leaderboards.submitScoreImmediate(id, score)
                : leaderboards.submitScoreImmediate(id, score, tag));
        }
        Tasks.whenAll(tasks).addOnCompleteListener(done -> {
            if (!done.isSuccessful()) Log.w(PlatformServices.TAG, "scores did not all arrive", done.getException());
            services.post(SERVICE, "scoresSubmitted", PlatformServices.object("request", request, "ok", done.isSuccessful()));
        });
    }

    /**
     * Play Games' leaderboards over the game: one by its Play ID, at a time
     * span and collection, or the list of all of them (Game Center's
     * dashboard). A signed-out player is asked to sign in first, as for the
     * achievements.
     */
    private void showLeaderboards(String id, int span, int collection) {
        if (!configured) return;
        if (!signedIn) {
            Log.i(PlatformServices.TAG, "Play Games: signing in before the leaderboards");
            checkSignIn(true, () -> showLeaderboards(id, span, collection));
            return;
        }
        Log.i(PlatformServices.TAG, "Play Games: opening the leaderboards");
        LeaderboardsClient leaderboards = PlayGames.getLeaderboardsClient(activity);
        Task<android.content.Intent> intent = id == null
            ? leaderboards.getAllLeaderboardsIntent()
            : leaderboards.getLeaderboardIntent(id, span, collection);
        intent
            .addOnSuccessListener(shown -> activity.startActivityForResult(shown, DASHBOARD_REQUEST))
            .addOnFailureListener(error -> Log.w(PlatformServices.TAG, "could not open leaderboards", error));
    }

    /** {@code daily}, {@code weekly} or {@code allTime}, as Play's constant. */
    private static int timeSpan(String name) {
        switch (name) {
            case "daily": return LeaderboardVariant.TIME_SPAN_DAILY;
            case "weekly": return LeaderboardVariant.TIME_SPAN_WEEKLY;
            default: return LeaderboardVariant.TIME_SPAN_ALL_TIME;
        }
    }

    /** {@code public} or {@code friends}, as Play's constant. */
    private static int collection(String name) {
        return "friends".equals(name) ? LeaderboardVariant.COLLECTION_FRIENDS : LeaderboardVariant.COLLECTION_PUBLIC;
    }

    /** A failed answer, saying when it is because nobody is signed in. */
    private JSONObject refusal(int request) {
        JSONObject body = PlatformServices.object("request", request, "ok", false);
        if (!signedIn) put(body, "reason", "signedOut");
        return body;
    }

    /**
     * Each leaderboard's Play ID and title: those in {@code ids}, or every
     * one the game has.
     */
    private void loadLeaderboards(JSONArray ids, int request) {
        if (!signedIn) {
            services.post(SERVICE, "leaderboards", refusal(request));
            return;
        }
        PlayGames.getLeaderboardsClient(activity).loadLeaderboardMetadata(false).addOnCompleteListener(done -> {
            if (!done.isSuccessful() || done.getResult() == null || done.getResult().get() == null) {
                Log.w(PlatformServices.TAG, "could not load leaderboards", done.getException());
                services.post(SERVICE, "leaderboards", refusal(request));
                return;
            }
            List<String> wanted = new ArrayList<>();
            if (ids != null) for (int i = 0; i < ids.length(); i++) wanted.add(ids.optString(i));
            LeaderboardBuffer buffer = done.getResult().get();
            JSONArray items = new JSONArray();
            try {
                for (Leaderboard leaderboard : buffer) {
                    if (ids != null && !wanted.contains(leaderboard.getLeaderboardId())) continue;
                    items.put(PlatformServices.object(
                        "id", leaderboard.getLeaderboardId(), "title", leaderboard.getDisplayName()));
                }
            } finally {
                buffer.release();
            }
            JSONObject body = PlatformServices.object("request", request, "ok", true);
            put(body, "items", items);
            services.post(SERVICE, "leaderboards", body);
        });
    }

    /**
     * Up to {@code count} of a leaderboard's top scores at a time span and
     * collection (25 a page, as Play hands them out), the signed-in player's
     * own, and how many scores the variant holds. A {@code count} of 0 loads
     * only the player's.
     */
    private void loadScores(String id, int span, int collection, int count, int request) {
        if (!signedIn) {
            services.post(SERVICE, "scores", refusal(request));
            return;
        }
        LeaderboardsClient leaderboards = PlayGames.getLeaderboardsClient(activity);
        JSONArray items = new JSONArray();
        Runnable finish = () -> leaderboards.loadCurrentPlayerLeaderboardScore(id, span, collection)
            .addOnCompleteListener(mine -> {
                JSONObject body = PlatformServices.object("request", request, "ok", true);
                put(body, "items", items);
                if (mine.isSuccessful() && mine.getResult() != null && mine.getResult().get() != null) {
                    put(body, "local", score(mine.getResult().get()));
                }
                leaderboards.loadLeaderboardMetadata(id, false).addOnCompleteListener(meta -> {
                    put(body, "total", total(meta, span, collection));
                    services.post(SERVICE, "scores", body);
                });
            });
        if (count <= 0) {
            finish.run();
            return;
        }
        leaderboards.loadTopScores(id, span, collection, Math.min(count, SCORES_PAGE))
            .addOnCompleteListener(first -> collectScores(leaderboards, first, items, count, finish, request));
    }

    private static final int SCORES_PAGE = 25;

    /** Adds a page's scores, asks for the next until there are {@code count}, then finishes. */
    private void collectScores(LeaderboardsClient leaderboards,
                               Task<AnnotatedData<LeaderboardsClient.LeaderboardScores>> page,
                               JSONArray items, int count, Runnable finish, int request) {
        if (!page.isSuccessful() || page.getResult() == null || page.getResult().get() == null) {
            Log.w(PlatformServices.TAG, "could not load scores", page.getException());
            services.post(SERVICE, "scores", refusal(request));
            return;
        }
        LeaderboardScoreBuffer buffer = page.getResult().get().getScores();
        int before = items.length();
        try {
            for (LeaderboardScore score : buffer) {
                if (items.length() >= count) break;
                items.put(score(score));
            }
        } catch (RuntimeException e) {
            buffer.release();
            throw e;
        }
        boolean more = items.length() < count && items.length() > before;
        if (!more) {
            buffer.release();
            finish.run();
            return;
        }
        leaderboards.loadMoreScores(buffer, Math.min(count - items.length(), SCORES_PAGE), com.google.android.gms.games.PageDirection.NEXT)
            .addOnCompleteListener(next -> {
                buffer.release();
                collectScores(leaderboards, next, items, count, finish, request);
            });
    }

    /** One score as the game reads it. */
    private static JSONObject score(LeaderboardScore score) {
        return PlatformServices.object(
            "rank", score.getRank(),
            "score", score.getRawScore(),
            "formattedScore", score.getDisplayScore(),
            "tag", score.getScoreTag() == null ? "" : score.getScoreTag(),
            "time", score.getTimestampMillis(),
            "playerId", score.getScoreHolder() == null ? "" : score.getScoreHolder().getPlayerId(),
            "name", score.getScoreHolderDisplayName());
    }

    /** How many scores the leaderboard's variant at this span and collection holds; -1 when unknown. */
    private static long total(Task<AnnotatedData<Leaderboard>> meta, int span, int collection) {
        if (!meta.isSuccessful() || meta.getResult() == null || meta.getResult().get() == null) return -1;
        for (LeaderboardVariant variant : meta.getResult().get().getVariants()) {
            if (variant.getTimeSpan() == span && variant.getCollection() == collection) {
                long scores = variant.getNumScores();
                return scores == LeaderboardVariant.NUM_SCORES_UNKNOWN ? -1 : scores;
            }
        }
        return -1;
    }

    /** The signed-in player's ID and name. */
    private void loadIdentity() {
        PlayGames.getPlayersClient(activity).getCurrentPlayer().addOnCompleteListener(done -> {
            if (!done.isSuccessful() || done.getResult() == null) {
                Log.w(PlatformServices.TAG, "could not load the Play Games player", done.getException());
                return;
            }
            services.post(SERVICE, "identity", PlatformServices.object(
                "id", done.getResult().getPlayerId(), "name", done.getResult().getDisplayName()));
        });
    }

    /** The signed-in player's name and picture (a PNG, base64). */
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
