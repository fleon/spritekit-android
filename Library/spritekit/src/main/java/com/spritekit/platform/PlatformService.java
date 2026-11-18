package com.spritekit.platform;

import org.json.JSONObject;

/**
 * One service behind the platform channel, under the name it was added with
 * ({@link PlatformServices#add}): Swift's {@code <name>.<method>} calls come
 * to {@link #call}, and it answers later through
 * {@link PlatformServices#post}.
 */
public interface PlatformService {
    /**
     * Runs {@code method} with {@code args}, on SDL's thread. Returns what is
     * known at once, or null; anything slow is started here and posted later.
     * A throw is logged and answered with null.
     */
    JSONObject call(String method, JSONObject args) throws Exception;

    /** The activity is resuming, before SDL resumes the game. */
    default void onResume() {
    }

    /** The activity stopped (gone to the background). */
    default void onStop() {
    }

    /** The activity is going away. */
    default void onDestroy() {
    }
}
