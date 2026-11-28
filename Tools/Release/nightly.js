#!/usr/bin/env node
'use strict';
// A game's nightly release: when PRs were merged (or the runtime moved)
// since the last `Build <N>` commit, one build of origin's branch with one
// build number on every platform, to TestFlight (internal and external
// testers) and to Google Play's internal testing, copied to closed testing
// (alpha), both rolled out and sent for review. Never production.
//
//   <game>/Tools/Release/nightly.sh [--dry-run] [--notes <file>] [--ref <commit>]
//
//   --dry-run       decide, version, write the notes and build every platform
//                   (the Apple archives and exports, the Android bundle,
//                   checked by play.js offline), but upload and push nothing
//   --notes <file>  this build's tester notes, a few `• ` lines in plain words
//                   for players; without it they're drafted from the merged
//                   PRs' titles (the game's notes settings)
//   --ref <commit>  build that instead of origin's branch, to try a change
//                   with --dry-run before it's merged (never for a release;
//                   NIGHTLY_REF says the same)
//
// Every Apple platform and Android build and upload at the same time, each
// with its own logs (release.json's "parallel": false runs them one after
// another). It works in a throwaway worktree, removed at the end; in the
// checkout it's run from it only fetches. The App Store Connect writes are the TestFlight
// upload, its What to Test and the External group with --submit; the one
// Play write is play.js's nightly release. The Build commit is pushed only
// once an upload succeeded. It needs gh, asc, gplay, Xcode, the NDK,
// swiftly's toolchain, the Android SDK and 1Password's service account, so
// it runs outside a sandbox. Tools/Release/README.md has the settings.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const lib = require('./lib');
const stores = require('./stores');

const args = process.argv.slice(2);
if (args.includes('--help') || args.includes('-h')) {
  const lines = fs.readFileSync(__filename, 'utf8').split('\n');
  const end = lines.findIndex((l, i) => i > 2 && !l.startsWith('//'));
  console.log(lines.slice(2, end).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}

const usage = (why) => { console.error(`nightly: ${why} (--help lists the options)`); process.exit(2); };
let DRY = false;
let notesIn = null;
let ref = process.env.NIGHTLY_REF || null;
for (let i = 0; i < args.length; i += 1) {
  if (args[i] === '--dry-run') DRY = true;
  else if (args[i] === '--notes') notesIn = args[++i] ?? usage('--notes takes a file');
  else if (args[i] === '--ref') ref = args[++i] ?? usage('--ref takes a commit');
  else usage(`unknown option ${args[i]}`);
}
if (ref && !DRY) usage('--ref is for --dry-run only: a release is always built from origin');
if (notesIn) {
  notesIn = path.resolve(notesIn);
  if (!fs.existsSync(notesIn) || !lib.bulleted(fs.readFileSync(notesIn, 'utf8')).length) usage(`no notes in ${notesIn}`);
}

const { settings: S, root: CONFIG_ROOT } = (() => {
  try { return stores.loadSettings(); } catch (error) { usage(error.message); }
})();
const missing = lib.nightlyProblems(S);
if (missing.length) usage(`release.json has no ${missing.join(', ')}`);

const say = (line = '') => console.log(line);
const heading = (title) => say(`\n== ${title} ==`);
const quiet = (command, argv, options = {}) => spawnSync(command, argv, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, ...options });
const git = (...argv) => {
  const r = quiet('git', argv);
  if (r.status !== 0) throw new Error(`git ${argv.slice(0, 4).join(' ')} failed: ${(r.stderr || '').trim()}`);
  return r.stdout.trim();
};
const fail = (why) => { say(`${why}: no build.`); process.exit(1); };
// Git over the network: HTTPS with gh's login (lib.HTTPS_GIT), never a
// prompt, and given up after ten minutes rather than waited on all night.
const net = (argv) => quiet('git', [...lib.HTTPS_GIT, ...argv], {
  env: { ...process.env, GIT_TERMINAL_PROMPT: '0' }, timeout: 10 * 60 * 1000,
});

// The checkout this runs from (or a worktree of it): only fetched.
const ROOT = (() => { try { return git('-C', CONFIG_ROOT, 'rev-parse', '--show-toplevel'); } catch { return CONFIG_ROOT; } })();
const BRANCH = S.branch;
const ORIGIN = `origin/${BRANCH}`;
const REF = ref || ORIGIN;
const PBX = path.join(S.project, 'project.pbxproj');
const SLUG = S.name.replace(/[^A-Za-z0-9]/g, '');

// --- 1. Decide -------------------------------------------------------------

