'use strict';
// The release tools' pure parts, apart so they test on any machine
// (release.test.js), with no git, no stores and no files.

const { sameVersion, namesVersion } = require('../Play/lib');

// App Store states of a version that reached production: live, or live once
// and since replaced or removed. Waiting for review, in review, approved but
// not yet released and every other state don't count.
const APP_STORE_LIVE = [
  'READY_FOR_SALE', 'READY_FOR_DISTRIBUTION', 'PREORDER_READY_FOR_SALE',
  'REPLACED_WITH_NEW_VERSION', 'REMOVED_FROM_SALE', 'DEVELOPER_REMOVED_FROM_SALE',
];

// What `xcodebuild -destination` and `asc publish testflight` take for each
// Apple platform, and the file its export writes.
const PLATFORMS = {
  IOS: { label: 'iOS', destination: 'generic/platform=iOS', artifact: 'ipa' },
  TV_OS: { label: 'tvOS', destination: 'generic/platform=tvOS', artifact: 'ipa' },
  MAC_OS: { label: 'macOS', destination: 'generic/platform=macOS,variant=Mac Catalyst', artifact: 'pkg' },
};

// --- The Xcode project ----------------------------------------------------

const settingPattern = (name) => new RegExp(`\\b${name} = ([^;]+);`, 'g');

