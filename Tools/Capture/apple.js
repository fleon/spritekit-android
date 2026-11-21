'use strict';
// Filming a game on Apple's side, for every tool that records it (store
// screenshots, previews, trailers): debug builds, simulators of a run's own
// (never more than ten booted at once), a Duo kept unfolded for good, the
// Mac app in a window of its own with its preferences put back, and
// sessions that launch the app and act on its markers (`Markers` in
// PlatformSprite: `[marker] scene <Scene>`, `[marker] board`, …).
//
// A game binds it once to its app, in its own capture module:
//
//   const apple = require('<runtime>/Tools/Capture/apple.js')({
//     root, bundle: 'com.example.game', project: 'Game.xcodeproj', scheme: 'Game',
//     app: 'Game', macEntitlements: 'Game-macOS.entitlements', unfoldedDuo: 'Game Duo (unfolded)',
//   });
//
// and keeps what is its own beside it (the launch arguments that quiet it,
// the progress it seeds, its screens). README.md beside this file.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, execFileSync } = require('child_process');
const { framing, isCompletePNG, markTime } = require('./lib');

const MAX_BOOTED = 10;
const MARKER_TIMEOUT = 90;
const DUO_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo';

const PLATFORMS = {
  ios: { destination: 'generic/platform=iOS Simulator', products: 'Debug-iphonesimulator' },
  tvos: { destination: 'generic/platform=tvOS Simulator', products: 'Debug-appletvsimulator' },
  mac: { destination: 'platform=macOS,variant=Mac Catalyst', products: 'Debug-maccatalyst' },
};

const sleep = (s) => new Promise((resolve) => setTimeout(resolve, s * 1000));
const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...opts });

