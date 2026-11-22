'use strict';
// node --test Tools/Release/release.test.js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const lib = require('./lib');

const PROJECT = [
  'MARKETING_VERSION = 1.0;', 'CURRENT_PROJECT_VERSION = 7;', // a tests target
  'MARKETING_VERSION = 1.4.1;', 'CURRENT_PROJECT_VERSION = 7;',
  'MARKETING_VERSION = 1.4.1;', 'CURRENT_PROJECT_VERSION = "7";',
].join('\n');

test('the project: the app target is the last value; a bump leaves other targets alone', () => {
  assert.strictEqual(lib.projectSetting(PROJECT, 'MARKETING_VERSION'), '1.4.1');
  assert.strictEqual(lib.projectSetting(PROJECT, 'CURRENT_PROJECT_VERSION'), '7');
  assert.throws(() => lib.projectSetting('A = 1;', 'MARKETING_VERSION'), /no MARKETING_VERSION/);
  const bumped = lib.withVersion(lib.withBuild(PROJECT, 12), '1.4.1', '1.5.0');
  assert.strictEqual((bumped.match(/CURRENT_PROJECT_VERSION = 12;/g) ?? []).length, 3);
  assert.strictEqual((bumped.match(/MARKETING_VERSION = 1\.5\.0;/g) ?? []).length, 2);
  assert.match(bumped, /MARKETING_VERSION = 1\.0;/);
});

test('the minor goes up with as many parts as the version has', () => {
  assert.strictEqual(lib.bumpMinor('1.7'), '1.8');
  assert.strictEqual(lib.bumpMinor('1.4.1'), '1.5');
  assert.strictEqual(lib.bumpMinor('1.5.0'), '1.6');
  assert.strictEqual(lib.bumpMinor('2.9'), '2.10');
  assert.throws(() => lib.bumpMinor('7'), /x\.y/);
});

test('build numbers: one past everything taken; a build now keeps an untaken project number', () => {
  assert.strictEqual(lib.nextBuild({ project: 74 }), 75);
  assert.strictEqual(lib.nextBuild({ project: 74, appStore: [78], play: [76] }), 79);
  assert.strictEqual(lib.nextBuild({ project: 80, appStore: [76], play: [79] }), 81);
  assert.strictEqual(lib.nextBuild({ project: '1004', appStore: ['133', '1004'], play: [1003] }), 1005);
  assert.strictEqual(lib.thisBuild({ project: 54, play: [] }), 54);
  assert.strictEqual(lib.thisBuild({ project: 54, play: [54] }), 55);
  assert.strictEqual(lib.thisBuild({ project: 60, play: [56] }), 60);
  assert.strictEqual(lib.thisBuild({ project: 50, appStore: [58], play: [56] }), 59);
});

test('patch names count further Play uploads at one version', () => {
  const at = (releases, marketing = '1.1', build = 54) => lib.patchName(marketing, build, releases);
  assert.strictEqual(at([]), '1.1');
  assert.strictEqual(at([{ name: '54' }]), '1.1.1');
  assert.strictEqual(at([{ name: '54' }, { name: '1.1.1' }]), '1.1.2');
  assert.strictEqual(at([{ name: '1.1.2' }], '1.1', 57), '1.1.3');
  assert.strictEqual(at([{ name: '1.1.2' }], '1.2', 60), '1.2');
  assert.strictEqual(at([{ name: '53' }]), '1.1');
});

test('App Store Connect: replies a page a line, and approved versions', () => {
  assert.deepStrictEqual(lib.ascData('{"data":[{"id":"a"}]}'), [{ id: 'a' }]);
  assert.deepStrictEqual(lib.ascData('{"data":[{"id":"a"}]}\n{"data":[{"id":"b"}]}\n'), [{ id: 'a' }, { id: 'b' }]);
  assert.deepStrictEqual(lib.ascData(''), []);
  assert.deepStrictEqual(lib.ascBuildNumbers([{ attributes: { version: '77' } }, { attributes: {} }]), [77]);
  assert.deepStrictEqual(lib.ascUploadNumbers([
    { attributes: { cfBundleVersion: '78', state: { state: 'AWAITING_UPLOAD' } } },
    { attributes: { cfBundleVersion: '77', state: { state: 'COMPLETE' } } },
    { attributes: { cfBundleVersion: '76', state: { state: 'FAILED' } } },
  ]), [77, 76]);
  const versions = [
    { attributes: { versionString: '1.5', appVersionState: 'WAITING_FOR_REVIEW' } },
    { attributes: { versionString: '1.4', appVersionState: 'READY_FOR_DISTRIBUTION', appStoreState: 'READY_FOR_SALE' } },
    { attributes: { versionString: '1.3', appStoreState: 'REPLACED_WITH_NEW_VERSION' } },
  ];
  assert.strictEqual(lib.appStoreApproved(versions, '1.5.0'), null);
  assert.strictEqual(lib.appStoreApproved(versions, '1.4.0'), '1.4 READY_FOR_DISTRIBUTION');
  assert.strictEqual(lib.appStoreApproved(versions, '1.3'), '1.3 REPLACED_WITH_NEW_VERSION');
});

