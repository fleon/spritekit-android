#!/usr/bin/env node
'use strict';
// Store screenshots of a game's screens, shot on an Android emulator or an
// iOS simulator: one tool for every game on this runtime, driven by the
// game's capture.json (README.md beside this file). The game's own hooks
// (a patch script that wires launch arguments such as -ShotState into a
// scratch copy, never the repository) put each screen in the state its
// screenshot shows; this builds that copy, launches each shot in each
// language, waits until it settles and saves the screen.
//
//   node <game capture dir>/<shim> …        (the game's shim names capture.json)
//   node Tools/Capture/capture.js --settings <capture.json> <command> …
//
// Commands:
//   build android               copies the game into the work folder, runs its
//                               android.patch on the copy and builds the debug
//                               APK (arm64-v8a); prints the APK's path
//   build ios <udid>            the same for the simulator, with ios.patch,
//                               and installs the app on <udid>
//   shoot android [--screen <name>] <out> [name…]
//                               shoots on $ANDROID_SERIAL (adb from $ADB):
//                               <out>/[<language>/]<file>.png, on
//                               android.screen, or the named one of
//                               android.screens
//   shoot ios <udid> <display> <out> [name…]
//                               shoots on a simulator; <display> is 1 (an
//                               iPhone Duo's outer screen), 3 (its inner one)
//                               or - (a simulator with one screen)
//   check <dir> --store play|appstore [--size <w>x<h>]
//                               checks a set (<dir>/*.png, or a set a
//                               language folder) against the store's rules
//   sheet <dir> <file.jpg>      a contact sheet of <dir> (a row a language)
//
// [name…] picks shots by name and languages by code, in any mix; with none,
// every shot (but the optional ones) in every language. The work folder is
// $SHOTS_WORK, else $TMPDIR/<name>-shots, and keeps its build products
// between runs.
//
// Never shoot on a phone: the hooks rewrite the saved progress, and the
// cloud would sync it.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const lib = require('./lib');
const { sheet, rowsOf } = require('./sheet');

const argv = process.argv.slice(2);
const option = (name) => {
  const i = argv.indexOf(name);
  if (i < 0) return undefined;
  const value = argv[i + 1];
  argv.splice(i, 2);
  return value;
};
const fail = (message, code = 1) => { console.error(`capture: ${message}`); process.exit(code); };
const sleep = (s) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, s * 1000);
const usage = () => {
  const text = fs.readFileSync(__filename, 'utf8');
  console.log(text.slice(text.indexOf('//   node'), text.indexOf("const fs")).replace(/^\/\/ ?/gm, '').trim());
};

if (argv.includes('--help') || argv.includes('-h') || !argv.length) { usage(); process.exit(argv.length ? 0 : 2); }

const SETTINGS_FILE = option('--settings') ?? process.env.CAPTURE_SETTINGS;
const SCREEN = option('--screen');
const [command, ...rest] = argv;

// MARK: - Settings

