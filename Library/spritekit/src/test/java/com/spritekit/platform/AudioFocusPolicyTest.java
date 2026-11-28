package com.spritekit.platform;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class AudioFocusPolicyTest {
    @Test
    public void asksAsTheGameSaysItWantsFocus() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        assertEquals(AudioFocusPolicy.Step.KEEP, policy.onResume(false));
        assertEquals(AudioFocusPolicy.Step.REQUEST, policy.onWanted(true, false));
    }

    @Test
    public void asksAtTheFirstStartWhenTheGameSaidSoBefore() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        assertEquals(AudioFocusPolicy.Step.KEEP, policy.onWanted(true, false));
        assertEquals(AudioFocusPolicy.Step.REQUEST, policy.onResume(false));
    }

    /**
     * The regression: coming back from a stop while another app's music
     * plays (or after it took focus and Android faded the game out), the
     * game asks again, so its soundtrack comes back.
     */
    @Test
    public void backFromAStopAsksAgain() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        policy.onWanted(true, false);
        policy.onResume(false);
        policy.onStop();
        assertEquals(AudioFocusPolicy.Step.REQUEST, policy.onResume(false));
    }

    @Test
    public void pauseWithoutStopKeepsWhatItHas() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        policy.onWanted(true, false);
        policy.onResume(false);
        assertEquals(AudioFocusPolicy.Step.KEEP, policy.onResume(true));
        assertEquals(AudioFocusPolicy.Step.KEEP, policy.onResume(false));
    }

    @Test
    public void musicOffHoldsNoFocus() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        policy.onWanted(false, false);
        assertEquals(AudioFocusPolicy.Step.KEEP, policy.onResume(false));
        policy.onStop();
        assertEquals(AudioFocusPolicy.Step.KEEP, policy.onResume(false));
    }

    @Test
    public void theSwitchTakesAndGivesUpFocusInTheFront() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        policy.onWanted(false, false);
        policy.onResume(false);
        assertEquals(AudioFocusPolicy.Step.REQUEST, policy.onWanted(true, false));
        assertEquals(AudioFocusPolicy.Step.ABANDON, policy.onWanted(false, true));
    }

    /** The same switch told again (a sync) doesn't take focus back from the player's own music. */
    @Test
    public void theSameSwitchAgainChangesNothing() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        policy.onWanted(true, false);
        policy.onResume(false);
        assertEquals(AudioFocusPolicy.Step.KEEP, policy.onWanted(true, false));
    }

    @Test
    public void theSwitchInTheBackgroundWaitsForTheFront() {
        AudioFocusPolicy policy = new AudioFocusPolicy();
        policy.onWanted(false, false);
        policy.onResume(false);
        policy.onStop();
        assertEquals(AudioFocusPolicy.Step.KEEP, policy.onWanted(true, false));
        assertEquals(AudioFocusPolicy.Step.REQUEST, policy.onResume(false));
    }
}
