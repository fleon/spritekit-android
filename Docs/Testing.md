# Testing on devices, simulators and emulators

`AGENTS.md` ("Devices, simulators and emulators") has the rules; this page
has the recipes they rely on. A game's own docs add its launch arguments and
the screens they reach.

## Real devices

Every step on a device runs inside `Scripts/device-lock.sh run` (README,
"Devices"). Inside a run:

- **Android.** Wrap every `adb` call in `timeout 60`: a dropped wireless
  connection otherwise hangs while holding the lock. Before any tap or Back,
  check the game is in front:
  `adb shell dumpsys activity activities | grep -E 'topResumedActivity|mResumedActivity'`
  (older Android versions list only `mResumedActivity`). Test going to the
  background and back with `KEYCODE_HOME`, then
  `am start -n <package>/<activity>`; only `KEYCODE_WAKEUP` keeps the screen
  on. A secure lock screen can't be cleared over adb, so never send the power
  or sleep key.
- **A debug build beside a release install.** A debug build can't replace a
  release build signed with another key. Install it next to it with the
  app's `applicationIdSuffix` property (`-P<game>.applicationIdSuffix=.test`
  in the template's Gradle app), and launch that package with
  `SKA_APP_PACKAGE` for `Scripts/launch.js`.
- **Wireless adb.** The connect port changes whenever wireless debugging
  restarts. When an adb server that ran for a while answers "No route to
  host" though the port is reachable, start a fresh server on a free port
  (`ADB_SERVER_SOCKET=tcp:localhost:<port> adb start-server`, then
  `adb connect`) rather than kill one: other sessions and the emulator pool
  use the running servers.
- **iPhones and iPads.** `xcrun devicectl device install app --device <udid> <app>`;
  launch arguments go after `--`:
  `xcrun devicectl device process launch --device <udid> <bundle id> -- -settings.soundEnabled "<false/>"`.
  A debug build needs the project's team (`-allowProvisioningUpdates`).
  Crash logs come off with
  `xcrun devicectl device copy from --domain-type systemCrashLogs`.
- **Mali phones** are bound by fill rate (frame time follows the pixels
  drawn), and their `GL_EXT_disjoint_timer_query` results are wrong for
  frames that draw to several targets: time frames by the wall clock.

## Simulators

- Boot a simulator of your own (`xcrun simctl create <session name> …`) and
  delete it when you're done. A fresh one can refuse installs for a while
  after its first boot ("Failed to create promise"): retry. An old one may
  merge cloud-synced progress over the defaults you seed.
- A sandboxed app reads its preferences from its own container, not from
  the `simctl spawn … defaults` domain:
  `D=$(xcrun simctl get_app_container <udid> <bundle id> data)/Library/Preferences/<bundle id>`,
  then `xcrun simctl spawn <udid> defaults write "$D" <key> -bool NO`.
  Installing over an app keeps its data but moves its container, so look
  `$D` up again after every install.
- Launch arguments that set preferences take plist values:
  `-settings.soundEnabled "<false/>"`. A plain `NO` arrives as the string
  "NO", which a `Bool` getter with a default of `true` reads as on.
- iPad simulators ignore an app's orientation lock and `-Orientation`-style
  arguments: turn them with
  `xcrun devicectl device orientation set --device <udid> landscapeRight`.
  On iOS 27.0, `simctl io screenshot` saves a landscape phone upright; older
  runtimes save the portrait framebuffer, so check the size before turning a
  shot.
- A simulator signed out of Game Center never answers its sign-in: anything
  that waits for it needs a timeout.
- After every batch of runs, list new crash reports
  (`~/Library/Logs/DiagnosticReports/<App>-*.ips`, `find … -newer <marker>`)
  and read their stacks before running again. A take that ends on the home
  screen is a crash.

### The iPhone Duo

The iPhone Duo simulator (Xcode 27.1, device type `iPhone-Duo`) needs the
iOS 27.1 runtime, which accepts no other device type; other iPhones and
iPads run on 27.0. `xcodebuild -downloadPlatform iOS` also starts an
unwanted 27.0 download: stop it. After installing a runtime,
CoreSimulatorService may need a restart before devices boot.

- It boots closed. The cover is 466 × 678 pt with the camera top right, in
  a strip down one side (an 84 pt right safe-area inset upright); the inner
  screen is 951 × 669 pt landscape, and turns to 669 × 951 pt portrait,
  which lays out like a normal phone.
- `xcrun simctl io <udid> screenshot --display=1 --mask=black` captures the
  cover and `--display=3` the inner screen, both upright.
- Only the hinge slider in DeviceHub's device window folds and unfolds it:
  `simctl`, `devicectl` and CoreDevice have no hinge command, and
  `simctl io … screenConfig power` only blanks a screen. Ask the person to
  move it, or keep one unfolded Duo for good (`Tools/Capture`'s
  `unfoldedDuo`).
- Simulator taps reach the inner screen's coordinates, not the cover: drive
  the cover with launch arguments.
