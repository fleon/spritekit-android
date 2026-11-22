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