function loadSettings() {
  if (!SETTINGS_FILE) fail('which game? Run its own shim, or pass --settings <capture.json>', 2);
  const file = path.resolve(SETTINGS_FILE);
  let json;
  try { json = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (error) { fail(`${file}: ${error.message}`, 2); }
  let settings;
  try { settings = lib.readSettings(json, file); } catch (error) { fail(error.message, 2); }
  const dir = path.dirname(file);
  const root = settings.root
    ? path.resolve(dir, settings.root)
    : execFileSync('git', ['-C', dir, 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  const work = path.resolve(process.env.SHOTS_WORK || path.join(process.env.TMPDIR || os.tmpdir(), `${settings.name}-shots`));
  return { ...settings, dir, root, work };
}

const pngLine = (file) => {
  const { width, height } = lib.pngInfo(fs.readFileSync(file));
  return `${width}x${height}`;
};

// MARK: - Build

// The game copied into <work>/src (build products kept), then its hooks
// patched into the copy.
function scratchCopy(settings, patch) {
  if (!patch) fail('capture.json names no patch script for this platform', 2);
  const src = path.join(settings.work, 'src');
  fs.mkdirSync(src, { recursive: true });
  execFileSync('rsync', ['-a', '--delete', ...settings.exclude.flatMap((e) => ['--exclude', e]), `${settings.root}/`, `${src}/`], { stdio: 'inherit' });
  const patched = spawnSync('python3', ['-I', path.resolve(settings.dir, patch), src], { stdio: ['ignore', 2, 2] });
  if (patched.status !== 0) fail(`${patch} failed`);
  return src;
}

function buildAndroid(settings) {
  const android = settings.android ?? fail('capture.json has no android settings', 2);
  const src = scratchCopy(settings, android.patch);
  const log = path.join(settings.work, 'build.log');
  console.error(`building the shell (log: ${log})`);
  const out = fs.openSync(log, 'w');
  const shell = spawnSync('Android/Scripts/build-shell.sh', ['--debug', 'arm64-v8a'], { cwd: src, stdio: ['ignore', out, out] });
  if (shell.status !== 0) {
    const errors = [...new Set(fs.readFileSync(log, 'utf8').split('\n').filter((l) => /error:/.test(l)))].sort().slice(0, 20);
    fail(`the shell didn't build:\n${errors.join('\n')}`);
  }
  const abis = android.abisProperty ? [`-P${android.abisProperty}=arm64-v8a`] : [];
  const gradle = spawnSync('./gradlew', ['-q', 'assembleDebug', ...abis], { cwd: path.join(src, android.app), stdio: ['ignore', out, out] });
  if (gradle.status !== 0) fail(`gradle failed:\n${fs.readFileSync(log, 'utf8').split('\n').slice(-20).join('\n')}`);
  console.log(path.join(src, android.app, 'app/build/outputs/apk/debug/app-debug.apk'));
}

function buildIOS(settings, udid) {
  const ios = settings.ios ?? fail('capture.json has no ios settings', 2);
  if (!udid) fail('usage: build ios <simulator-udid>', 2);
  for (const key of ['project', 'scheme', 'app']) if (!ios[key]) fail(`capture.json: ios.${key} is needed to build`, 2);
  const src = scratchCopy(settings, ios.patch);
  const log = path.join(settings.work, 'build.log');
  const derived = path.join(settings.work, 'DerivedData');
  const out = fs.openSync(log, 'w');
  spawnSync('xcodebuild', ['-project', ios.project, '-scheme', ios.scheme, '-configuration', 'Debug',
    '-destination', `platform=iOS Simulator,id=${udid}`, '-derivedDataPath', derived,
    '-skipMacroValidation', '-skipPackagePluginValidation', 'build'], { cwd: src, stdio: ['ignore', out, out] });
  const text = fs.readFileSync(log, 'utf8');
  if (!text.includes('BUILD SUCCEEDED')) {
    console.error(text.split('\n').filter((l) => /error:/.test(l)).slice(0, 20).join('\n'));
    fail(`Build failed; see ${log}`);
  }
  execFileSync('xcrun', ['simctl', 'install', udid, path.join(derived, 'Build/Products/Debug-iphonesimulator', `${ios.app}.app`)]);
  console.log(`Installed on ${udid}`);
}

// MARK: - Shoot

const filesIn = (dir) => fs.readdirSync(dir).filter((f) => fs.statSync(path.join(dir, f)).isFile()).sort();

function shootAndroid(settings, out, filters) {
  const android = settings.android ?? fail('capture.json has no android settings', 2);
  if (!out) fail('usage: shoot android <out-dir> [name…]', 2);
  const serial = process.env.ANDROID_SERIAL || fail('ANDROID_SERIAL names no device (Scripts/emulators.sh acquire sets it)', 2);
  const adb = process.env.ADB || 'adb';
  const pkg = android.package;
  const a = (...args) => execFileSync(adb, ['-s', serial, ...args], { timeout: 60000, maxBuffer: 256 << 20, stdio: ['ignore', 'pipe', 'pipe'] });
  const vars = { appData: `/data/user/0/${pkg}` };
  let screen;
  try { screen = lib.screenFor(android, SCREEN); } catch (error) { fail(error.message, 2); }
  let captures;
  try { captures = lib.plan(settings, 'android', filters, vars); } catch (error) { fail(error.message, 2); }
  fs.mkdirSync(out, { recursive: true });

  a('shell', 'am', 'force-stop', pkg);
  for (const { from, to } of android.push) {
    a('shell', 'run-as', pkg, 'mkdir', '-p', to);
    const dir = path.resolve(settings.work, from);
    for (const name of filesIn(dir)) {
      a('push', path.join(dir, name), '/data/local/tmp/shot.tmp');
      a('shell', 'run-as', pkg, 'cp', '/data/local/tmp/shot.tmp', `${to}/${name}`);
    }
    a('shell', 'rm', '-f', '/data/local/tmp/shot.tmp');
  }
  if (screen) {
    a('shell', 'wm', 'size', screen.size);
    a('shell', 'wm', 'density', String(screen.density));
    sleep(5);
  }
  const defaultSettle = Number(process.env.SETTLE || android.settle);
  try {
    for (const { shot, language, args, file } of captures) {
      const dest = path.join(out, file);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      a('shell', 'am', 'force-stop', pkg);
      a('logcat', '-c');
      a('shell', 'am', 'start', '-n', `${pkg}/.MainActivity`, '--es', 'args64', lib.args64(args));
      const landed = shot.scene !== undefined ? lib.fill(android.log.landed, { scene: shot.scene }) : null;
      const t0 = Date.now();
      let done = false;
      while (!done && Date.now() - t0 < android.timeout * 1000) {
        sleep(2);
        done = lib.settled(lib.filterLog(a('logcat', '-d').toString('utf8'), android.log.filter), { landed, event: shot.event });
      }
      if (!done) console.log(`  (gave up waiting for ${shot.scene ?? shot.name}${shot.event ? ` and ${shot.event}` : ''})`);
      sleep(shot.settle ?? defaultSettle);
      const png = a('exec-out', 'screencap', '-p');
      if (android.flatten) {
        execFileSync('ffmpeg', ['-v', 'error', '-y', '-f', 'png_pipe', '-i', '-', '-pix_fmt', 'rgb24', dest], { input: png });
      } else {
        fs.writeFileSync(dest, png);
      }
      console.log(`${language ? `${language} ` : ''}${shot.name} -> ${dest} ${pngLine(dest)}`);
    }
  } finally {
    // Best effort: a device that went away mustn't hide why the run stopped.
    const tidy = (...args) => { try { a(...args); } catch { /* gone */ } };
    tidy('shell', 'am', 'force-stop', pkg);
    if (screen) {
      tidy('shell', 'wm', 'size', 'reset');
      tidy('shell', 'wm', 'density', 'reset');
    }
  }
}

function shootIOS(settings, udid, display, out, filters) {
  const ios = settings.ios ?? fail('capture.json has no ios settings', 2);
  if (!out) fail('usage: shoot ios <simulator-udid> <display> <out-dir> [name…]', 2);
  const run = (...args) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  let captures;
  try { captures = lib.plan(settings, 'ios', filters); } catch (error) { fail(error.message, 2); }
  fs.mkdirSync(out, { recursive: true });
  if (ios.push.length) {
    const data = run('get_app_container', udid, ios.bundle, 'data').trim();
    for (const { from, to } of ios.push) {
      const dir = path.resolve(settings.work, from);
      fs.mkdirSync(path.join(data, to), { recursive: true });
      for (const name of filesIn(dir)) fs.copyFileSync(path.join(dir, name), path.join(data, to, name));
    }
  }
  const terminate = () => { try { run('terminate', udid, ios.bundle); } catch { /* not running */ } };
  try {
    for (const { shot, language, args, file } of captures) {
      const dest = path.join(out, file);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      terminate();
      run('launch', udid, ios.bundle, ...args);
      sleep(shot.wait ?? ios.wait);
      run('io', udid, 'screenshot', ...(display && display !== '-' ? [`--display=${display}`] : []), dest);
      console.log(`${language ? `${language} ` : ''}${shot.name} -> ${dest} ${pngLine(dest)}`);
    }
  } finally {
    terminate();
  }
}

// MARK: - Check and sheet

function check(dir, store, size) {
  if (!dir || !store) fail('usage: check <dir> --store play|appstore [--size <w>x<h>]', 2);
  const wanted = size ? size.split('x').map(Number) : undefined;
  const sets = rowsOf(path.resolve(dir));
  if (!sets.length) fail(`no PNGs in ${dir}`);
  let problems = [];
  try {
    for (const files of sets) {
      const label = path.relative(process.cwd(), path.dirname(files[0])) || '.';
      const found = lib.setProblems(files.map((f) => ({ name: path.basename(f), info: lib.pngInfo(fs.readFileSync(f)) })), store, wanted);
      problems = problems.concat(found.map((p) => `${label}: ${p}`));
      console.log(`${label}: ${files.length} screenshots${found.length ? `, ${found.length} problem${found.length > 1 ? 's' : ''}` : ', fine'}`);
    }
  } catch (error) { fail(error.message, 2); }
  for (const p of problems) console.log(`  ${p}`);
  process.exit(problems.length ? 1 : 0);
}

process.on('uncaughtException', (error) => fail(error.stderr?.length ? `${error.message.split('\n')[0]}: ${error.stderr.toString().trim()}` : error.message));

switch (command) {
  case 'build': {
    const [platform, udid] = rest;
    if (platform === 'android') buildAndroid(loadSettings());
    else if (platform === 'ios') buildIOS(loadSettings(), udid);
    else fail('usage: build android | build ios <udid>', 2);
    break;
  }
  case 'shoot': {
    const [platform, ...more] = rest;
    if (platform === 'android') shootAndroid(loadSettings(), more[0], more.slice(1));
    else if (platform === 'ios') shootIOS(loadSettings(), more[0], more[1], more[2], more.slice(3));
    else fail('usage: shoot android <out> [name…] | shoot ios <udid> <display> <out> [name…]', 2);
    break;
  }
  case 'check': {
    const store = option('--store');
    const size = option('--size');
    check(argv[1], store, size);
    break;
  }
  case 'sheet': {
    const [dir, file] = rest;
    if (!dir || !file) fail('usage: sheet <dir> <file.jpg>', 2);
    console.log(sheet(rowsOf(path.resolve(dir)), path.resolve(file)));
    break;
  }
  default:
    fail(`unknown command "${command}" (--help lists them)`, 2);
}
