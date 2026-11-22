'use strict';
// node --test Tools/Assets/assets.test.js: assets.js's pure parts (lib.js),
// and the CLI on a scratch game.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const lib = require('./lib');

const SWIFT = `
enum Sound: String {
    case tap = "Tap"
    case step
}

final class Menu {
    func build() {
        let a = txtr("Button")
        let b = sprite("Panel", size: sz(10, 10))
        let c = tinted("Icon", .white)
        let d = sliced("Frame", size: sz(4, 4))
        let e = SKTexture(imageNamed: "Background")
        let f = UIImage(named: "Logo")
        let g = txtr("Level\\(level)")
        let h = sprite(name)
        // txtr("Commented")
        playSound(.tap)
        playSound(Sound.step)
        playMusic("Theme", loop: true)
        AudioManager.shared.play("Chime")
        playMusic(nil)
        color.tinted(0.5)
    }
}
`;

test('finds literal names, resolves enum cases and keeps run-time names apart', () => {
  const found = lib.scanSwift(SWIFT, lib.stringEnums(SWIFT));
  assert.deepStrictEqual(found.images.map((i) => i.name).sort(), ['Background', 'Button', 'Frame', 'Icon', 'Logo', 'Panel']);
  assert.deepStrictEqual(found.sounds.map((s) => s.name).sort(), ['Chime', 'Tap', 'Theme', 'step']);
  assert.deepStrictEqual(found.unchecked.map((u) => [u.kind, u.expression, u.prefix]), [
    ['images', '"Level\\(level)"', 'Level'],
    ['images', 'name', ''],
  ]);
  assert.strictEqual(found.images.find((i) => i.name === 'Button').line, 9);
});

test('reads a String enum\'s raw values, its cases\' names where none', () => {
  assert.deepStrictEqual(lib.stringEnums('enum Music: String { case menu = "Menu", play\n case `default` }'), {
    Music: { menu: 'Menu', play: 'play', default: 'default' },
  });
});

test('a case two enums share resolves only through its type', () => {
  const enums = { A: { tap: 'TapA' }, B: { tap: 'TapB' } };
  const found = lib.scanSwift('playSound(.tap)\nplaySound(B.tap)', enums);
  assert.deepStrictEqual(found.sounds.map((s) => s.name), ['TapB']);
  assert.deepStrictEqual(found.unchecked.map((u) => u.expression), ['.tap']);
});

test('compares: missing, unused, a run-time prefix\'s maybe-used, and sound variants', () => {
  const have = new Set(['Button', 'Level1', 'Level2', 'Old']);
  const r = lib.compare({ used: [{ name: 'Button' }, { name: 'Gone' }], have, unchecked: [{ prefix: 'Level' }] });
  assert.deepStrictEqual(r.missing.map((m) => m.name), ['Gone']);
  assert.deepStrictEqual(r.unused, ['Old']);
  assert.deepStrictEqual(r.maybeUsed, ['Level1', 'Level2']);
  const sounds = lib.compare({ used: [{ name: 'Gameplay' }], have: new Set(['Gameplay 1', 'Gameplay 2']), unchecked: [], variants: true });
  assert.deepStrictEqual([sounds.missing, sounds.unused], [[], []]);
});

function scratchGame() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'assets-test-'));
  const write = (file, text = '') => {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.writeFileSync(path.join(root, file), text);
  };
  write('Source/Menu.swift', SWIFT);
  for (const name of ['Button', 'Panel', 'Icon', 'Frame', 'Background', 'Unused', 'Level1']) write(`Assets.xcassets/${name}.imageset/Contents.json`, '{}');
  write('Assets.xcassets/UI/Contents.json', JSON.stringify({ properties: { 'provides-namespace': true } }));
  write('Assets.xcassets/UI/Badge.imageset/Contents.json', '{}');
  for (const name of ['Tap.wav', 'step.wav', 'Theme.mp3', 'Chime.wav', 'notes.txt']) write(`Audio/${name}`);
  write('Tools/Assets/assets.json', JSON.stringify({ catalogs: ['Assets.xcassets'], sounds: ['Audio'] }));
  return root;
}

test('the CLI reports what\'s missing and exits 1, and reports counts', () => {
  const root = scratchGame();
  const run = spawnSync(process.execPath, [path.join(__dirname, 'assets.js'), '--dir', path.join(root, 'Tools/Assets'), 'check', '--json'], { encoding: 'utf8' });
  assert.strictEqual(run.status, 1, run.stderr);
  const report = JSON.parse(run.stdout);
  assert.deepStrictEqual(report.images.missing.map((m) => [m.name, m.file]), [['Logo', 'Source/Menu.swift']]);
  assert.deepStrictEqual(report.images.unused, ['UI/Badge', 'Unused']);
  assert.deepStrictEqual(report.images.maybeUsed, ['Level1']);
  assert.deepStrictEqual(report.sounds.missing, []);
  assert.strictEqual(report.unchecked.length, 2);
  fs.rmSync(root, { recursive: true, force: true });
});

