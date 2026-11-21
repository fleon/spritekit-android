'use strict';
// node --test Tools/Art/pack.test.js: pack.js's settings, cache key and
// cache, and one whole run on the fixture catalogs with PNG pages (no
// encoder), packed and then copied from the cache.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const pack = require('./pack');

const FIXTURES = path.join(__dirname, 'Fixtures');
const scratch = () => fs.mkdtempSync(path.join(os.tmpdir(), 'art-pack-test-'));
const write = (file, text) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };

test('flags', () => {
  assert.deepStrictEqual(pack.parseArgs([]), {});
  assert.deepStrictEqual(pack.parseArgs(['--png', '--out', 'o', '--cache', 'c']), { png: true, out: 'o', cache: 'c' });
  assert.match(pack.parseArgs(['--out']).error, /--out needs a directory/);
  assert.match(pack.parseArgs(['--cache', '--png']).error, /--cache needs a directory/);
  assert.match(pack.parseArgs(['Assets.xcassets']).error, /unknown argument/);
});

test('settings default to the game around the runtime', () => {
  const s = pack.settings({ flags: {}, env: {}, cwd: '/elsewhere', runtimeDir: '/game/Android/spritekit-android' });
  assert.deepStrictEqual(s, {
    root: '/game', catalogs: ['/game/Assets/Assets.xcassets'], out: '/game/Android/Assets', cache: null, png: false,
  });
});

test('settings come from the game, paths from its root, and flags win', () => {
  const env = {
    GAME_ANDROID_DIR: '/game/Android',
    SKA_ART_CATALOGS: ' Assets/Assets.xcassets  Android/Art/Symbols.xcassets ',
    SKA_ART_OUT: 'Build/Art',
    SKA_ART_PNG: '1',
    SKA_ART_CACHE: 'Build/ArtCache',
  };
  const s = pack.settings({ flags: {}, env, cwd: '/elsewhere', runtimeDir: '/runtime' });
  assert.deepStrictEqual(s.catalogs, ['/game/Assets/Assets.xcassets', '/game/Android/Art/Symbols.xcassets']);
  assert.strictEqual(s.out, '/game/Build/Art');
  assert.strictEqual(s.cache, '/game/Build/ArtCache');
  assert.strictEqual(s.png, true);
  const flagged = pack.settings({ flags: { out: 'o', cache: '/c' }, env, cwd: '/here', runtimeDir: '/runtime' });
  assert.strictEqual(flagged.out, '/here/o');
  assert.strictEqual(flagged.cache, '/c');
});

test('the key follows the catalogs\' contents, order and format, not where they are', () => {
  const dir = scratch();
  try {
    const tool = path.join(dir, 'tool.js');
    write(tool, 'v1');
    const a = path.join(dir, 'one/A.xcassets');
    const b = path.join(dir, 'one/B.xcassets');
    write(path.join(a, 'Contents.json'), '{}');
    write(path.join(a, 'Logo.imageset/Logo.png'), 'pixels');
    write(path.join(b, 'Contents.json'), '{}');
    const key = (catalogs, png = false) => pack.inputKey({ catalogs, png, tools: [tool] });
    const base = key([a, b]);
    assert.match(base, /^[0-9a-f]{16}$/);
    assert.strictEqual(key([a, b]), base);

    fs.cpSync(path.join(dir, 'one'), path.join(dir, 'two'), { recursive: true });
    assert.strictEqual(key([path.join(dir, 'two/A.xcassets'), path.join(dir, 'two/B.xcassets')]), base, 'another checkout');
    write(path.join(a, '.DS_Store'), 'finder');
    assert.strictEqual(key([a, b]), base, 'hidden files');

    assert.notStrictEqual(key([b, a]), base, 'order');
    assert.notStrictEqual(key([a, b], true), base, 'format');
    write(path.join(a, 'Logo.imageset/Logo.png'), 'other pixels');
    assert.notStrictEqual(key([a, b]), base, 'a changed image');
    write(path.join(a, 'Logo.imageset/Logo.png'), 'pixels');
    fs.renameSync(path.join(a, 'Logo.imageset'), path.join(a, 'Mark.imageset'));
    assert.notStrictEqual(key([a, b]), base, 'a renamed set');
    fs.renameSync(path.join(a, 'Mark.imageset'), path.join(a, 'Logo.imageset'));
    write(tool, 'v2');
    assert.notStrictEqual(key([a, b]), base, 'a changed tool');
    assert.throws(() => key([path.join(dir, 'missing.xcassets')]), /No catalog/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the output is cleared only when it is a pack or empty', () => {
  const dir = scratch();
  try {
    const out = path.join(dir, 'out');
    pack.clearOut(out);
    write(path.join(out, 'index.json'), '{}');
    pack.clearOut(out);
    assert.ok(!fs.existsSync(out));
    write(path.join(out, 'notes.txt'), 'mine');
    assert.throws(() => pack.clearOut(out), /Won't clear/);
    assert.ok(fs.existsSync(path.join(out, 'notes.txt')));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the cache keeps the most recently used packs', () => {
  const dir = scratch();
  try {
    const out = path.join(dir, 'out');
    const cache = path.join(dir, 'cache');
    write(path.join(out, 'index.json'), '{}');
    fs.mkdirSync(cache);
    const keys = ['0000000000000001', '0000000000000002', '0000000000000003', '0000000000000004'];
    keys.forEach((key, i) => {
      pack.store(cache, key, out);
      const when = new Date(Date.UTC(2026, 0, 1 + i));
      fs.utimesSync(path.join(cache, key), when, when);
    });
    pack.store(cache, keys[0], out); // already there: kept as it is
    write(path.join(cache, 'notes.txt'), 'not a pack');
    pack.prune(cache, 2);
    assert.deepStrictEqual(fs.readdirSync(cache).sort(), [keys[2], keys[3], 'notes.txt']);
    assert.ok(fs.existsSync(path.join(cache, keys[3], 'index.json')));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a run packs the game\'s catalogs, and an unchanged run copies the cached pack', () => {
  const dir = scratch();
  try {
    const game = path.join(dir, 'game');
    fs.cpSync(path.join(FIXTURES, 'Fixture.xcassets'), path.join(game, 'Assets/Assets.xcassets'), { recursive: true });
    fs.cpSync(path.join(FIXTURES, 'Symbols.xcassets'), path.join(game, 'Android/Art/Symbols.xcassets'), { recursive: true });
    const env = {
      ...process.env,
      GAME_ANDROID_DIR: path.join(game, 'Android'),
      SKA_ART_CATALOGS: 'Assets/Assets.xcassets Android/Art/Symbols.xcassets',
      SKA_ART_PNG: '1',
    };
    const run = (...args) => spawnSync(process.execPath, [path.join(__dirname, 'pack.js'), ...args], { env, cwd: dir, encoding: 'utf8' });
    const files = (root) => pack.filesUnder(root).map((file) => [file, fs.readFileSync(path.join(root, file)).toString('base64')]);

    const first = run('--cache', 'cache');
    assert.strictEqual(first.status, 0, first.stderr);
    assert.match(first.stdout, /cached pack/);
    const out = path.join(game, 'Android/Assets');
    assert.deepStrictEqual(files(out), files(path.join(FIXTURES, 'Packed')));

    const second = run('--cache', 'cache', '--out', 'copy');
    assert.strictEqual(second.status, 0, second.stderr);
    assert.match(second.stdout, /unchanged, copied pack/);
    assert.deepStrictEqual(files(path.join(dir, 'copy')), files(out));

    assert.strictEqual(run('--bogus').status, 2);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
