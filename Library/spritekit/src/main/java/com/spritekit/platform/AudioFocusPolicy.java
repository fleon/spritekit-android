package com.spritekit.platform;

/**
 * When the game asks for audio focus, apart from Android so a unit test can
 * drive it ({@code AudioFocusPolicyTest}).
 *
 * <p>The game tells another app's music by {@code AudioManager.isMusicActive()},
 * which counts every app's stream, the game's own included. That reads true
 * only for others when the game's stream is stopped, which it is as the game
 * first starts and after a stop (SDL pauses it as the surface goes). A pause
 * without a stop (a dialog or the shade's device controls over the game, a
 * second launch intent, Play's sign-in) leaves it playing. So the game keeps
 * its focus through such a pause, gives it up only when it stops, and looks
 * for other music only as it comes back from a stop. Asking on every resume
 * once took the game's own soundtrack for another app's and kept it quiet
 * until the next time the app went to the background.
 */
final class AudioFocusPolicy {
    /** What a resume does about focus. */
    enum Step {
        /** Nothing has changed that the game can see: keep what it has. */
        KEEP,
        /** Ask for focus (the soundtrack plays once it's granted). */
        REQUEST,
        /** Another app's music is playing: no focus, the soundtrack quiet. */
        OTHER_AUDIO,
    }

    /** Whether the game's stream is stopped: before the first start, and after a stop. */
    private boolean stopped = true;

    Step onResume(boolean holdsFocus, boolean musicActive) {
        boolean afterStop = stopped;
        stopped = false;
        if (holdsFocus || !afterStop) return Step.KEEP;
        return musicActive ? Step.OTHER_AUDIO : Step.REQUEST;
    }

    /** The game went to the background: give focus up. */
    void onStop() {
        stopped = true;
    }
}