if (quiet('gh', ['auth', 'status']).status !== 0) fail('gh is missing or signed out');
if (net(['-C', ROOT, 'fetch', '-q', 'origin', '--prune']).status !== 0) fail('git fetch failed');

// The last build: the newest `Build <N>` commit on the branch, else (before
// the first nightly) the commit that last set the build number.
function lastBuild() {
  const tagged = git('-C', ROOT, 'log', '-1', '--format=%H%x09%cI%x09%s', '--grep=^Build [0-9]', ORIGIN);
  if (tagged) {
    const [sha, date, subject] = tagged.split('\t');
    return { sha, date, number: lib.buildInSubject(subject) };
  }
  const set = git('-C', ROOT, 'log', '-1', '--format=%H%x09%cI', '-G', 'CURRENT_PROJECT_VERSION = ', ORIGIN, '--', PBX);
  if (!set) fail(`no last build on ${ORIGIN}`);
  const [sha, date] = set.split('\t');
  return { sha, date, number: Number(lib.projectSetting(git('-C', ROOT, 'show', `${sha}:${PBX}`), 'CURRENT_PROJECT_VERSION')) };
}
const LAST = lastBuild();

const listed = quiet('gh', ['pr', 'list', '--repo', S.repo, '--state', 'merged', '--base', BRANCH, '--limit', '100',
  '--json', 'number,title,mergedAt,mergeCommit,files']);
if (listed.status !== 0) fail(`gh pr list failed (${(listed.stderr || '').trim()})`);
const ancestor = (a, b) => quiet('git', ['-C', ROOT, 'merge-base', '--is-ancestor', a, b]).status === 0;
// A merge commit on the branch that the last build doesn't hold.
const PRS = lib.newPRs(JSON.parse(listed.stdout), (oid) => ancestor(oid, ORIGIN) && !ancestor(oid, LAST.sha), LAST.date);
// The runtime moves the nightly task pushes straight to the branch.
const MOVES = git('-C', ROOT, 'log', '--reverse', '--format=%h%x09%s', `${LAST.sha}..${ORIGIN}`)
  .split('\n').filter((l) => /\tRuntime to [0-9a-f]{7,40}$/.test(l)).map((l) => l.split('\t')[1]);
if (!PRS.length && !MOVES.length) {
  say(`nothing merged since Build ${LAST.number}`);
  process.exit(0);
}
heading(`Since Build ${LAST.number}`);
for (const p of PRS) say(`#${p.number} ${p.title}`);
for (const m of MOVES) say(m);

// --- 2. The release worktree -----------------------------------------------

const A = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), `${SLUG.toLowerCase()}-nightly-`));
const WT = path.join(A, 'worktree');
const pad = (n) => String(n).padStart(2, '0');
const now = new Date();
const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
const LOGS = path.join(os.homedir(), 'Library/Logs', `${SLUG}Nightly`, stamp);
fs.mkdirSync(LOGS, { recursive: true });
function cleanup() {
  quiet('git', ['-C', ROOT, 'worktree', 'remove', '--force', WT]);
  quiet('git', ['-C', ROOT, 'worktree', 'prune']);
  fs.rmSync(A, { recursive: true, force: true });
}
process.on('exit', cleanup);
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => process.exit(130));

if (quiet('git', ['-C', ROOT, 'worktree', 'add', '-q', '--detach', WT, REF]).status !== 0) fail('the release worktree failed');
if (net(['-C', WT, 'submodule', 'update', '-q', '--init', S.submodule]).status !== 0) fail('the runtime submodule failed');
const RUNTIME = path.join(WT, S.submodule);
const GUARD = path.join(RUNTIME, 'Tools/guard.js');

// --- 3. Version and build number -------------------------------------------

heading('Version');
let V;
try {
  V = stores.release({ root: WT, settings: S, log: say });
} catch (error) {
  say(error.message);
  fail('the version or build number couldn\'t be worked out');
}
const SUBJECT = lib.buildSubject(V.build, V.version, V.bumped);
if (quiet('git', ['-C', WT, 'commit', '-q', '-am', SUBJECT]).status !== 0) fail(`the ${SUBJECT} commit failed`);
say(`${SUBJECT}, committed in the worktree; pushed only after an upload.`);
const VALUES = { build: V.build, version: V.version, name: V.name, worktree: WT, runtime: RUNTIME, guard: GUARD, logs: LOGS };

// --- 4. Notes --------------------------------------------------------------

const NOTES = path.join(A, 'notes.txt');
const noteLines = notesIn ? lib.bulleted(fs.readFileSync(notesIn, 'utf8')) : lib.draftNotes(PRS, S.notes);
fs.writeFileSync(NOTES, noteLines.join('\n') + '\n');
heading('Notes');
say(noteLines.join('\n'));

