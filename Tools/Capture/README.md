# Screen captures

The tools that film a game for its store pages: store screenshots of its
screens, shot on an Android emulator or an iOS simulator in every language,
recordings of the app in simulators and the Mac app, and the checks and
contact sheets that go with them. Every game on this runtime uses these, each
with its own settings and hooks; nothing here knows a game.

| File | What it does |
|---|---|
| `capture.js` | Shoots a game's screens from its `capture.json`: builds a hooked scratch copy, launches each shot in each language, waits until it settles, saves the screen. Also checks a set against a store's rules and draws contact sheets. |
| `apple.js` | Simulator, Mac and session plumbing for a game's own recording tools (previews, trailers, frames for laid-out screenshots): debug builds, simulators of a run's own, the unfolded Duo, the Mac app's window and preferences, marker-driven sessions. |
| `mac-record.swift` | A ScreenCaptureKit recorder for the Mac app's window that says when its first frame showed, so markers line up to the frame (`apple.macRecorder`). |
| `sheet.js` | Contact sheets: a row a language, every screenshot as tall. |
| `parity-pair.sh` | One state side by side on an emulator and a simulator, with a picture of the difference and a score. |
| `lib.js` | The pure parts: settings, plans, file names, settling, the stores' rules, framing. |

## Shooting a game's screens (`capture.js`)

A game puts its screens into the states its screenshots show with hooks of
its own: a patch script (Python, run as `python3 -I <script> <scratch copy>`)
that wires launch arguments such as `-ShotState` into a scratch copy of the
repository, never the repository itself, so the hooks never ship. The tool
does the rest:

```bash
node Tools/Capture/capture.js --settings <capture.json> build android            # prints the APK's path
node Tools/Capture/capture.js --settings <capture.json> build ios <udid>         # builds and installs
node Tools/Capture/capture.js --settings <capture.json> shoot android <out> [name…]
node Tools/Capture/capture.js --settings <capture.json> shoot ios <udid> <display> <out> [name…]
node Tools/Capture/capture.js check <dir> --store play|appstore [--size <w>x<h>]
node Tools/Capture/capture.js sheet <dir> <file.jpg>
```

- `build` copies the repository into `<work>/src` (rsync, without history or
  build products), runs the platform's patch script on the copy and builds
  it: the debug APK for arm64-v8a (`Android/Scripts/build-shell.sh --debug`,
  then Gradle), or the Debug app for the simulator, installed on it. The work
  folder is `$SHOTS_WORK`, else `$TMPDIR/<name>-shots`, and keeps its build
  products, so a second build only rebuilds what changed. The build log is
  `<work>/build.log`.
- `shoot android` shoots on `$ANDROID_SERIAL` (adb from `$ADB`, else the one
  on the path). It pushes the files the game seeds into the app's data, sets
  the emulator's screen (and sets it back afterwards), and for each shot
  stops the app, clears the log, starts it with the shot's launch arguments
  (`args64`, as `Scripts/launch.js` does), waits until it has settled and
  saves the screen. Settled means the shot's scene has drawn (the renderer's
  `scene <Scene> at` line, or the game's own line), its `event` (if any) is
  in the log, and every texture page the renderer read has been decoded;
  then a few quiet seconds for the entrance animation. It gives up waiting
  after `timeout` seconds, says so, and shoots anyway.
- `shoot ios` copies the seeded files into the app's data container, and for
  each shot terminates the app, launches it with the shot's arguments, waits
  the shot's seconds and saves the screen: `<display>` is `1` for an iPhone
  Duo's outer screen, `3` for its inner one, `-` for a simulator with one.
- Shots land in `<out>/<language>/<file>.png` for a game that shoots every
  language, else `<out>/<file>.png`, the layout `Tools/Play/play.js images
  --screenshots <out>` takes. Names after `<out>` pick shots (by name) and
  languages (by code), in any mix; with none, every shot but the optional
  ones, in every language.
- `check` reads each PNG's header and refuses what the store would: an alpha
  channel (App Store Connect and Play both refuse one), for Play a side under
  320 or over 3840 px or a long side more than twice the short, more than a
  set holds (Play eight, the App Store ten), and with `--size` any other size.
  It exits 1 on a problem.
- `sheet` lays a set out for review: a row a language folder.

Shoot on an emulator, never a phone: hooks rewrite the saved progress, and the
cloud (iCloud, Play Saved Games) would sync it. Borrow one from the pool
(`Scripts/emulators.sh acquire`), and install the hooked APK on it alone
(`adb -s $ANDROID_SERIAL install -r -t <apk>`).

### A game's `capture.json`

