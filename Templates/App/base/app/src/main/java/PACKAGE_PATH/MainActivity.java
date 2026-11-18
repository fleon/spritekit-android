package PACKAGE_NAME;

import com.spritekit.platform.PlatformServices;
import com.spritekit.platform.SpriteKitActivity;
import com.spritekit.platform.billing.PlayBilling;

/**
 * The APK's only activity: the runtime's {@link SpriteKitActivity} (SDL's
 * activity, with the shell's side of the platform channel, links, the share
 * sheet and Paste), and the services this game adds to the built-in
 * {@code device}, {@code games} and {@code review}.
 *
 * <p>A game overrides what it needs: {@code gameLink} to read its links,
 * {@code shareUri} for a content provider of its own, {@code logTag}.
 */
public class MainActivity extends SpriteKitActivity {
    @Override
    protected void addServices(PlatformServices services) {
        // A game that sells nothing leaves this out, and the module.
        services.add(PlayBilling.SERVICE, new PlayBilling(this, services));
        // Local notifications, with the module in app/build.gradle.kts:
        // services.add(PlatformNotifications.SERVICE, new PlatformNotifications(this, services));
    }
}