// --- Steps -----------------------------------------------------------------

const ENV = {
  ...process.env,
  RELEASE_WORKTREE: WT, RELEASE_RUNTIME: RUNTIME, RELEASE_GUARD: GUARD, RELEASE_LOGS: LOGS,
  RELEASE_BUILD: String(V.build), RELEASE_VERSION: V.version, RELEASE_DRY_RUN: DRY ? '1' : '0',
};
// Runs one step with its output in $LOGS/<name>.log; on failure, prints its end.
function step(name, argv, { cwd = WT, shell = false } = {}) {
  say(`-- ${name}`);
  const log = path.join(LOGS, `${name}.log`);
  const fd = fs.openSync(log, 'w');
  // Android's steps take swiftly's toolchain, which only a shell can load.
  const [command, ...rest] = shell
    ? ['bash', '-c', 'set +u; [ -f "$HOME/.swiftly/env.sh" ] && . "$HOME/.swiftly/env.sh"; exec "$@"', 'bash', ...argv]
    : argv;
  const r = spawnSync(command, rest, { cwd, env: ENV, stdio: ['ignore', fd, fd] });
  fs.closeSync(fd);
  if (r.status === 0) return true;
  const tail = fs.readFileSync(log, 'utf8').split('\n').filter((l) => l.trim() && !/password/i.test(l)).slice(-15);
  say(`   ${name} failed${r.error ? ` (${r.error.message})` : ''}; the end of ${log}:`);
  for (const l of tail) say(`     ${l}`);
  return false;
}
// The same, without waiting: the platforms' chains run side by side.
function stepAsync(name, argv, { cwd = WT, shell = false } = {}) {
  say(`-- ${name}`);
  const log = path.join(LOGS, `${name}.log`);
  const fd = fs.openSync(log, 'w');
  const [command, ...rest] = shell
    ? ['bash', '-c', 'set +u; [ -f "$HOME/.swiftly/env.sh" ] && . "$HOME/.swiftly/env.sh"; exec "$@"', 'bash', ...argv]
    : argv;
  return new Promise((resolve) => {
    let error = null;
    const child = spawn(command, rest, { cwd, env: ENV, stdio: ['ignore', fd, fd] });
    child.on('error', (e) => { error = e; });
    child.on('close', (code) => {
      fs.closeSync(fd);
      if (code === 0 && !error) return resolve(true);
      const tail = fs.readFileSync(log, 'utf8').split('\n').filter((l) => l.trim() && !/password/i.test(l)).slice(-15);
      say(`   ${name} failed${error ? ` (${error.message})` : ''}; the end of ${log}:`);
      for (const l of tail) say(`     ${l}`);
      resolve(false);
    });
  });
}
const commands = (list) => list.map((c, i) => ({ name: c.name ?? `step-${i + 1}`, run: c.run.map((a) => lib.fill(a, VALUES)) }));
const logTail = (name, n = 3) => {
  try { return fs.readFileSync(path.join(LOGS, `${name}.log`), 'utf8').split('\n').filter((l) => l.trim() && !/password/i.test(l)).slice(-n).join(' '); } catch { return ''; }
};

const RESULTS = [];
let uploaded = false;
let failed = false;

// The game's own art, made before either platform builds.
heading('Art');
let artOK = true;
for (const c of commands(S.art)) if (!(artOK = step(c.name, c.run))) break;
if (!S.art.length) say('none to make');

// --- 5. Apple --------------------------------------------------------------