test('what is new: merge commits past the last build, oldest first', () => {
  const prs = [
    { number: 3, title: 'c', mergedAt: '2026-01-03T00:00:00Z', mergeCommit: { oid: 'c3' } },
    { number: 1, title: 'a', mergedAt: '2026-01-01T00:00:00Z', mergeCommit: { oid: 'a1' } },
    { number: 2, title: 'b', mergedAt: '2026-01-02T00:00:00Z', mergeCommit: { oid: 'b2' } },
    { number: 4, title: 'd', mergedAt: '2026-01-04T00:00:00Z' },
  ];
  const fresh = lib.newPRs(prs, (oid) => oid !== 'a1', '2026-01-03T12:00:00Z');
  assert.deepStrictEqual(fresh.map((p) => p.number), [2, 3, 4]);
  assert.strictEqual(lib.buildInSubject('Build 77'), 77);
  assert.strictEqual(lib.buildInSubject('Build 78 (version 1.6.0)'), 78);
  assert.strictEqual(lib.buildInSubject('Builds 3'), null);
  assert.strictEqual(lib.buildSubject(78, '1.6.0', true), 'Build 78 (version 1.6.0)');
  assert.strictEqual(lib.buildSubject(78, '1.5.0', false), 'Build 78');
});

test('notes: bullets, plain titles, tooling left out', () => {
  assert.deepStrictEqual(lib.bulleted('• One\n\n- Two\nThree\n'), ['• One', '• Two', '• Three']);
  assert.strictEqual(lib.plainTitle('Runtime to 68b5ed6: Android speaks the language (#6)'), 'Android speaks the language');
  assert.strictEqual(lib.plainTitle('android: faster loading.'), 'Faster loading');
  const prs = [
    { title: 'Brighter colours (#4)', files: [{ path: 'Source/Theme.swift' }] },
    { title: 'Release script tweaks', files: [{ path: 'Source/X.swift' }] },
    { title: 'Docs (#5)', files: [{ path: 'README.md' }, { path: 'Tools/x.js' }] },
  ];
  assert.deepStrictEqual(lib.draftNotes(prs), ['• Brighter colours.']);
  assert.deepStrictEqual(lib.draftNotes(prs.slice(2)), [lib.FALLBACK]);
  assert.deepStrictEqual(lib.draftNotes(prs, { draft: false, fallback: '• Polish.' }), ['• Polish.']);
  assert.deepStrictEqual(lib.draftNotes(prs.slice(1, 3), { tooling: '^Source/' }), ['• Docs.']);
});

test('settings: defaults, checks, templates', () => {
  assert.throws(() => lib.settingsFrom({ playDir: 'P' }), /"project"/);
  const s = lib.settingsFrom({ project: 'Game.xcodeproj', playDir: 'Android/Play', appStore: { app: '1' } });
  assert.strictEqual(s.branch, 'main');
  assert.deepStrictEqual(s.appStore.platforms, ['IOS']);
  assert.strictEqual(s.android.releaseName, '{name}');
  assert.strictEqual(s.version.exportPrefix, 'GAME');
  assert.strictEqual(s.parallel, true);
  assert.strictEqual(lib.settingsFrom({ project: 'G', playDir: 'P', parallel: false }).parallel, false);
  assert.deepStrictEqual(lib.nightlyProblems(s), ['name', 'repo', 'appStore.externalGroup', 'appStore.team', 'appStore.scheme']);
  assert.throws(() => lib.settingsFrom({ project: 'G', playDir: 'P', appStore: { platforms: ['WATCH_OS'] } }), /unknown platform/);
  assert.strictEqual(lib.fill('-Pgame.versionCode={build} {other}', { build: 9 }), '-Pgame.versionCode=9 {other}');
});

test('the Play release always goes to internal, copied to alpha, for review; --send only when asked', () => {
  const plan = lib.playRelease({ aab: 'a.aab', name: '1.5.0', notes: 'n.txt', send: false });
  assert.deepStrictEqual(plan, ['release', '--aab', 'a.aab', '--track', 'internal', '--also', 'alpha', '--rollout',
    '--send-for-review', '--name', '1.5.0', '--notes', 'n.txt']);
  assert.strictEqual(lib.playRelease({ aab: 'a', name: 'n', notes: 'n', send: true }).at(-1), '--send');
});

