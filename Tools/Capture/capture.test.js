'use strict';
// node --test Tools/Capture/capture.test.js: the capture tools' pure parts
// (lib.js), the contact sheet, and capture.js's guards, which refuse before
// anything reaches a device.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { spawnSync, execFileSync } = require('child_process');
const lib = require('./lib');

const settings = (extra = {}) => lib.readSettings({
  name: 'example',
  languages: ['en', 'de'],
  shots: [
    { name: 'game:1', file: '1', args: ['-ShotState', 'game:1'], scene: 'GameScene', event: 'SHOT solved' },
    { name: 'title', file: '2', args: ['-ShotState', 'title'], scene: 'TitleScene', settle: 10 },
    { name: 'title-alt', file: '2-alt', args: ['-ShotState', 'title', '-NoButtons', 'YES'], scene: 'TitleScene', optional: true },
  ],
  android: { package: 'com.example.game', args: ['-ShotDir', '{appData}/files/shots'] },
  ios: { bundle: 'com.example.game' },
  ...extra,
});

test('settings take defaults and keep the game\'s own', () => {
  const s = settings({ exclude: ['AppStoreMetadata'] });
  assert.deepStrictEqual(s.exclude, [...lib.BASE_EXCLUDES, 'AppStoreMetadata']);
  assert.deepStrictEqual(s.languageArgs, ['-AppleLanguages', '({language})']);
  assert.strictEqual(s.android.timeout, 120);
  assert.strictEqual(s.android.settle, 6);
  assert.strictEqual(s.android.flatten, false);
  assert.strictEqual(s.android.app, 'Android/App');
  assert.deepStrictEqual(s.android.log, { filter: null, landed: 'scene {scene} at' });
  assert.strictEqual(s.ios.wait, 8);
  const custom = settings({ android: { package: 'p', log: { filter: 'Game:', landed: 'transition into {scene} landed' }, settle: 8 } });
  assert.deepStrictEqual(custom.android.log, { filter: 'Game:', landed: 'transition into {scene} landed' });
  assert.strictEqual(custom.android.settle, 8);
});