// The app target's value of a build setting: the last in the project, as
// the Android build reads it (a tests target may keep its own before it).
function projectSetting(text, name) {
  const values = [...text.matchAll(settingPattern(name))].map((m) => m[1].replace(/"/g, '').trim());
  if (!values.length) throw new Error(`no ${name} in the Xcode project`);
  return values.at(-1);
}

// The project with every CURRENT_PROJECT_VERSION set to `build`: the app
// and its extensions and tests share one number.
function withBuild(text, build) {
  return text.replace(settingPattern('CURRENT_PROJECT_VERSION'), `CURRENT_PROJECT_VERSION = ${build};`);
}

// The project with the app's MARKETING_VERSION lines set to `to`; lines
// holding another version (a tests target's) keep theirs.
function withVersion(text, from, to) {
  return text.replace(settingPattern('MARKETING_VERSION'), (line, value) =>
    (value.replace(/"/g, '').trim() === from ? `MARKETING_VERSION = ${to};` : line));
}

// The next minor version, written without a patch of 0: 1.7 → 1.8,
// 1.4.1 → 1.5 (1.5.0 with its patch of 0 left off).
function bumpMinor(version) {
  const parts = String(version).split('.');
  const [major, minor] = parts.map(Number);
  if (parts.length < 2 || parts.length > 3 || !Number.isInteger(major) || !Number.isInteger(minor)) {
    throw new Error(`MARKETING_VERSION isn't x.y or x.y.z: ${version}`);
  }
  return withoutZeroPatch(`${major}.${minor + 1}.0`);
}

// A version without a patch of 0 (1.5.0 is 1.5); any other patch stays (1.4.1).
function withoutZeroPatch(version) {
  return String(version).replace(/^(\d+\.\d+)\.0$/, '$1');
}

// --- Build numbers --------------------------------------------------------

// The highest build number anything has taken: the project's, App Store
// Connect's (every build and upload) and Play's (every release and upload).
const highestTaken = ({ project, appStore = [], play = [] }) =>
  Math.max(0, Number(project), ...appStore.map(Number), ...play.map(Number));

// The number of the next new build, on either platform: one past them all.
const nextBuild = (seen) => highestTaken(seen) + 1;

// The code for a build of the project as it stands: its own number, unless
// a store has already taken it.
const thisBuild = ({ project, appStore = [], play = [] }) =>
  Math.max(Number(project), highestTaken({ project: 0, appStore, play }) + 1);

// Android's version name for a marketing version: a patch of 0 is left
// off (1.5.0 is 1.5, 1.4.1 stays), as Play shows it to testers and players.
const androidName = (version) => String(version).replace(/^(\d+\.\d+)\.0$/, '$1');

// A version name with a patch counting further Android uploads at one
// marketing version (1.1, 1.1.1, 1.1.2, …): Play needs a new code each time
// while iOS may stay at one build. A release named only by digits at or past
// the project's build counts as its version's first.
function patchName(marketing, build, releases) {
  const ours = new RegExp(`^${marketing.replace(/\./g, '\\.')}(?:\\.(\\d+))?$`);
  let patch = -1;
  for (const r of releases) {
    const name = String(r.name ?? '');
    const m = name.match(ours);
    if (m) patch = Math.max(patch, m[1] ? Number(m[1]) : 0);
    else if (/^\d+$/.test(name) && Number(name) >= Number(build)) patch = Math.max(patch, 0);
  }
  return patch < 0 ? marketing : `${marketing}.${patch + 1}`;
}

// --- App Store Connect's replies -------------------------------------------

// asc prints one JSON document, or with --paginate sometimes one page a line.
function ascData(text) {
  const trimmed = String(text ?? '').trim();
  if (!trimmed) return [];
  try {
    const parsed = JSON.parse(trimmed);
    return Array.isArray(parsed) ? parsed : [].concat(parsed.data ?? []);
  } catch {
    return trimmed.split('\n').filter((l) => l.trim().startsWith('{'))
      .flatMap((l) => [].concat(JSON.parse(l).data ?? []));
  }
}

// Every build number among `asc builds list`'s builds.
const ascBuildNumbers = (builds) => builds.map((b) => Number(b.attributes?.version)).filter(Number.isFinite);

// The build numbers of uploads that went up or failed; one still awaiting
// its file (what an export for App Store Connect leaves) takes no number.
const ascUploadNumbers = (uploads) => uploads
  .filter((u) => (u.attributes?.state?.state ?? u.attributes?.state) !== 'AWAITING_UPLOAD')
  .map((u) => Number(u.attributes?.cfBundleVersion)).filter(Number.isFinite);

// The iOS App Store version in production for `version`, as
// "<versionString> <state>", or null. tvOS and macOS versions don't count.
// 1.4 and 1.4.0 are the same version.
function appStoreLive(versions, version) {
  for (const v of versions) {
    const a = v.attributes ?? {};
    if (a.platform !== 'IOS' || !sameVersion(a.versionString, version)) continue;
    const state = [a.appVersionState, a.appStoreState].find((s) => APP_STORE_LIVE.includes(s));
    if (state) return `${a.versionString} ${state}`;
  }
  return null;
}

// --- What's new since the last build ---------------------------------------

// The merged PRs not yet in the last build, oldest first. `isNew(oid)` says
// whether a merge commit is on the branch but not in the last build; a PR
// without one counts by its date.
function newPRs(prs, isNew, lastDate) {
  return prs
    .filter((p) => (p.mergeCommit?.oid ? isNew(p.mergeCommit.oid) : new Date(p.mergedAt) > new Date(lastDate)))
    .sort((a, b) => new Date(a.mergedAt) - new Date(b.mergedAt));
}

// A last build's number from its commit subject: "Build 77", "Build 78 (version 1.6.0)".
function buildInSubject(subject) {
  const m = String(subject ?? '').match(/^Build (\d+)\b/);
  return m ? Number(m[1]) : null;
}

const buildSubject = (build, version, bumped) => (bumped ? `Build ${build} (version ${version})` : `Build ${build}`);

// --- Notes -----------------------------------------------------------------

const DEFAULT_TOOLING = '^(Tools/|Scripts/|Android/Play/|AppStoreMetadata/|\\.github/|\\.claude/|Tests/)|\\.md$|^\\.gitignore$';
const BACKSTAGE = /\b(signing|signs|1password|keystore|upload key|release script|nightly|ci)\b/i;
const FALLBACK = '• Fixes and improvements.';

// Notes as `• ` lines: blank lines dropped, a missing bullet added.
function bulleted(text) {
  return String(text ?? '').split('\n').map((l) => l.trim()).filter(Boolean)
    .map((l) => (l.startsWith('• ') ? l : `• ${l.replace(/^[-*•]\s*/, '')}`));
}

// A PR title in plain words: "Runtime to 68b5ed6: Android speaks the
// device's language (#6)" → "Android speaks the device's language".
function plainTitle(title) {
  let t = String(title).trim().replace(/\s*\(#\d+\)$/, '');
  t = t.replace(/^Runtime( to [0-9a-f]{7,}| main [0-9a-f]{7,})?:\s*/, '').replace(/^(android|ios|play|docs?|tools?)[:,]\s*/i, '');
  return t.slice(0, 1).toUpperCase() + t.slice(1).replace(/\.$/, '');
}

// Draft notes when none are given: each merged PR that touches the game, by
// title (`notes.draft` false: the fallback line alone).
function draftNotes(prs, notes = {}) {
  const fallback = notes.fallback ?? FALLBACK;
  if (notes.draft === false) return [fallback];
  const tooling = new RegExp(notes.tooling ?? DEFAULT_TOOLING);
  const lines = prs
    .filter((p) => !p.files || p.files.some((f) => !tooling.test(f.path)))
    .filter((p) => !BACKSTAGE.test(p.title))
    .map((p) => `• ${plainTitle(p.title)}.`);
  return lines.length ? lines : [fallback];
}

// --- Settings --------------------------------------------------------------

// `{name}` in a template, from `values`; unknown names stay as written.
const fill = (template, values) => String(template).replace(/\{(\w+)\}/g, (all, k) => (k in values ? String(values[k]) : all));

// A game's release.json, checked and with its defaults.
function settingsFrom(json) {
  const s = { ...json };
  const need = (key) => { if (!s[key]) throw new Error(`release.json has no "${key}"`); };
  need('project');
  need('playDir');
  s.branch ??= 'main';
  s.submodule ??= 'Android/spritekit-android';
  s.version = { exportPrefix: 'GAME', patchNames: false, ...(s.version ?? {}) };
  if (s.appStore) s.appStore = { platforms: ['IOS'], ...s.appStore };
  for (const p of s.appStore?.platforms ?? []) if (!PLATFORMS[p]) throw new Error(`release.json: unknown platform ${p} (${Object.keys(PLATFORMS).join(', ')})`);
  s.android = { gradleProperties: [], releaseName: '{name}', art: [], ...(s.android ?? {}) };
  s.parallel = s.parallel !== false;
  s.art ??= [];
  s.notes ??= {};
  return s;
}

// The settings the nightly needs beyond the version tool's.
function nightlyProblems(s) {
  const missing = ['name', 'repo'].filter((k) => !s[k]);
  for (const k of ['app', 'externalGroup', 'team', 'scheme']) if (!s.appStore?.[k]) missing.push(`appStore.${k}`);
  return missing;
}

// --- Play ------------------------------------------------------------------

// The nightly's one Play write: internal testing, copied to closed testing,
// rolled out and sent for review. Without `send` play.js only checks the bundle.
function playRelease({ aab, name, notes, send }) {
  return ['release', '--aab', aab, '--track', 'internal', '--also', 'alpha', '--rollout', '--send-for-review',
    '--name', name, '--notes', notes, ...(send ? ['--send'] : [])];
}

// The nightly's fetches and pushes go to GitHub over HTTPS with gh's login,
// never over SSH: a run nobody watches can't answer an SSH agent's prompt
// (1Password's waits for one forever, and every later request queues behind
// it). Passed before a git command, these reach its submodules too.
const HTTPS_GIT = [
  '-c', 'credential.helper=',
  '-c', 'credential.helper=!gh auth git-credential',
  '-c', 'url.https://github.com/.insteadOf=git@github.com:',
  '-c', 'url.https://github.com/.insteadOf=ssh://git@github.com/',
];

module.exports = {
  APP_STORE_LIVE, HTTPS_GIT, PLATFORMS, projectSetting, withBuild, withVersion, bumpMinor, withoutZeroPatch,
  highestTaken, nextBuild, thisBuild, androidName, patchName, ascData, ascBuildNumbers, ascUploadNumbers, appStoreLive,
  newPRs, buildInSubject, buildSubject, bulleted, plainTitle, draftNotes, FALLBACK,
  fill, settingsFrom, nightlyProblems, playRelease, sameVersion, namesVersion,
};