The game keeps `capture.json` beside its hooks, and a shim for each command at
the path its callers know:

```zsh
#!/bin/zsh
# Launches each screenshot state on an Android emulator and captures it.
# The runtime's Tools/Capture/capture.js, with capture.json.
exec node "${0:A:h:h:h:h}/Android/spritekit-android/Tools/Capture/capture.js" --settings "${0:A:h}/capture.json" shoot android "$@"
```

| Key | What it says |
|---|---|
| `name` | Names the work folder (`$TMPDIR/<name>-shots`). |
| `root` | The repository, relative to `capture.json` (default: the git checkout it's in). |
| `exclude` | More rsync patterns the scratch copy leaves out (it always leaves out `.git`, `.claude`, `node_modules`, `.build` and the Android app's build folders). |
| `languages` | The languages to shoot, each into its own folder; without it, one set. |
| `languageArgs` | The arguments that pick a language (default `["-AppleLanguages", "({language})"]`). |
| `shots` | In store order: `name`, `file` (without `.png`), `args`, and per platform what it waits for: `scene` and `event` (a log line) and `settle` (seconds after it settles) on Android, `wait` (seconds after launch) on iOS. `optional: true` shoots it only when named (an alternative take, which may share its main shot's `file`). |
| `android` | `package`, `patch` (the patch script, beside `capture.json`), `abisProperty` (the Gradle property that picks ABIs, as `zyl.abis`), `app` (default `Android/App`), `screen` (`{ "size": "1080x1920", "density": 420 }`), `flatten` (save RGB, without alpha), `log` (`filter`: keep only lines with this; `landed`: the line a scene logs once it's in, `{scene}` for its name, default `scene {scene} at`), `timeout` (default 120), `settle` (default 6; `$SETTLE` overrides it), `args` (added to every shot; `{appData}` is the app's data folder) and `push`. |
| `ios` | `bundle`, `project`, `scheme`, `app` (the product's name), `patch`, `wait` (default 8), `args` and `push`. |
| `push` | `[{ "from": "<folder in the work folder>", "to": "<folder in the app's data>" }]`: files the hooks read, such as saved games, copied in before the shots. |

## Recording on Apple's side (`apple.js`)

A game's own recording tools (laid-out store screenshots, preview videos,
trailers) bind `apple.js` to the game once, in a capture module of their own,
and keep beside it what's the game's: the launch arguments that quiet it,
its screens, the progress it seeds.

```js
const apple = require('../../Android/spritekit-android/Tools/Capture/apple.js')({
  root, bundle: 'com.example.game', project: 'Game.xcodeproj', scheme: 'Game', app: 'Game',
  macEntitlements: 'Game-macOS.entitlements', unfoldedDuo: 'Game Duo (unfolded)',
});
```

- `buildApps(platforms, out)` makes Debug builds for `ios`, `tvos` and `mac`
  (Mac Catalyst, unsandboxed, so its preferences are the user's own) into
  `<out>/DerivedData`, fetching the runtime submodule first when it's empty;
  `appPath`, `macBinary` and `requireBuilds` find them.
- `createSimulator(name, { type, orientation }, app)` creates and boots
  `<name> <pid>` on the newest runtime that runs it, never with ten booted,
  and installs the app; `deleteSimulators` deletes every one the run made,
  and `deleteSimulatorsOnExit` does so on Ctrl-C or a fatal error.
- `unfoldedDuo(app, display)` is the one iPhone Duo kept unfolded for good:
  only DeviceHub's hinge slider unfolds a Duo, so it's created the first time
  (the run waits for someone to unfold it, once), booted when it's down and
  never deleted.
- `session({ start, stop, launchArgs, video, ready, act, label })` launches
  the app, collects its markers (`[marker] …`, stamped with the system clock
  under `-MarkerClock YES`), optionally records the simulator's screen, and
  acts once `ready` says so.
- `withMac(out, work)` runs the Mac app and puts its preferences back
  afterwards; `macWindow(pid)` finds its window; `macRecorder(out)` builds
  `mac-record`.
- `framing({ turn, crop, screen })` gives ffmpeg's filters that stand a
  recording up and crop it to a view capped to an aspect; `markTime` finds a
  marker's moment.

## Parity

```bash
Tools/Capture/parity-pair.sh <state> <simulator-udid> [out-dir]
```

With the emulator sized as the simulator's device and both showing the same
state, it writes `<out>/<state>.png` (Android, iPhone, difference) and appends
`<state> <score>` to `<out>/scores.txt`. A game runs it through a shim at
`Android/Scripts/parity-pair.sh`.

## Tests

```bash
node --test Tools/Capture/capture.test.js
```