- UIKit reports the camera strip through
  `UIView.reservedRegions(kind: .occlusion)` and the fold through
  `.division`. After a fold, the first layout pass still sees the old
  regions; the right ones come a pass later.

## Recording video

- **Apple:** `xcrun simctl io <udid> recordVideo --codec h264 --force <file>.mov`
  in the background, stopped with `kill -INT`. The recording has a variable
  frame rate: make clips with `-vf fps=60`. `Tools/Capture/apple.js` records
  the Mac app's window (ScreenCaptureKit, `mac-record.swift`).
- **Android:** `adb shell screenrecord` on a pool emulator or a device.
- **Smooth takes.** A loaded host stalls the simulator for 0.2–1 s, and so
  do the seconds after an install while its asset agents settle. Another
  session recording its own simulator stalls your takes about 100 ms every
  0.6 s: wait until `ps -Ao command | grep "simctl io"` shows only yours.
  Check every take for gaps (`ffprobe -show_entries frame=pts_time`):
  anything over about 45 ms where it matters means a retake. A gap at the
  same moment in every take is the app's own cost.
- **Frame rate.** Film, cut and render at 60 fps and convert to 30 only at
  the end, blending frame pairs (`tmix=frames=2,fps=30`); resampling early
  drops and doubles frames.
- **Labels.** An ffmpeg without `drawtext` can still label a clip: draw the
  label as a PNG and overlay it.
- **Images** stay under 5 MB (GitHub's image proxy refuses bigger ones):
  JPEG at `-q:v 2`, or 8-bit PNG (`-pix_fmt rgb24`).

## Profiling and memory in the simulator

- **Time Profiler:**
  `xcrun xctrace record --template "Time Profiler" --device <udid> --attach <pid> --time-limit 24s --output run.trace --no-prompt`.
  Without `--device` it can't find the process, and attaching right after
  `simctl launch` fails the same way: wait about 1.5 s. `--launch` is refused
  when the app embeds an extension. Export the samples with
  `xctrace export --input run.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'`.
  Time Profiler samples only running threads, so a main-thread stall shows
  as a long busy stretch or a gap in its samples.
- **GPU memory.** The simulator hides most of what a device counts in the
  app's footprint. The app's `footprint` shows only CPU memory; textures
  live in the simulator's `SimMetalHost` process. Metal buffers show only as
  the app's `vmmap --summary` "shared memory" virtual size, and Core Image
  intermediates as its "IOSurface" row. `heap <pid>` counts live objects by
  class.
- **Frame gaps in a recording** aren't always the game's own: a busy
  simulator GPU drops frames the app never stalled for, and a fresh
  simulator stalls most on its first take, while its Metal cache is cold.

## SpriteKit on Apple's GPU

Measured on iOS, tvOS and Mac Catalyst devices, where SpriteKit draws with
Metal:

- **Attribute buffers.** Each `SKShader` attribute gets one buffer pool that
  never rotates. When a node with attributes suddenly sits behind many more
  vertices (a scene fading in from alpha 0, a busier screen), the pool grows
  while the GPU still reads it and the copy runs past its end
  (`-[SKAttributeValue copyValueTo:type:count:]`, a crash). Make attribute
  shaders static, built at launch, and prime them once by drawing them
  offscreen behind many sprites, which grows the pools to their cap.
- **Shader translation.** Each `SKShader` instance translates its GLSL to
  Metal on its first draw, on the main thread (0.5–1.5 ms for an
  8,000-character shader on an A14). A subtree built hidden pays for all its
  shaders the frame it first shows. Share instances, and prime them inside a
  normal frame (point-sized proxies under something opaque):
  `SKView.texture(from:)` waits for the GPU's frame in flight (6–14 ms).
- **Translation limits.** `dFdx` and `dFdy` are undeclared, a bare `return;`
  in `main` fails, and helper functions can't see uniforms (pass them in).
  Compile errors show only in `simctl launch --console-pty` output.
- **Effect nodes.** An `SKEffectNode`'s texture spans its children's whole
  accumulated frame, off-screen parts included, so `v_tex_coord` shifts as
  children move: place things by `gl_FragCoord`. Inside the effect,
  `gl_FragCoord` counts the effect texture's pixels, not the view's.
  Children render at their own scale times the content scale, ignoring the
  scene-to-view magnification, so a magnified scene's effect comes out soft
  unless its content is scaled up inside it and the effect down by the
  inverse.
- **Crops.** A crop node draws its children into a texture of its own first,
  and its accumulated frame ignores its mask. An effect inside a crop gets
  `gl_FragCoord` in the crop's texture: don't wrap an effect node in a crop.
- **The node counter** counts every node not hidden, on screen or not, plus
  some revisits; hidden subtrees cost nothing there. It's a poor guide to
  cost: check draw calls, passes and GPU time first. No frame-time cliff
  shows near 1,500 nodes (60 fps held to about 6,600 on an A14).
- **A keyed action re-armed from inside its own block** every frame loops
  SpriteKit's action list forever: poll from `update(_:)` instead.
