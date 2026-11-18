package com.spritekit.platform;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class AudioFocusPolicyTest {
    @Test
    public void firstStartAsksForFocusWhenNothingPlays() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        assertEquals(AudioFocusPolicy.Step.REQUEST, policy.onResume(false, false));
    }

    @Test
    public void firstStartStepsAsideForOtherMusic() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        assertEquals(AudioFocusPolicy.Step.OTHER_AUDIO, policy.onResume(false, true));
    }

    /**
     * The regression: a pause without a stop (a dialog, the shade's device
     * controls, a second launch intent) leaves the game's own soundtrack
     * playing, so `isMusicActive()` reads true. The game keeps its focus and
     * mustn't take its own music for another app's.
     */
    @Test
    public void pauseWithoutStopKeepsFocusThoughItsOwnMusicPlays() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        policy.onResume(false, false);
        assertEquals(AudioFocusPolicy.Step.KEEP, policy.onResume(true, true));
    }

    @Test
    public void pauseWithoutStopAndNoFocusChangesNothing() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        policy.onResume(false, true);
        assertEquals(AudioFocusPolicy.Step.KEEP, policy.onResume(false, true));
    }

    @Test
    public void backFromAStopLooksForOtherMusicAgain() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        policy.onResume(false, false);
        policy.onStop();
        assertEquals(AudioFocusPolicy.Step.OTHER_AUDIO, policy.onResume(false, true));
        policy.onStop();
        assertEquals(AudioFocusPolicy.Step.REQUEST, policy.onResume(false, false));
    }
}