// A game on disk: its project, its settings and a stand-in for its play.js.
function fixture(settings = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'release-test-'));
  fs.mkdirSync(path.join(root, 'Game.xcodeproj'));
  fs.writeFileSync(path.join(root, 'Game.xcodeproj/project.pbxproj'), PROJECT);
  fs.mkdirSync(path.join(root, 'Tools/Release'), { recursive: true });
  fs.writeFileSync(path.join(root, 'Tools/Release/release.json'), JSON.stringify({ project: 'Game.xcodeproj', playDir: 'Play', ...settings }));
  fs.mkdirSync(path.join(root, 'Play'));
  fs.writeFileSync(path.join(root, 'Play/play.js'), `
    const approved = process.argv.includes('--approved');
    console.log(JSON.stringify({ package: 'com.example.game', highest: 9,
      releases: [{ track: 'internal', name: '1.4.1', status: 'completed', versionCodes: [9] }],
      uploaded: [9], ...(approved ? { approved: null } : {}) }));`);
  return root;
}
const version = (root, ...argv) => spawnSync(process.execPath, [path.join(__dirname, 'version.js'), ...argv], {
  encoding: 'utf8', env: { ...process.env, RELEASE_CONFIG: path.join(root, 'Tools/Release/release.json') },
});

test('version.js: exports for a build now, --next writes one past Play, --offline reads nothing', () => {
  const root = fixture();
  let r = version(root);
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(r.stdout, 'export GAME_VERSION_CODE=10\nexport GAME_VERSION_NAME=1.4.1\n');
  assert.match(r.stderr, /Play: highest version code 9/);
  assert.match(r.stderr, /App Store Connect: highest build not read/);
  r = version(root, '--offline', '--json');
  assert.strictEqual(JSON.parse(r.stdout).code, 7);
  r = version(root, '--next');
  assert.strictEqual(r.stdout.split('\n')[0], 'export GAME_VERSION_CODE=10');
  const text = fs.readFileSync(path.join(root, 'Game.xcodeproj/project.pbxproj'), 'utf8');
  assert.strictEqual((text.match(/CURRENT_PROJECT_VERSION = 10;/g) ?? []).length, 3);
  r = version(root, '--set', '3');
  assert.strictEqual(r.status, 1);
  assert.match(r.stderr, /at least 10/);
  assert.strictEqual(version(root, '--frobnicate').status, 1);
});

test('Android names leave off a patch of 0', () => {
  assert.strictEqual(lib.androidName('1.5.0'), '1.5');
  assert.strictEqual(lib.androidName('1.0.0'), '1.0');
  assert.strictEqual(lib.androidName('1.4.1'), '1.4.1');
  assert.strictEqual(lib.androidName('1.10.0'), '1.10');
  assert.strictEqual(lib.androidName('1.7'), '1.7');
  assert.strictEqual(lib.androidName('2.0.10'), '2.0.10');
});

test('version.js: patch names and an export prefix from the settings', () => {
  const root = fixture({ version: { patchNames: true, exportPrefix: 'MYGAME' } });
  const r = version(root);
  assert.strictEqual(r.stdout, 'export MYGAME_VERSION_CODE=10\nexport MYGAME_VERSION_NAME=1.4.1.1\n');
});

test('version.js --release: no approved release keeps the version and takes the next build', () => {
  const root = fixture();
  const r = version(root, '--release');
  assert.strictEqual(r.status, 0, r.stderr);
  assert.deepStrictEqual(JSON.parse(r.stdout), { previous: '1.4.1', version: '1.4.1', bumped: false, approved: null, build: 10, name: '1.4.1' });
});

test('nightly.js refuses --ref without --dry-run, and unknown options, before touching anything', () => {
  const root = fixture({ name: 'Game', repo: 'example/game' });
  const nightly = (...argv) => spawnSync(process.execPath, [path.join(__dirname, 'nightly.js'), ...argv], {
    encoding: 'utf8', env: { ...process.env, RELEASE_CONFIG: path.join(root, 'Tools/Release/release.json') },
  });
  let r = nightly('--ref', 'HEAD');
  assert.strictEqual(r.status, 2);
  assert.match(r.stderr, /--ref is for --dry-run only/);
  r = nightly('--dry-run', '--bogus');
  assert.strictEqual(r.status, 2);
  r = nightly('--dry-run');
  assert.strictEqual(r.status, 2);
  assert.match(r.stderr, /appStore\.app/);
});