test('with nothing missing it exits 0', () => {
  const root = scratchGame();
  fs.writeFileSync(path.join(root, 'Tools/Assets/assets.json'), JSON.stringify({ catalogs: ['Assets.xcassets'], sounds: ['Audio'], ignore: ['Logo'] }));
  const run = spawnSync(process.execPath, [path.join(__dirname, 'assets.js'), '--dir', path.join(root, 'Tools/Assets'), 'check', '--quiet'], { encoding: 'utf8' });
  assert.strictEqual(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /images: 6 named, 8 there; 0 missing/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('an enum the audio configuration lists names all its sounds, and a game\'s own calls count', () => {
  const swift = 'enum Effect: String { case pop = "Pop", fizz }\nAudioManager.configure(AudioConfiguration(sounds: AudioConfiguration.sounds(Effect.self)))\nspring.kick(.pop, pace: 2)\nbadge(icon: "Star")\nbadge("Moon")';
  const found = lib.scanSwift(swift, lib.stringEnums(swift), { sounds: ['kick'], images: ['badge'] });
  assert.deepStrictEqual(found.sounds.map((s) => s.name).sort(), ['Pop', 'Pop', 'fizz']);
  assert.deepStrictEqual(found.images.map((i) => i.name), ['Moon']);
  assert.deepStrictEqual(found.unchecked.map((u) => u.expression), ['icon: "Star"']);
});

test('the splash style\'s logo is an image', () => {
  const swift = 'let style = StudioSplashScene.Style(\n    logo: "StudioLogo",\n    footer: ["Line"],\n    fontName: "Face"\n)\nlet other = Style(logo: "Mark", footer: [], fontName: "Face")\nlet run = StudioSplashScene.Style(logo: logoName, footer: [], fontName: "Face")';
  const found = lib.scanSwift(swift);
  assert.deepStrictEqual(found.images.map((i) => [i.name, i.line]), [['StudioLogo', 1], ['Mark', 6]]);
  assert.deepStrictEqual(found.unchecked.map((u) => u.expression), ['logoName']);
});

test('a helper\'s own declaration isn\'t a call', () => {
  const swift = 'func img(_ name: String) -> SKSpriteNode { sprite(name) }\nfunc  txtr(_ imageName: String) -> SKTexture { SKTexture(imageNamed: imageName) }\nlet a = img("Star")\nlet b = txtr("Moon")';
  const found = lib.scanSwift(swift, {}, { images: ['img'] });
  assert.deepStrictEqual(found.images.map((i) => i.name).sort(), ['Moon', 'Star']);
  // The helpers' bodies pass a variable on, which stays unchecked; their
  // parameter lists don't.
  assert.deepStrictEqual(found.unchecked.map((u) => u.expression).sort(), ['imageName', 'name']);
});

test('a call entry can name a labelled parameter, read wherever it stands', () => {
  const swift = [
    'let a = Piece(asset: "Rook")',
    'let b = Piece(size: sz(2, 2), asset: "Knight", tint: .red)',
    'let c = Piece(asset: Kind.queen)',
    'let d = Piece(asset: "Pawn\\(rank)")',
    'let e = Piece(size: 3)',
    'let f = Piece(frame: Frame(asset: "Inner"), asset: "Outer")',
    'let g = Foo(image: "Flag", scale: 2)',
    'let h = badge(icon: "Star")',
    'let i = mark(_: "Dot")',
    'let j = mark("Ring")',
  ].join('\n');
  const enums = { Kind: { queen: 'Queen' } };
  const found = lib.scanSwift(swift, enums, { images: ['Piece(asset:)', 'Foo(image:)', 'badge(icon:)', 'mark(_:)'] });
  assert.deepStrictEqual(found.images.map((i) => [i.name, i.line]), [
    ['Rook', 1], ['Knight', 2], ['Queen', 3], ['Outer', 6], ['Flag', 7], ['Star', 8], ['Ring', 10],
  ]);
  // A run-time name is unchecked without its label; `Piece(size:)` has no
  // asset: and names nothing; `mark(_: "Dot")` isn't Swift.
  assert.deepStrictEqual(found.unchecked.map((u) => [u.expression, u.prefix]), [['"Pawn\\(rank)"', 'Pawn'], ['_: "Dot"', '']]);
});

test('a call entry it can\'t read is an error', () => {
  assert.throws(() => lib.ownCall('Piece(asset)'), /can't read "Piece\(asset\)"/);
  assert.throws(() => lib.ownCall('Piece(size:asset:)'), /name or name\(label:\)/);
  assert.deepStrictEqual(lib.ownCall('Piece(asset:)').label, 'asset');
  const root = scratchGame();
  fs.writeFileSync(path.join(root, 'Tools/Assets/assets.json'), JSON.stringify({ catalogs: ['Assets.xcassets'], calls: { images: ['Piece(asset'] } }));
  const run = spawnSync(process.execPath, [path.join(__dirname, 'assets.js'), '--dir', path.join(root, 'Tools/Assets'), 'check'], { encoding: 'utf8' });
  assert.strictEqual(run.status, 2);
  assert.match(run.stderr, /assets: assets.json calls: can't read "Piece\(asset"/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('the CLI checks a labelled call\'s names', () => {
  const root = scratchGame();
  fs.writeFileSync(path.join(root, 'Source/Board.swift'), 'let p = Piece(size: 2, asset: "Button")\nlet q = Piece(asset: "Gone")');
  fs.writeFileSync(path.join(root, 'Tools/Assets/assets.json'), JSON.stringify({ catalogs: ['Assets.xcassets'], sounds: ['Audio'], calls: { images: ['Piece(asset:)'] } }));
  const run = spawnSync(process.execPath, [path.join(__dirname, 'assets.js'), '--dir', path.join(root, 'Tools/Assets'), 'check', '--json'], { encoding: 'utf8' });
  assert.strictEqual(run.status, 1, run.stderr);
  const report = JSON.parse(run.stdout);
  assert.deepStrictEqual(report.images.missing.map((m) => [m.name, m.file, m.line]), [['Gone', 'Source/Board.swift', 2], ['Logo', 'Source/Menu.swift', 14]]);
  fs.rmSync(root, { recursive: true, force: true });
});
