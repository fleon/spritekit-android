package com.spritekit.platform;

import static org.junit.Assert.assertEquals;

import android.content.pm.ActivityInfo;

import org.junit.Test;

public class OrientationPolicyTest {
    @Test
    public void everyOrientationTurnsWithTheUser() {
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_FULL_USER, OrientationPolicy.requestedOrientation(
            "LandscapeLeft LandscapeRight Portrait PortraitUpsideDown"));
    }

    @Test
    public void nothingNamedTurnsWithTheUser() {
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_FULL_USER, OrientationPolicy.requestedOrientation(""));
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_FULL_USER, OrientationPolicy.requestedOrientation("  sideways "));
    }

    @Test
    public void portraitAloneHoldsItUpright() {
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, OrientationPolicy.requestedOrientation("Portrait"));
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT,
            OrientationPolicy.requestedOrientation("PortraitUpsideDown"));
    }

    @Test
    public void bothPortraitsTurnBetweenThem() {
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_USER_PORTRAIT,
            OrientationPolicy.requestedOrientation("PortraitUpsideDown\n  Portrait"));
    }

    @Test
    public void landscapes() {
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, OrientationPolicy.requestedOrientation("LandscapeLeft"));
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE,
            OrientationPolicy.requestedOrientation("LandscapeRight"));
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_USER_LANDSCAPE,
            OrientationPolicy.requestedOrientation("LandscapeRight LandscapeLeft"));
    }

    @Test
    public void portraitAndOneLandscapeTurnWithTheUser() {
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_FULL_USER,
            OrientationPolicy.requestedOrientation("Portrait LandscapeLeft"));
    }
}
