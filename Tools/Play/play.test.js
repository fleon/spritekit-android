'use strict';
// node --test Tools/Play/play.test.js: play.js's pure parts (lib.js), and its argument
// guards, which refuse before anything reaches gplay or Play.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const lib = require('./lib');

test('notes are cut to 500 characters at a line break', () => {
  const line = 'x'.repeat(99);
  const notes = Array.from({ length: 8 }, () => line).join('\n');
  const cut = lib.cutNotes(notes);
  assert.ok([...cut].length <= 500);
  assert.strictEqual(cut, Array.from({ length: 5 }, () => line).join('\n'));
  assert.strictEqual(lib.cutNotes('• short\n'), '• short');
  assert.strictEqual(lib.cutNotes('y'.repeat(501)), null);
});

test('--also takes only other testing tracks', () => {
  assert.strictEqual(lib.alsoProblem('internal', ['alpha']), null);
  assert.strictEqual(lib.alsoProblem('internal', []), null);
  assert.match(lib.alsoProblem('internal', ['internal']), /not internal/);
  assert.match(lib.alsoProblem('internal', ['production']), /not production/);
  assert.match(lib.alsoProblem('production', ['alpha']), /testing track/);
  assert.deepStrictEqual(lib.tracksIn(' alpha, beta ,'), ['alpha', 'beta']);
});

test('listing fields over Play\'s limits are named', () => {
  const over = lib.overLimits({ 'en-US': { title: 't'.repeat(31), shortDescription: 's', fullDescription: 'f' } });
  assert.deepStrictEqual(over, ['en-US title is 31 characters; Play allows 30']);
  assert.deepStrictEqual(lib.overLimits({ 'de-DE': { title: 'ä'.repeat(30), shortDescription: '', fullDescription: '' } }), []);
});

test('a diff counts operations, not what it left alone', () => {
  const summary = { update: 2, create: 1, unchanged: 5, locale: 'x' };
  assert.strictEqual(lib.counted(summary), 3);
  assert.strictEqual(lib.describe(summary), '2 to update, 1 to create (5 already right)');
  assert.strictEqual(lib.counted({ unchanged: 3 }), 0);
});

test('build.json says beta, not beta, or nothing', () => {
  assert.strictEqual(lib.betaIn('{"beta":true}'), true);
  assert.strictEqual(lib.betaIn('{"beta":false}'), false);
  assert.strictEqual(lib.betaIn('{}'), null);
  assert.strictEqual(lib.betaIn('not json'), null);
});

test('native libraries without debug symbols are found', () => {
  const entries = [
    'base/lib/arm64-v8a/libgame.so', 'base/lib/arm64-v8a/libSDL3.so', 'base/assets/build.json',
    'BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/libgame.so.sym',
  ];
  assert.deepStrictEqual(lib.nativeSymbols(entries), {
    libraries: ['arm64-v8a/libgame.so', 'arm64-v8a/libSDL3.so'],
    missing: ['arm64-v8a/libSDL3.so'],
  });
});

test('only tall phone screenshots let Play\'s commit decide', () => {
  assert.ok(lib.onlyTallScreenshots('errors:\n  - [en-US phoneScreenshots #1] (ratio) too tall\n  - [en-US phoneScreenshots #2] (ratio) too tall'));
  assert.ok(!lib.onlyTallScreenshots('  - [en-US phoneScreenshots #1] (ratio) too tall\n  - [en-US icon] (size) wrong'));
  assert.ok(!lib.onlyTallScreenshots('all good'));
});

test('an app is published once any track served a release', () => {
  assert.ok(!lib.everPublished([]));
  assert.ok(!lib.everPublished([{ track: 'internal', releases: [{ status: 'draft' }] }]));
  assert.ok(lib.everPublished([{ track: 'alpha', releases: [{ status: 'completed' }] }]));
});

// The CLI against a scratch game directory: every case refuses before gplay runs.
function play(...argv) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'play-test-'));
  fs.writeFileSync(path.join(dir, 'listing.json'), JSON.stringify({ package: 'com.example.game' }));
  const run = spawnSync(process.execPath, [path.join(__dirname, 'play.js'), '--dir', dir, ...argv], { encoding: 'utf8', env: { ...process.env, PATH: '/nonexistent' } });
  fs.rmSync(dir, { recursive: true, force: true });
  return { status: run.status, text: run.stdout + run.stderr };
}

test('the CLI refuses what it must, before reaching Play', () => {
  let run = play('release', '--aab', '/nowhere.aab', '--track', 'internal', '--also', 'production', '--rollout');
  assert.strictEqual(run.status, 1);
  assert.match(run.text, /--also takes other testing tracks/);
  run = play('release', '--aab', '/nowhere.aab', '--track', 'production', '--rollout');
  assert.match(run.text, /Production is only ever a draft/);
  run = play('release', '--aab', '/nowhere.aab', '--track', 'internal', '--rollout');
  assert.match(run.text, /is not there/);
  run = play('release', '--aab', '/nowhere.aab', '--track', 'internal', '--send-for-review');
  assert.match(run.text, /--send-for-review sends a rolled-out release/);
  run = play('listing', '--offline', '--send');
  assert.strictEqual(run.status, 2);
});

test('the help is the header, read without a game', () => {
  const run = spawnSync(process.execPath, [path.join(__dirname, 'play.js'), '--help'], { encoding: 'utf8' });
  assert.strictEqual(run.status, 0);
  assert.match(run.stdout, /^Google Play, driven from a game's repository/);
  assert.match(run.stdout, /--send-for-review/);
});

test('a release name names its version however a game wrote it', () => {
  assert.ok(lib.namesVersion('1.5.0', '1.5.0'));
  assert.ok(lib.namesVersion('1002 (1.0.2)', '1.0.2'));
  assert.ok(lib.namesVersion('1.4', '1.4.0'));
  assert.ok(lib.namesVersion('1.5.0 beta', '1.5'));
  assert.ok(!lib.namesVersion('1.5.1', '1.5'));
  assert.ok(!lib.namesVersion('11.5.0', '1.5.0'));
  assert.ok(!lib.namesVersion(null, '1.0'));
});

test('what Play gave out: releases, uploads and the approved one', () => {
  const releases = lib.releasesIn([
    { track: 'production', releases: [{ name: '1002 (1.0.2)', status: 'completed', versionCodes: ['1002'] }, { name: '1.1.0', status: 'draft', versionCodes: ['1010'] }] },
    { track: 'alpha', releases: [{ name: '1.1.0', status: 'completed', versionCodes: ['1010'] }] },
  ]);
  assert.deepStrictEqual(releases[0], { track: 'production', name: '1002 (1.0.2)', status: 'completed', versionCodes: [1002] });
  assert.deepStrictEqual(lib.uploadedIn({ bundles: { bundles: [{ versionCode: 1011 }] }, apks: {} }), [1011]);
  assert.deepStrictEqual(lib.uploadedIn({}), []);
  assert.strictEqual(lib.approvedRelease(releases, '1.0.2').name, '1002 (1.0.2)');
  // A draft on production, or a release on a testing track, isn't an approval.
  assert.strictEqual(lib.approvedRelease(releases, '1.1'), null);
});
