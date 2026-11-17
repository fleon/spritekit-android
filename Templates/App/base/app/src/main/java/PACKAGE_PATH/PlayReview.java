package PACKAGE_NAME;

import android.app.Activity;
import android.util.Log;

import com.google.android.play.core.review.ReviewInfo;
import com.google.android.play.core.review.ReviewManager;
import com.google.android.play.core.review.ReviewManagerFactory;

import org.json.JSONObject;

/**
 * Play In-App Review, behind {@code SKStoreReviewController.requestReview}:
 * the game asks, and Play decides whether a rating card shows, as the App
 * Store does on iOS. Neither tells the game what happened (Play quotas the
 * card per player and says nothing about it), so the game hears only that
 * the request was made, under {@code review}: {@code requested {ok}}.
 *
 * <p>A build installed from anywhere but Play (an emulator, {@code adb
 * install}) runs the whole flow and shows nothing, as a TestFlight build
 * shows nothing on iOS.
 */
final class PlayReview {
    private static final String SERVICE = "review";

    private final Activity activity;
    private final PlatformServices services;
    private boolean requesting;

    PlayReview(Activity activity, PlatformServices services) {
        this.activity = activity;
        this.services = services;
    }

    JSONObject call(String method, JSONObject args) {
        switch (method) {
            case "request":
                activity.runOnUiThread(this::request);
                return null;
            default:
                Log.w(PlatformServices.TAG, "no review." + method);
                return null;
        }
    }

    private void request() {
        // One card at a time: a second ask while Play is still deciding on
        // the first would only be dropped by Play.
        if (requesting) return;
        requesting = true;
        ReviewManager manager = ReviewManagerFactory.create(activity);
        manager.requestReviewFlow().addOnCompleteListener(asked -> {
            if (!asked.isSuccessful()) {
                Log.w(PlatformServices.TAG, "Play In-App Review unavailable", asked.getException());
                finish(false);
                return;
            }
            ReviewInfo info = asked.getResult();
            manager.launchReviewFlow(activity, info).addOnCompleteListener(shown -> {
                Log.i(PlatformServices.TAG, "Play In-App Review flow finished");
                finish(shown.isSuccessful());
            });
        });
    }

    private void finish(boolean ok) {
        requesting = false;
        services.post(SERVICE, "requested", PlatformServices.object("ok", ok));
    }
}
