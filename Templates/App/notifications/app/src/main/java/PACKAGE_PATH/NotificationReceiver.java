package PACKAGE_NAME;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * A scheduled notification's alarm went off: {@link PlatformNotifications}
 * re-arms a repeating one and shows it, or asks the game first when it's in
 * front. Not exported: only this app's own alarms reach it.
 */
public final class NotificationReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!PlatformNotifications.ACTION_FIRE.equals(intent.getAction())) return;
        String identifier = intent.getStringExtra(PlatformNotifications.EXTRA_IDENTIFIER);
        if (identifier != null) PlatformNotifications.fired(context, identifier);
    }
}