const EXPORT_OPTIONS = path.join(A, 'ExportOptions.plist');
fs.writeFileSync(EXPORT_OPTIONS, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key><string>export</string>
    <key>method</key><string>app-store-connect</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>${S.appStore.team}</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
`);
// Every game uploads at once each night: give asc's upload time.
ENV.ASC_UPLOAD_TIMEOUT ||= '60m';

async function apple(platform) {
  const P = lib.PLATFORMS[platform];
  const id = P.label.replace(/\W/g, '');
  const archive = path.join(A, `${SLUG}-${id}.xcarchive`);
  const artifact = path.join(A, `${SLUG}-${id}.${P.artifact}`);
  if (!artOK) return 'not built: the art couldn\'t be made';
  const xcflags = (...flags) => flags.map((f) => `--xcodebuild-flag=${f}`);
  if (!await stepAsync(`${id}-archive`, ['asc', 'xcode', 'archive', '--project', path.join(WT, S.project), '--scheme', S.appStore.scheme,
    '--configuration', 'Release', '--clean', '--archive-path', archive,
    ...xcflags('-destination', P.destination, '-allowProvisioningUpdates', '-skipMacroValidation', '-skipPackagePluginValidation',
      '-derivedDataPath', path.join(A, `DerivedData-${id}`)), '--output', 'json'])) {
    return `archive failed: ${logTail(`${id}-archive`)}`;
  }
  if (!await stepAsync(`${id}-export`, ['asc', 'xcode', 'export', '--archive-path', archive, '--export-options', EXPORT_OPTIONS,
    `--${P.artifact}-path`, artifact, ...xcflags('-allowProvisioningUpdates'), '--output', 'json'])) {
    return `export failed: ${logTail(`${id}-export`)}`;
  }
  if (!fs.existsSync(artifact)) return `the export wrote no ${P.artifact}`;
  const size = `${(fs.statSync(artifact).size / 1048576).toFixed(1)} MB`;
  if (DRY) return `${V.version} (${V.build}) archived and exported (${size}); dry run, not uploaded`;
  const upload = platform === 'MAC_OS'
    ? ['--pkg', artifact, '--platform', platform, '--version', V.version, '--build-number', String(V.build)]
    : ['--ipa', artifact, '--platform', platform];
  if (!await stepAsync(`${id}-upload`, ['asc', 'publish', 'testflight', '--app', S.appStore.app, ...upload, '--upload-only', '--wait', '--output', 'json'])) {
    return `upload failed: ${logTail(`${id}-upload`)}`;
  }
  uploaded = true;
  const info = await new Promise((resolve) => {
    let stdout = '';
    const child = spawn('asc', ['builds', 'info', '--app', S.appStore.app, '--build-number', String(V.build), '--platform', platform,
      '--version', V.version, '--output', 'json'], { env: ENV, stdio: ['ignore', 'pipe', 'ignore'] });
    child.stdout.on('data', (d) => { stdout += d; });
    child.on('error', () => resolve({ stdout: '' }));
    child.on('close', () => resolve({ stdout }));
  });
  let buildId = '';
  try {
    const d = JSON.parse(info.stdout);
    const data = d.data ?? d;
    buildId = (Array.isArray(data) ? data[0] : data)?.id ?? '';
  } catch { /* reported below */ }
  if (!buildId) return 'uploaded, but its build wasn\'t found to add its notes and the External group';
  if (!await stepAsync(`${id}-notes`, ['asc', 'builds', 'test-notes', 'create', '--build-id', buildId, '--locale', 'en-US', '--whats-new', `@file:${NOTES}`])) {
    return `uploaded, but its What to Test failed: ${logTail(`${id}-notes`)}`;
  }
  if (!await stepAsync(`${id}-external`, ['asc', 'builds', 'add-groups', '--build-id', buildId, '--group', S.appStore.externalGroup, '--submit', '--confirm'])) {
    return `uploaded with its notes, but adding the External group failed: ${logTail(`${id}-external`)}`;
  }
  return 'uploaded and submitted to external beta review';
}

async function applePlatform(platform) {
  const label = lib.PLATFORMS[platform].label;
  const result = await apple(platform);
  if (!/^(uploaded and submitted|.*dry run, not uploaded$)/.test(result)) failed = true;
  say(`${label}: ${result}`);
  return [label, result];
}

// --- 6. Android ------------------------------------------------------------

ENV.ANDROID_NDK_HOME ||= path.join(os.homedir(), 'Library/Android/android-ndk-r30');
ENV.ANDROID_NDK_ROOT ||= ENV.ANDROID_NDK_HOME;
ENV.ANDROID_HOME ||= path.join(os.homedir(), 'Library/Android/sdk');
const AAB = path.join(WT, 'Android/App/app/build/outputs/bundle/release/app-release.aab');
const NAME = lib.fill(S.android.releaseName, VALUES);
// The release as the report names it: its name, with the build when the name doesn't hold it.
const LABEL = NAME.includes(String(V.build)) ? NAME : `${NAME} (${V.build})`;

async function android() {
  if (!artOK) return 'not built: the art couldn\'t be made';
  const build = [
    { name: 'android-vendor', run: [path.join(RUNTIME, 'Vendor/build.sh'), 'android'] },
    { name: 'android-sdl', run: ['Android/Scripts/build-sdl.sh'] },
    ...commands(S.android.art).map((c) => ({ ...c, name: `android-${c.name}` })),
    { name: 'android-shell', run: ['Android/Scripts/build-shell.sh', '--store'] },
  ];
  for (const c of build) if (!await stepAsync(c.name, c.run, { shell: true })) return `${c.name.replace(/^android-/, '')} failed: ${logTail(c.name)}`;
  const properties = S.android.gradleProperties.map((p) => lib.fill(p, VALUES));
  if (!await stepAsync('android-bundle', ['./gradlew', '--no-daemon', '--console=plain', 'bundleRelease', ...properties], { cwd: path.join(WT, 'Android/App'), shell: true })) {
    return `bundleRelease failed: ${logTail('android-bundle', 4)}`;
  }
  if (!fs.existsSync(AAB)) return 'bundleRelease wrote no bundle';
  const play = (send) => ['node', GUARD, '12', '--', 'node', path.join(WT, S.playDir, 'play.js'), ...lib.playRelease({ aab: AAB, name: NAME, notes: NOTES, send })];
  // Without --send, play.js checks the bundle offline and uploads nothing.
  if (!await stepAsync('android-check', play(false))) return `the bundle doesn't check out for Play: ${logTail('android-check')}`;
  const size = `${(fs.statSync(AAB).size / 1048576).toFixed(1)} MB`;
  if (DRY) return `${LABEL} built (${size}) and checked for internal and alpha; dry run, not uploaded`;
  const sent = await stepAsync('android-release', play(true));
  const log = (() => { try { return fs.readFileSync(path.join(LOGS, 'android-release.log'), 'utf8'); } catch { return ''; } })();
  const neverPublished = /had never been published/.test(log)
    ? '; the app had never been published, so every pending change went for review too' : '';
  if (!sent) {
    // The internal release may have gone out before the copy to alpha failed.
    if (/^Release: rolled out on internal/m.test(log)) {
      uploaded = true;
      return `${LABEL} rolled out to internal testing, but copying it to alpha failed: ${logTail('android-release')}`;
    }
    return `the Play release failed: ${logTail('android-release')}`;
  }
  uploaded = true;
  return `${LABEL} rolled out to internal and alpha and sent for review${neverPublished}`;
}
async function androidPlatform() {
  const result = await android();
  if (!/(sent for review|dry run, not uploaded)/.test(result) || /failed/.test(result)) failed = true;
  say(`Android: ${result}`);
  return ['Android', result];
}