test('settings refuse what a run would trip over, every problem at once', () => {
  assert.throws(() => lib.readSettings({ name: 'x y', shots: [] }), (e) => /name:/.test(e.message) && /shots:/.test(e.message));
  assert.throws(() => lib.readSettings({ name: 'x', shots: [{ name: 'a', file: '1' }, { name: 'a', file: '2' }] }), /named twice/);
  assert.throws(() => lib.readSettings({ name: 'x', shots: [{ name: 'a', file: '1' }, { name: 'b', file: '1' }] }), /another shot's/);
  assert.throws(() => lib.readSettings({ name: 'x', shots: [{ name: 'a', file: '1.png' }] }), /without \.png/);
  assert.throws(() => lib.readSettings({ name: 'x', shots: [{ name: 'a', file: '1', wait: -1 }] }), /wait is seconds/);
  assert.throws(() => lib.readSettings({ name: 'x', shots: [{ name: 'a', file: '1' }], android: { package: 'p' } }), /scene, the scene Android waits for/);
  assert.throws(() => lib.readSettings({ name: 'x', shots: [{ name: 'a', file: '1', scene: 'S' }], android: { package: 'p', screen: { size: '1080', density: 420 } } }), /android\.screen/);
  assert.throws(() => lib.readSettings({ name: 'x', shots: [{ name: 'a', file: '1' }], ios: { bundle: 'b', push: [{ from: 'saves' }] } }), /ios\.push/);
  // An optional variant may share its main shot's file.
  assert.doesNotThrow(() => lib.readSettings({ name: 'x', shots: [{ name: 'a', file: '1' }, { name: 'b', file: '1', optional: true }] }));
});

test('an Android run takes android.screen, or a named one of android.screens', () => {
  const phone = { size: '1080x1920', density: 420 };
  const tablet = { size: '2880x1620', density: 360 };
  const android = lib.readSettings({ name: 'x', shots: [{ name: 'a', file: '1', scene: 'S' }], android: { package: 'p', screen: phone, screens: { tablet } } }).android;
  assert.deepStrictEqual(lib.screenFor(android), phone);
  assert.deepStrictEqual(lib.screenFor(android, 'tablet'), tablet);
  assert.throws(() => lib.screenFor(android, 'tv'), /no screen tv in android\.screens \(tablet\)/);
  assert.strictEqual(lib.screenFor({}), null);
  assert.throws(() => lib.readSettings({ name: 'x', shots: [{ name: 'a', file: '1', scene: 'S' }], android: { package: 'p', screens: { tablet: { size: '2880x1620' } } } }), /android\.screens/);
});

test('a plan takes every shot in every language, in order, named by file', () => {
  const steps = lib.plan(settings(), 'android', [], { appData: '/data/user/0/com.example.game' });
  assert.deepStrictEqual(steps.map((s) => s.file), ['en/1.png', 'en/2.png', 'de/1.png', 'de/2.png']);
  assert.deepStrictEqual(steps[2].args, ['-ShotState', 'game:1', '-AppleLanguages', '(de)', '-ShotDir', '/data/user/0/com.example.game/files/shots']);
  assert.deepStrictEqual(lib.plan(settings(), 'ios')[0].args, ['-ShotState', 'game:1', '-AppleLanguages', '(en)']);
});

test('names pick shots and languages in any mix; optional shots only by name', () => {
  assert.deepStrictEqual(lib.plan(settings(), 'ios', ['de']).map((s) => s.file), ['de/1.png', 'de/2.png']);
  assert.deepStrictEqual(lib.plan(settings(), 'ios', ['title', 'en']).map((s) => s.file), ['en/2.png']);
  assert.deepStrictEqual(lib.plan(settings(), 'ios', ['title-alt', 'en']).map((s) => s.file), ['en/2-alt.png']);
  assert.throws(() => lib.plan(settings(), 'ios', ['fr']), /no shot or language "fr"/);
  assert.throws(() => lib.plan(settings({ android: undefined }), 'android'), /no android settings/);
});

test('a game of one language writes its shots straight into the folder', () => {
  const s = settings({ languages: undefined });
  assert.deepStrictEqual(lib.plan(s, 'ios').map((x) => [x.file, x.language, x.args]), [
    ['1.png', null, ['-ShotState', 'game:1']],
    ['2.png', null, ['-ShotState', 'title']],
  ]);
});

test('args64 is base64 of the arguments as a JSON array', () => {
  const args = ['-ShotState', 'game:16', '-AppleLanguages', '(zh-Hant)', '-Note', 'a b;"c"'];
  assert.deepStrictEqual(JSON.parse(Buffer.from(lib.args64(args), 'base64').toString('utf8')), args);
});

test('a launch settles once its scene is in, its event logged and every page decoded', () => {
  const landed = 'scene GameScene at';
  const log = ['read page 1', 'read page 2', 'page 1 decoded', 'scene GameScene at 1.2'].join('\n');
  assert.strictEqual(lib.settled(log, { landed }), false);
  assert.strictEqual(lib.settled(`${log}\npage 2 decoded`, { landed }), true);
  assert.strictEqual(lib.settled(`${log}\npage 2 decoded`, { landed, event: 'SHOT popup' }), false);
  assert.strictEqual(lib.settled(`${log}\npage 2 decoded\nSHOT popup`, { landed, event: 'SHOT popup' }), true);
  assert.strictEqual(lib.settled('page 2 decoded', { landed }), false);
  assert.strictEqual(lib.settled('', {}), true);
  const filtered = lib.filterLog('Game: read page 1\nOther: read page 9\nGame: page 1 decoded', 'Game:');
  assert.strictEqual(lib.settled(filtered, {}), true);
  assert.strictEqual(lib.fill('transition into {scene} landed', { scene: 'TitleScene' }), 'transition into TitleScene landed');
  assert.strictEqual(lib.fill('{unknown}/x', {}), '{unknown}/x');
});

// A tiny PNG of `width` × `height` in colour type `colorType`, with a tRNS chunk if asked.
function png(width, height, colorType = 2, trns = false) {
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
    const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32 ? zlib.crc32(body) : 0);
    return Buffer.concat([length, body, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = colorType;
  const channels = { 0: 1, 2: 3, 4: 2, 6: 4 }[colorType];
  const raw = Buffer.alloc((width * channels + 1) * height);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    ...(trns ? [chunk('tRNS', Buffer.alloc(6))] : []),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

test('a PNG\'s header gives its size and whether it holds alpha', () => {
  assert.deepStrictEqual(lib.pngInfo(png(1080, 1920)), { width: 1080, height: 1920, colorType: 2, alpha: false });
  assert.strictEqual(lib.pngInfo(png(4, 4, 6)).alpha, true);
  assert.strictEqual(lib.pngInfo(png(4, 4, 2, true)).alpha, true);
  assert.throws(() => lib.pngInfo(Buffer.from('not a png at all, not at all, no')), /not a PNG/);
});

test('the stores\' rules: Play\'s sides and shape, no alpha, so many a set', () => {
  const info = (width, height, alpha = false) => ({ width, height, alpha });
  assert.strictEqual(lib.screenshotProblem(info(...lib.SIZES['play-phone-9x16']), 'play'), null);
  assert.strictEqual(lib.screenshotProblem(info(...lib.SIZES['play-tablet-16x9']), 'play'), null);
  assert.match(lib.screenshotProblem(info(1080, 1920, true), 'play'), /alpha/);
  assert.match(lib.screenshotProblem(info(300, 500), 'play'), /under 320/);
  assert.match(lib.screenshotProblem(info(4000, 2400), 'play'), /over 3840/);
  assert.match(lib.screenshotProblem(info(1000, 2100), 'play'), /more than 2×/);
  assert.strictEqual(lib.screenshotProblem(info(...lib.SIZES['appstore-appletv']), 'appstore'), null);
  assert.match(lib.screenshotProblem(info(1206, 2622), 'appstore', [1320, 2868]), /not 1320 × 2868/);
  assert.throws(() => lib.screenshotProblem(info(1, 1), 'steam'), /no store/);
  const nine = Array.from({ length: 9 }, (_, i) => ({ name: `${i + 1}.png`, info: info(1080, 1920) }));
  assert.deepStrictEqual(lib.setProblems(nine.slice(0, 8), 'play'), []);
  assert.match(lib.setProblems(nine, 'play').join(), /takes 8 a set/);
  assert.deepStrictEqual(lib.setProblems(nine, 'appstore'), []);
});

test('framing turns, then crops a recording to its view', () => {
  assert.deepStrictEqual(lib.framing({}), []);
  assert.deepStrictEqual(lib.framing({ turn: 'transpose=1' }), ['transpose=1']);
  assert.deepStrictEqual(lib.framing({ turn: 'transpose=2', crop: [10, 20], screen: [1274, 2266] }), ['transpose=2', 'crop=1274:2266:10:20']);
  const marks = [{ name: 'scene TitleScene', t: 1.5 }, { name: 'board', t: 2 }];
  assert.strictEqual(lib.markTime(marks, 'scene', 'TitleScene'), 1.5);
  assert.strictEqual(lib.markTime(marks, 'board'), 2);
  assert.strictEqual(lib.markTime(marks, 'win'), undefined);
});

const hasFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0;

test('a contact sheet puts a row a language, every shot as tall', { skip: !hasFfmpeg && 'no ffmpeg' }, () => {
  const { sheet, rowsOf, contactSheets } = require('./sheet');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'capture-sheet-'));
  try {
    for (const language of ['de', 'en']) {
      fs.mkdirSync(path.join(dir, 'set', language), { recursive: true });
      for (const n of [1, 2, 3]) execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', `color=c=0x336699:s=${n === 3 ? '200x100' : '90x160'}`, '-frames:v', '1', path.join(dir, 'set', language, `${n}.png`)]);
    }
    const rows = rowsOf(path.join(dir, 'set'));
    assert.deepStrictEqual(rows.map((r) => r.map((f) => path.relative(dir, f))), [['set/de/1.png', 'set/de/2.png', 'set/de/3.png'], ['set/en/1.png', 'set/en/2.png', 'set/en/3.png']]);
    const file = sheet(rows, path.join(dir, 'sheet.jpg'), { height: 100 });
    const [w, h] = execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', file], { encoding: 'utf8' }).trim().split(',').map(Number);
    // Each shot 100 tall plus 12 under each row; widths 56 + 56 + 200 plus 12 after each.
    assert.deepStrictEqual([w, h], [56 + 56 + 200 + 36, 224]);
    assert.deepStrictEqual(fs.readdirSync(dir).filter((f) => f.startsWith('.')), []);
    assert.deepStrictEqual(contactSheets(dir, ['set', 'none'], ['en', 'de']).map((f) => path.relative(dir, f)), ['review/set.jpg']);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

const cli = (...args) => spawnSync(process.execPath, [path.join(__dirname, 'capture.js'), ...args], { encoding: 'utf8', env: { ...process.env, ANDROID_SERIAL: '', CAPTURE_SETTINGS: '' } });

test('capture.js refuses before reaching a device', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'capture-cli-'));
  try {
    const file = path.join(dir, 'capture.json');
    fs.writeFileSync(file, JSON.stringify({ name: 'example', root: '.', shots: [{ name: 'a', file: '1', scene: 'S' }], android: { package: 'com.example.game' } }));
    assert.match(cli('shoot', 'android', dir).stderr, /which game\?/);
    assert.match(cli('--settings', file, 'shoot', 'android', dir).stderr, /ANDROID_SERIAL names no device/);
    assert.match(cli('--settings', file, 'shoot', 'ios', 'udid', '-', dir).stderr, /no ios settings/);
    assert.match(cli('--settings', file, 'build', 'android').stderr, /no patch script/);
    assert.match(cli('--settings', file, 'launch').stderr, /unknown command/);
    fs.writeFileSync(file, JSON.stringify({ name: 'example', shots: [] }));
    const bad = cli('--settings', file, 'shoot', 'android', dir);
    assert.strictEqual(bad.status, 2);
    assert.match(bad.stderr, /shots: a list of shots/);
    assert.strictEqual(cli('--help').status, 0);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('capture.js check passes a good set and names what\'s wrong with a bad one', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'capture-check-'));
  try {
    fs.mkdirSync(path.join(dir, 'en'));
    fs.mkdirSync(path.join(dir, 'de'));
    for (const n of [1, 2]) fs.writeFileSync(path.join(dir, 'en', `${n}.png`), png(1080, 1920));
    fs.writeFileSync(path.join(dir, 'de', '1.png'), png(1080, 1920, 6));
    const good = cli('check', path.join(dir, 'en'), '--store', 'play', '--size', '1080x1920');
    assert.strictEqual(good.status, 0, good.stdout + good.stderr);
    const bad = cli('check', dir, '--store', 'play');
    assert.strictEqual(bad.status, 1);
    assert.match(bad.stdout, /1\.png has an alpha channel/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('apple.js binds to a game without touching a simulator', () => {
  const apple = require('./apple')({ root: '/repo', bundle: 'com.example.game', project: 'Game.xcodeproj', scheme: 'Game', app: 'Game', unfoldedDuo: 'Game Duo (unfolded)' });
  assert.strictEqual(apple.appPath('/out', 'ios'), '/out/DerivedData/ios/Build/Products/Debug-iphonesimulator/Game.app');
  assert.strictEqual(apple.macBinary('/out'), '/out/DerivedData/mac/Build/Products/Debug-maccatalyst/Game.app/Contents/MacOS/Game');
  assert.strictEqual(apple.UNFOLDED_DUO, 'Game Duo (unfolded)');
  assert.match(apple.MAC_PREFS, /Library\/Preferences\/com\.example\.game\.plist$/);
  assert.throws(() => apple.requireBuilds(['tvos'], '/nowhere', 'build'), /No tvos build/);
  assert.throws(() => require('./apple')({}), /root and bundle/);
});
