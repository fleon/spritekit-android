package com.spritekit.platform;

import android.content.pm.ActivityInfo;

/**
 * The activity's requested orientation for the orientations a game allows,
 * apart from Android so a unit test can drive it ({@code OrientationPolicyTest}).
 *
 * <p>The game names them in its {@code spritekit_orientations} string (the
 * library's {@code res/values/orientations.xml}), in the words of SDL's
 * {@code SDL_HINT_ORIENTATIONS}: {@code Portrait}, {@code PortraitUpsideDown},
 * {@code LandscapeLeft}, {@code LandscapeRight}. As for SDL's resizable
 * window, portrait and landscape together follow the sensor and the user's
 * rotation lock; one of them alone holds the screen that way.
 */
final class OrientationPolicy {
    private OrientationPolicy() {}

    static int requestedOrientation(String orientations) {
        boolean portrait = false, upsideDown = false, left = false, right = false;
        for (String word : orientations.trim().split("\\s+")) {
            switch (word) {
                case "Portrait": portrait = true; break;
                case "PortraitUpsideDown": upsideDown = true; break;
                case "LandscapeLeft": left = true; break;
                case "LandscapeRight": right = true; break;
                default: break;
            }
        }
        boolean anyPortrait = portrait || upsideDown, anyLandscape = left || right;
        if (anyPortrait == anyLandscape) return ActivityInfo.SCREEN_ORIENTATION_FULL_USER;
        if (anyPortrait) {
            if (portrait && upsideDown) return ActivityInfo.SCREEN_ORIENTATION_USER_PORTRAIT;
            return portrait ? ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                : ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT;
        }
        if (left && right) return ActivityInfo.SCREEN_ORIENTATION_USER_LANDSCAPE;
        return left ? ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            : ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE;
    }
}
