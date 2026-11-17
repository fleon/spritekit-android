package PACKAGE_NAME;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Sets the scheduled notifications' alarms again when Android has dropped
 * them (a reboot, an update of the app) or when the clock moved under them
 * (a new time zone, the time set by hand), from the requests
 * {@link PlatformNotifications} keeps.
 *
 * <p>Exported because the system sends these; each is a protected broadcast
 * no other app can send, and anything else is ignored.
 */
public final class NotificationBootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (action == null) return;
        switch (action) {
            case Intent.ACTION_BOOT_COMPLETED:
            case Intent.ACTION_MY_PACKAGE_REPLACED:
                PlatformNotifications.rearmAll(context, false);
                break;
            case Intent.ACTION_TIMEZONE_CHANGED:
            case Intent.ACTION_TIME_CHANGED:
                PlatformNotifications.rearmAll(context, true);
                break;
            default:
                break;
        }
    }
}