function apple({ root, bundle, project, scheme, app, macEntitlements, unfoldedDuo: unfoldedName, logPrefix = 'capture' }) {
  if (!root || !bundle) throw new Error('apple.js needs the game\'s root and bundle');
  let prefix = logPrefix;
  const setLogPrefix = (p) => { prefix = p; };
  const log = (msg) => console.log(`[${prefix}] ${msg}`);

  function exec(cmd, args, logFile) {
    return new Promise((resolve, reject) => {
      const out = logFile ? fs.openSync(logFile, 'w') : 'ignore';
      const child = spawn(cmd, args, { cwd: root, stdio: ['ignore', out, out] });
      child.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`${cmd} exited with ${code}${logFile ? ` (log: ${path.relative(root, logFile)})` : ''}`))));
    });
  }

  // MARK: - Build

  // The iOS project links the shared platform code from the runtime
  // submodule (`Android/spritekit-android/Platform`), so a checkout without
  // it can't build: fetch it first, as the game's `Android/Scripts` do.
  function ensureRuntime() {
    if (fs.existsSync(path.join(root, 'Android/spritekit-android/Platform/Package.swift'))) return;
    console.error('fetching SpriteKit for Android (git submodule update --init Android/spritekit-android)');
    execFileSync('git', ['-C', root, 'submodule', 'update', '--init', 'Android/spritekit-android'], { stdio: 'inherit' });
  }

  function appPath(out, platform) {
    return path.join(out, 'DerivedData', platform, 'Build/Products', PLATFORMS[platform].products, `${app}.app`);
  }

  // Debug builds of `platforms` into `out`/DerivedData. The Mac app runs
  // unsandboxed: shell access to its container can hang, and its snapshot
  // then lands in ~/Library/Caches.
  async function buildApps(platforms, out) {
    ensureRuntime();
    fs.mkdirSync(path.join(out, 'logs'), { recursive: true });
    await Promise.all([...platforms].map(async (platform) => {
      const args = ['-project', project, '-scheme', scheme, '-configuration', 'Debug',
        '-destination', PLATFORMS[platform].destination, '-derivedDataPath', path.join(out, 'DerivedData', platform),
        '-skipMacroValidation', 'build'];
      if (platform === 'mac') {
        if (!macEntitlements) throw new Error('a Mac build needs the game\'s macEntitlements');
        const entitlements = path.join(out, 'mac-unsandboxed.entitlements');
        const source = fs.readFileSync(path.join(root, macEntitlements), 'utf8');
        fs.writeFileSync(entitlements, source.replace(/(<key>com\.apple\.security\.app-sandbox<\/key>\s*)<true\/>/, '$1<false/>'));
        args.push('-allowProvisioningUpdates', `CODE_SIGN_ENTITLEMENTS=${entitlements}`);
      }
      log(`building for ${platform}…`);
      await exec('xcodebuild', args, path.join(out, 'logs', `build-${platform}.log`));
      log(`built ${path.relative(root, appPath(out, platform))}`);
    }));
  }

  function requireBuilds(platforms, out, buildCommand) {
    const missing = [...new Set(platforms)].filter((p) => !fs.existsSync(appPath(out, p)));
    if (missing.length) throw new Error(`No ${missing.join(', ')} build in ${path.relative(root, out)}: run ${buildCommand} first`);
  }

  // MARK: - Simulators

  function newestRuntime(type) {
    const { runtimes } = JSON.parse(run('xcrun', ['simctl', 'list', 'runtimes', '-j']));
    const fits = runtimes.filter((r) => r.isAvailable && (r.supportedDeviceTypes ?? []).some((t) => t.identifier === type));
    fits.sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }));
    if (!fits.length) throw new Error(`No simulator runtime runs ${type}`);
    return fits[0].identifier;
  }

  function bootedCount() {
    const { devices } = JSON.parse(run('xcrun', ['simctl', 'list', 'devices', 'booted', '-j']));
    return Object.values(devices).flat().length;
  }

  async function waitForBootSlot() {
    for (let waited = 0; bootedCount() >= MAX_BOOTED; waited += 10) {
      if (waited >= 600) throw new Error(`${MAX_BOOTED} simulators stayed booted for ten minutes`);
      log(`${MAX_BOOTED} simulators are booted; waiting for one to shut down…`);
      await sleep(10);
    }
  }

  // A simulator that has only just booted can still refuse an install ("Failed to locate promise").
  async function install(udid, appBundle) {
    for (let tries = 1; ; tries++) {
      try {
        run('xcrun', ['simctl', 'install', udid, appBundle]);
        return;
      } catch (error) {
        if (tries >= 5) throw error;
        await sleep(3);
      }
    }
  }

  const created = new Set();

  // Creates and boots a simulator named `<name> <pid>`, installs `appBundle`
  // and turns it to `orientation` (iPads ignore `-Orientation`).
  async function createSimulator(name, { type, orientation }, appBundle) {
    await waitForBootSlot();
    const udid = run('xcrun', ['simctl', 'create', `${name} ${process.pid}`, type, newestRuntime(type)]).trim();
    created.add(udid);
    log(`booting ${name} (${udid})…`);
    run('xcrun', ['simctl', 'bootstatus', udid, '-b']);
    await install(udid, appBundle);
    if (orientation) run('xcrun', ['devicectl', 'device', 'orientation', 'set', '--device', udid, orientation]);
    return udid;
  }

  // One iPhone Duo simulator kept unfolded for good. Only DeviceHub's hinge
  // slider unfolds a Duo, so every tool films the Duo's inner screen on
  // this one instead of making (and waiting for someone to unfold) its own:
  // it's created the first time (unfold it then, once), booted whenever
  // it's shut down, and never deleted (it isn't in `created`).
  async function unfoldedDuo(appBundle, display = 3) {
    if (!unfoldedName) throw new Error('the game names no unfolded Duo');
    const { devices } = JSON.parse(run('xcrun', ['simctl', 'list', 'devices', '-j']));
    const found = Object.values(devices).flat().find((d) => d.name === unfoldedName && d.isAvailable);
    let udid = found?.udid;
    if (!udid) {
      udid = run('xcrun', ['simctl', 'create', unfoldedName, DUO_TYPE, newestRuntime(DUO_TYPE)]).trim();
      log(`created ${unfoldedName} (${udid}), kept for good`);
    }
    if (found?.state !== 'Booted') {
      await waitForBootSlot();
      log(`booting ${unfoldedName} (${udid})…`);
      try { run('xcrun', ['simctl', 'boot', udid]); } catch { /* already booting */ }
      run('xcrun', ['simctl', 'bootstatus', udid, '-b']);
    }
    await install(udid, appBundle);
    await waitForUnfold(udid, display, unfoldedName);
    return udid;
  }

  // Waits (up to half an hour) until a Duo's inner `display` shows anything:
  // it's still folded until someone drags DeviceHub's hinge slider open.
  async function waitForUnfold(udid, display, name) {
    const probe = path.join(os.tmpdir(), `unfold-${udid}.png`);
    const shows = () => {
      try {
        run('xcrun', ['simctl', 'io', udid, 'screenshot', '--type=png', `--display=${display}`, probe]);
        const pixels = execFileSync('ffmpeg', ['-v', 'error', '-i', probe, '-vf', 'scale=16:16,format=gray', '-f', 'rawvideo', '-']);
        return Math.max(...pixels) > 40;
      } catch { return false; }
    };
    if (shows()) return fs.rmSync(probe, { force: true });
    log(`waiting for ${name} to be unfolded: open it in DeviceHub and drag its hinge slider open (once: it stays unfolded)…`);
    for (let waited = 0; !shows(); waited += 5) {
      if (waited > 1800) throw new Error(`${name} wasn't unfolded in half an hour`);
      await sleep(5);
    }
    fs.rmSync(probe, { force: true });
    log(`${name} is open`);
    await sleep(3);
  }

  function deleteSimulators() {
    for (const udid of created) {
      try { run('xcrun', ['simctl', 'shutdown', udid]); } catch { /* already off */ }
      try { run('xcrun', ['simctl', 'delete', udid]); } catch { /* already gone */ }
    }
    created.clear();
  }

  // Deletes the simulators on Ctrl-C and on a fatal error.
  function deleteSimulatorsOnExit(name) {
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { deleteSimulators(); process.exit(130); });
    return (error) => {
      deleteSimulators();
      console.error(`[${name}] ${error.message}`);
      process.exit(1);
    };
  }

  // MARK: - Mac

  // The Mac app runs unsandboxed (buildApps builds it so), so its
  // preferences are the user's own.
  const MAC_PREFS = path.join(os.homedir(), 'Library/Preferences', `${bundle}.plist`);

  // The Mac app's window (the biggest of the process `pid`'s), by its id.
  function macWindow(pid) {
    const script = `ObjC.import('CoreGraphics');
      const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)).js;
      let best = null;
      for (const item of list) {
        const w = ObjC.deepUnwrap(item);
        if (w.kCGWindowOwnerPID !== ${pid} || w.kCGWindowLayer !== 0) continue;
        const area = w.kCGWindowBounds.Width * w.kCGWindowBounds.Height;
        if (!best || area > best.area) best = { id: w.kCGWindowNumber, area };
      }
      best ? String(best.id) : ''`;
    const id = run('osascript', ['-l', 'JavaScript', '-e', script]).trim();
    if (!id) throw new Error(`no window for the Mac app (pid ${pid})`);
    return id;
  }

  // The Mac app's binary, built into `out`.
  const macBinary = (out) => path.join(appPath(out, 'mac'), 'Contents/MacOS', app);

  // The Mac's video recorder (mac-record.swift, built into `out` when it's
  // missing or older than its source): it records a window and says when
  // its first frame showed, by the clock the markers are stamped with,
  // which screencapture's video can't.
  function macRecorder(out) {
    const source = path.join(__dirname, 'mac-record.swift');
    const binary = path.join(out, 'mac-record');
    if (!fs.existsSync(binary) || fs.statSync(binary).mtimeMs < fs.statSync(source).mtimeMs) {
      fs.mkdirSync(out, { recursive: true });
      run('xcrun', ['swiftc', '-O', '-swift-version', '5', '-suppress-warnings', '-o', binary, source]);
    }
    return binary;
  }

  // Runs `work` with the Mac app, putting its preferences back afterwards
  // (a copy waits in `out`): it keeps the iOS app's bundle ID, so a
  // TestFlight Mac build here shares them.
  async function withMac(out, work) {
    const backup = path.join(out, 'mac-prefs-backup.plist');
    const hadPrefs = fs.existsSync(MAC_PREFS);
    if (hadPrefs) fs.copyFileSync(MAC_PREFS, backup);
    try {
      return await work();
    } finally {
      // cfprefsd writes what it holds for the app as it quits, so it quits
      // first, then once more after the copy, so it reads the copy afresh.
      const restart = () => { try { run('killall', ['-u', os.userInfo().username, 'cfprefsd']); } catch { /* not running */ } };
      let back = false;
      for (let attempt = 0; attempt < 3 && !back; attempt++) {
        restart();
        await sleep(1);
        if (hadPrefs) fs.copyFileSync(backup, MAC_PREFS); else fs.rmSync(MAC_PREFS, { force: true });
        restart();
        await sleep(1);
        back = hadPrefs ? fs.existsSync(MAC_PREFS) && fs.readFileSync(MAC_PREFS).equals(fs.readFileSync(backup)) : !fs.existsSync(MAC_PREFS);
      }
      if (!back) log(`The Mac app's preferences didn't come back: copy ${backup} to ${MAC_PREFS}`);
    }
  }

  // MARK: - Sessions

  // Launches the app and collects its markers, in seconds from `t0` (when
  // the recording started, or the launch). Resolves once `ready(marks,
  // elapsed)` says so, after `act(marks)` (a screenshot) has run, with the
  // app stopped again. `act` may also take its time, polling markers as
  // they come.
  function session({ start, stop, launchArgs, video, recordArgs = [], ready, act, label, timeout = MARKER_TIMEOUT }) {
    return new Promise((resolve, reject) => {
      const marks = [];
      let t0 = Date.now();
      let recorder = null;
      let child = null;
      let timer = null;
      let finished = false;
      const finish = async (error) => {
        if (finished) return;
        finished = true;
        clearInterval(timer);
        try {
          if (!error && act) await act(marks, t0);
        } catch (e) { error = e; }
        if (recorder) {
          const exited = new Promise((r) => recorder.on('exit', r));
          recorder.kill('SIGINT');
          await exited;
        }
        await stop(child);
        if (error) reject(error); else resolve(marks);
      };
      const watch = (stream) => {
        let buffer = '';
        stream.on('data', (chunk) => {
          buffer += chunk.toString();
          const lines = buffer.split(/\r?\n/);
          buffer = lines.pop();
          for (const line of lines) {
            // `-MarkerClock YES` stamps each with the system clock (`@1234.5678`).
            const m = /\[marker\] (.+?)(?: @(\d+\.\d+))?\s*$/.exec(line);
            if (m) marks.push({ name: m[1], t: (Date.now() - t0) / 1000, ...(m[2] ? { clock: Number(m[2]) } : {}) });
          }
        });
      };
      const launch = () => {
        child = start(launchArgs);
        watch(child.stdout);
        timer = setInterval(() => {
          const elapsed = (Date.now() - t0) / 1000;
          if (ready(marks, elapsed)) finish();
          else if (elapsed > timeout) {
            finish(new Error(`${label}: gave up after ${timeout} s (markers: ${marks.map((m) => m.name).join(', ') || 'none'})`));
          }
        }, 50);
      };
      if (!video) return launch();
      recorder = spawn('xcrun', ['simctl', 'io', video.udid, 'recordVideo', '--codec=h264', '--force', ...recordArgs, video.file]);
      let started = false;
      const begin = () => { if (!started) { started = true; t0 = Date.now(); launch(); } };
      for (const stream of [recorder.stdout, recorder.stderr]) stream.on('data', (d) => { if (/Recording started/i.test(d)) begin(); });
      setTimeout(begin, 4000);
    });
  }

  return {
    ROOT: root, BUNDLE: bundle, MAX_BOOTED, MARKER_TIMEOUT, PLATFORMS, UNFOLDED_DUO: unfoldedName, MAC_PREFS,
    setLogPrefix, log, sleep, run, exec,
    ensureRuntime, appPath, buildApps, requireBuilds,
    newestRuntime, bootedCount, install, createSimulator, unfoldedDuo, waitForUnfold, deleteSimulators, deleteSimulatorsOnExit,
    macWindow, macBinary, macRecorder, withMac,
    session, markTime, framing, isCompletePNG,
  };
}

module.exports = apple;
module.exports.PLATFORMS = PLATFORMS;
