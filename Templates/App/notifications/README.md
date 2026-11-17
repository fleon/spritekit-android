# Local notifications: the app's half

The Java behind `UNUserNotificationCenter` on Android
(`Sources/PlatformShim/UserNotifications.swift`, imported by a game as
`UserNotifications` from `Modules/`). A game's own reminder code — asking to
notify, scheduling, listing and removing pending requests, its delegate's
`willPresent` and `didReceive` — runs unedited against it.

| File | What it does |
| --- | --- |
| `app/src/main/java/PACKAGE_PATH/PlatformNotifications.java` | The `notifications` service: permission, scheduling, the pending list, showing, taps |
| `app/src/main/java/PACKAGE_PATH/NotificationReceiver.java` | A scheduled notification's alarm going off |
| `app/src/main/java/PACKAGE_PATH/NotificationBootReceiver.java` | Re-arms the alarms after a reboot or an update, and on a time zone or clock change |
| `AndroidManifest-snippet.xml` | The two permissions and the two receivers |
| `app/src/main/res/drawable/ic_stat_notification.xml` | The status bar icon (a bell: swap in the game's own one-colour silhouette) |

## Copying it into a game

1. Copy `app/` over the game's copy of `base/` (the same tree), so the
   three `.java` files land beside `PlatformServices.java` and the drawable
   in `res/drawable/`. Replace the placeholders as for `base/`: `PACKAGE_NAME`
   (each file's `package` line) and `PACKAGE_PATH` (the folder). The others
   (`APP_NAME`, `XCODE_PROJECT`, `GAME_KEY`) don't appear here: the
   notification channel takes the app's label at run time. The classes use
   `PlatformServices.post`, `PlatformServices.object` and
   `PlatformServices.TAG` from that package.
2. Keep `ic_stat_notification.xml` or replace it with the game's own
   one-colour silhouette. Without it the app's launcher icon is used, which
   Android draws as a white blob.
3. Merge `AndroidManifest-snippet.xml` into the app's manifest.
4. Wire the service into `PlatformServices`: a field, its construction, and
   a case in `call`'s dispatch.

   ```java
   final PlatformNotifications notifications;

   PlatformServices(Activity activity) {
       …
       notifications = new PlatformNotifications(activity, this);
   }

   …
   case "notifications": result = notifications.call(method, arguments); break;
   ```

   It follows the activity's lifecycle itself (an
   `ActivityLifecycleCallbacks`), so `onResume` and the rest need nothing.

A tap opens the launcher activity with the notification on its intent,
which is read as the activity resumes. The launcher activity must be
`singleTask` or `singleInstance`, and must keep the newest intent: neither
`SDLActivity` nor the base template does, so add this to the game's
`MainActivity`, or a tap while the game runs is lost:

```java
@Override
protected void onNewIntent(Intent intent) {
    super.onNewIntent(intent);
    setIntent(intent);
}
```

(A `MainActivity` that already overrides `onNewIntent`, for links say,
adds the `setIntent(intent)` line to its own.)

## The protocol

Calls, `notifications.<method>`, answered at once:

| Call | Arguments | Answer |
| --- | --- | --- |
| `start` | | `{status}`; posts the taps held until Swift's center existed |
| `authorization` | | `{status}`: `notDetermined`, `denied` or `authorized` |
| `request` | `{options, request}` | `{status, granted}`, or `{status}` while the prompt is up (a `status` event with the same `request` follows) |
| `schedule` | `{request}` | `{ok}` |
| `remove` | `{identifiers}` | |
| `removeAll` | | |
| `pending` | | `{requests}` |
| `delivered` | | `{notifications: [{request, date}]}` |
| `removeDelivered` | `{identifiers}` | |
| `removeAllDelivered` | | |
| `badge` | `{count}` | nothing: Android's launchers count for themselves |
| `present` | `{request, options}` | the answer to `willPresent` |

Events, service `notifications`:

| Event | Body | When |
| --- | --- | --- |
| `status` | `{status, granted?, request?}` | the prompt's answer, or the player changed it in Settings |
| `willPresent` | `{request, date}` | one fired with the game in front: Swift asks its delegate and calls `present` with the options, as iOS shows nothing in front unless the delegate says so |
| `opened` | `{request, date, action}` | the player tapped one (`action` is `default`) |

A request is `{identifier, content: {title, subtitle, body, sound?, badge?,
threadIdentifier, categoryIdentifier, userInfo}, trigger?}`. A trigger is
`{type: "calendar", repeats, year?, month?, day?, hour?, minute?, second?,
weekday?, timeZone?, fireAt}` or `{type: "interval", seconds, repeats,
fireAt}`; `fireAt` is the next fire time in milliseconds since 1970, as
Swift works it out (Java arms the first alarm with it and works out each
repeat). No trigger shows it now. Dates are milliseconds since 1970.

## How it behaves

- **Permission.** From Android 13, `POST_NOTIFICATIONS` is asked for through
  the activity when the game calls `requestAuthorization`, and read back as
  the activity resumes after the prompt. Not asked yet is `notDetermined`;
  refused is `denied`, and Android shows its prompt at most twice, after
  which `requestAuthorization` answers `false` at once, as iOS does after
  one refusal. Before Android 13 there's no prompt: `authorized`, or
  `denied` if the player turned notifications off.
- **Alarms.** `setAndAllowWhileIdle`: delivered in Doze, with no permission
  to ask for. Exact alarms need `SCHEDULE_EXACT_ALARM` from Android 12 —
  off by default from Android 14, and a Play Console declaration — and a
  reminder doesn't need to land on the minute, so Android may deliver
  one up to an hour late. Where exact alarms are allowed anyway (before
  Android 12, or an app that declares and holds the permission) they're
  used. One alarm per pending request; Android allows an app 500.
- **Calendar triggers** fire in the device's local time, or in the trigger's
  own time zone when it has one, as `UNCalendarNotificationTrigger` does.
  Units left out below the smallest given are zero, those above it free:
  `{hour: 18, minute: 0}` is 18:00 every day, `{minute: 30}` every hour at
  half past. After a time zone change, triggers without one of their own are
  worked out again in the new local time.
- **Pending requests** live in SharedPreferences, so `pending` answers from
  them, a repeating one re-arms after each fire, and the boot receiver sets
  them all again. A non-repeating one leaves the list as it fires; one
  missed while the phone was off fires as it starts.
- **In front**, a fired notification goes to the game's delegate
  (`willPresent`) and is shown only with `.banner` or `.list`.
- **Showing.** One channel, named after the app, at default importance
  (sound, no heads-up). Content without a sound is posted silently. The
  subtitle is the notification's sub-text, `threadIdentifier` its group,
  `badge` its number.
- **Tapping** opens the launcher activity; the game's delegate hears
  `didReceive` with `UNNotificationDefaultActionIdentifier` and the request,
  `userInfo` and all, on the next frame. A tap that launched the app waits
  until the game has made its center.
- **`userInfo`** travels as JSON: string keys and JSON values only.
