'use strict';
// What the version tool and the nightly read and write: the game's release
// settings, its Xcode project, App Store Connect (`asc`, read-only) and Play
// (the game's own `play.js versions`, read-only).

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const lib = require('./lib');

function loadSettings(file = process.env.RELEASE_CONFIG) {
  if (!file) throw new Error('Which game? Run its own version tool or nightly script (it names its release.json in RELEASE_CONFIG).');
  if (!fs.existsSync(file)) throw new Error(`No release settings at ${file}.`);
  const settings = lib.settingsFrom(JSON.parse(fs.readFileSync(file, 'utf8')));
  return { settings, root: path.resolve(path.dirname(file), settings.root ?? '../..') };
}

const projectFile = (root, settings) => path.join(root, settings.project, 'project.pbxproj');
const pause = (seconds) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, seconds * 1000);

function run(command, argv, { cwd } = {}) {
  const result = spawnSync(command, argv, { cwd, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (result.error?.code === 'ENOENT') throw new Error(`${command} is not installed`);
  if (result.status !== 0) {
    const why = (result.stderr || result.stdout || '').trim().split('\n').filter(Boolean).slice(-2).join(' ');
    throw new Error(`${command} ${argv.slice(0, 3).join(' ')} failed: ${why}`);
  }
  return result.stdout;
}

// What Play has given out, through the game's play.js (tried three times:
// Play answers 503 now and then).
function playVersions(root, settings, approved) {
  const argv = [path.join(root, settings.playDir, 'play.js'), 'versions', '--json', ...(approved ? ['--approved', approved] : [])];
  for (let attempt = 1; ; attempt += 1) {
    try {
      return JSON.parse(run(process.execPath, argv, { cwd: root }));
    } catch (error) {
      if (attempt === 3) throw new Error(`Play can't be read: ${error.message}`);
      console.error(`play.js versions: ${error.message} (trying again)`);
      pause(20);
    }
  }
}

// Every build number App Store Connect has taken: builds in any state, and
// uploads still in flight (asc's next build number, one past them).
function appStoreBuilds(settings) {
  const app = settings.appStore.app;
  const numbers = lib.ascBuildNumbers(lib.ascData(run('asc', ['builds', 'list', '--app', app, '--paginate', '--processing-state', 'all', '--output', 'json'])));
  try {
    const next = Number(JSON.parse(run('asc', ['builds', 'next-build-number', '--app', app, '--output', 'json'])).nextBuildNumber);
    if (Number.isInteger(next) && next > 0) numbers.push(next - 1);
  } catch (error) {
    console.error(`asc's next build number wasn't read (${error.message}); its builds list stands.`);
  }
  return numbers;
}

// The App Store version Apple approved for `version`, or null.
function appStoreApproved(settings, version) {
  const versions = lib.ascData(run('asc', ['versions', 'list', '--app', settings.appStore.app, '--paginate', '--output', 'json']));
  return lib.appStoreApproved(versions, version);
}

// Where the project and the stores stand.
function survey({ root, settings, offline = false, play: known = null }) {
  const text = fs.readFileSync(projectFile(root, settings), 'utf8');
  const project = Number(lib.projectSetting(text, 'CURRENT_PROJECT_VERSION'));
  const marketing = lib.projectSetting(text, 'MARKETING_VERSION');
  if (!Number.isInteger(project)) throw new Error(`CURRENT_PROJECT_VERSION isn't a whole number: ${project}`);
  const readsAppStore = !offline && Boolean(settings.appStore?.app);
  const appStore = readsAppStore ? appStoreBuilds(settings) : [];
  const play = offline ? null : known ?? playVersions(root, settings);
  const playCodes = play ? [play.highest] : [];
  const seen = { project, appStore, play: playCodes };
  return {
    text, project, marketing, readsAppStore, appStore, play, seen,
    highest: lib.highestTaken(seen), next: lib.nextBuild(seen), now: lib.thisBuild(seen),
  };
}

const nameFor = (settings, marketing, code, play) =>
  (settings.version.patchNames ? lib.patchName(marketing, code, play?.releases ?? []) : marketing);

function writeBuild(root, settings, text, build) {
  const updated = lib.withBuild(text, build);
  if (updated !== text) fs.writeFileSync(projectFile(root, settings), updated);
  return updated !== text;
}

// The nightly's version step, in `root` (its release worktree): bump the
// minor when the version has an approved release on either store, then take
// the next build number. Writes the project; returns what it did.
function release({ root, settings, log = console.error }) {
  const before = fs.readFileSync(projectFile(root, settings), 'utf8');
  const previous = lib.projectSetting(before, 'MARKETING_VERSION');
  const onAppStore = settings.appStore?.app ? appStoreApproved(settings, previous) : null;
  const play = playVersions(root, settings, previous);
  const onPlay = play.approved;
  const approved = [onAppStore && `App Store ${onAppStore}`, onPlay && `Play production ${onPlay.name} (${onPlay.status})`].filter(Boolean).join(', ');
  let version = previous;
  if (approved) {
    version = lib.bumpMinor(previous);
    fs.writeFileSync(projectFile(root, settings), lib.withVersion(before, previous, version));
    log(`Version ${previous} is approved (${approved}): this build is ${version}.`);
  } else {
    log(`Version ${previous} has no approved release on either store: it stays.`);
  }
  const s = survey({ root, settings, play });
  writeBuild(root, settings, s.text, s.next);
  log(`Build ${s.next}: one past the project's ${s.project}, App Store Connect's ${s.readsAppStore ? Math.max(0, ...s.appStore) || 'none' : 'not read'} and Play's ${s.play.highest || 'none'}.`);
  return { previous, version, bumped: version !== previous, approved: approved || null, build: s.next, name: nameFor(settings, version, s.next, s.play) };
}

module.exports = { loadSettings, projectFile, survey, release, nameFor, writeBuild, playVersions, appStoreBuilds, appStoreApproved, run };
