package com.spritekit.platform;

/**
 * When the game asks for audio focus and gives it up, apart from Android so
 * a unit test can drive it ({@code AudioFocusPolicyTest}).
 *
 * <p>The game's soundtrack follows its own music switch alone. While the
 * switch is on, the game asks for focus each time it comes back from a stop
 * (and as it first starts), whatever another app is playing: Android fades
 * out an app that lost focus and keeps it muted until it asks again, so a
 * game that didn't ask would come back silent. Through a pause without a
 * stop (a dialog or the shade's device controls over the game, a second
 * launch intent, Play's sign-in) it keeps what it has: if the player
 * started their own music meanwhile, it plays until the game next comes
 * back. While the switch is off, the game holds no focus, so the player's
 * own music plays on under the game's sounds.
 */
final class AudioFocusPolicy {
    /** What to do about focus. */
    enum Step {
        KEEP,
        REQUEST,
        ABANDON,
    }

    /** Whether the game is stopped: before the first start, and after a stop. */
    private boolean stopped = true;
    /** The game's music switch: null until the game says. */
    private Boolean wanted;

    Step onResume(boolean holdsFocus) {
        boolean afterStop = stopped;
        stopped = false;
        return afterStop && !holdsFocus && Boolean.TRUE.equals(wanted) ? Step.REQUEST : Step.KEEP;
    }

    /** The game went to the background: it gives focus up. */
    void onStop() {
        stopped = true;
    }

    /** The game says whether it wants focus (its music switch). */
    Step onWanted(boolean wanted, boolean holdsFocus) {
        boolean changed = this.wanted == null || this.wanted != wanted;
        this.wanted = wanted;
        if (!changed || stopped) return Step.KEEP;
        if (wanted && !holdsFocus) return Step.REQUEST;
        if (!wanted && holdsFocus) return Step.ABANDON;
        return Step.KEEP;
    }
}