// Every chain at once, or one after another; the report keeps one order.
async function main() {
  const chains = [...S.appStore.platforms.map((p) => () => applePlatform(p)), () => androidPlatform()];
  if (S.parallel) {
    heading(`${[...S.appStore.platforms.map((p) => lib.PLATFORMS[p].label), 'Android'].join(', ')}, side by side`);
    RESULTS.push(...await Promise.all(chains.map((chain) => chain())));
  } else {
    for (const chain of chains) {
      heading(chain === chains[chains.length - 1] ? 'Android' : lib.PLATFORMS[S.appStore.platforms[chains.indexOf(chain)]].label);
      RESULTS.push(await chain());
    }
  }

// --- 7. Push ---------------------------------------------------------------

let pushed;
if (DRY) {
  pushed = `dry run: ${SUBJECT} not pushed`;
} else if (uploaded) {
  const push = () => net(['-C', WT, 'push', '-q', 'origin', `HEAD:${BRANCH}`]).status === 0;
  const ok = push() || (net(['-C', WT, 'fetch', '-q', 'origin']).status === 0
    && quiet('git', ['-C', WT, 'rebase', '-q', ORIGIN]).status === 0 && push());
  pushed = ok ? `${SUBJECT} pushed to ${BRANCH}` : `${SUBJECT} NOT pushed: push it by hand, its number is taken`;
  if (!ok) failed = true;
} else {
  pushed = `nothing uploaded, so ${SUBJECT} isn't pushed; the next run tries again`;
}

// --- Report ----------------------------------------------------------------

heading('Report');
const since = [PRS.length && `${PRS.length} PR${PRS.length === 1 ? '' : 's'}`, MOVES.length && `${MOVES.length} runtime move${MOVES.length === 1 ? '' : 's'}`].filter(Boolean).join(' and ');
say(`${S.name} ${V.version}, build ${V.build}${DRY ? ' (dry run)' : ''}: ${since} since Build ${LAST.number}`);
if (V.bumped) say(`Version: ${V.previous} is in production on the App Store (${V.live}), so this is ${V.version}`);
for (const [label, result] of RESULTS) say(`${label}: ${result}`);
say(pushed);
say(`Logs: ${LOGS}`);
say('Notes:');
say(noteLines.map((l) => `  ${l}`).join('\n'));
process.exitCode = failed ? 1 : 0;
}

main().catch((error) => { say(`nightly: ${error.stack || error}`); process.exitCode = 1; });
