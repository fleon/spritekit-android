'use strict';
// node --test Tools/Strings/strings.test.js: strings.js's pure parts (lib.js),
// and the CLI on a scratch game.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const lib = require('./lib');

const BASE = `/*
  Localizable.strings
  Base language: English
*/

// MARK: - Title

/* The title's play button */
"title.play" = "Play";

/* Shown with the player's score */
"score.format" = "Score: %d";
"greeting.format" = "Hello, %@! You have %1$d of %2$d.";
"quote" = "Say \\"hi\\"\\n\\U2019";
`;

test('parses keys, values, escapes, comments and lines', () => {
  const { entries, errors } = lib.parseStrings(BASE);
  assert.deepStrictEqual(errors, []);
  assert.deepStrictEqual(
    entries.map((e) => [e.key, e.value, e.line]),
    [
      ['title.play', 'Play', 9],
      ['score.format', 'Score: %d', 12],
      ['greeting.format', 'Hello, %@! You have %1$d of %2$d.', 13],
      ['quote', 'Say "hi"\n’', 14],
    ],
  );
  assert.strictEqual(BASE.slice(entries[0].leadStart, entries[0].start), '/* The title\'s play button */\n');
  assert.strictEqual(lib.noteOf(BASE, entries[1]), 'Shown with the player\'s score');
  assert.strictEqual(lib.noteOf(BASE, entries[2]), undefined);
});

test('parses bare words and shorthand entries, and reports bad syntax with its line', () => {
  assert.deepStrictEqual(lib.parseStrings('key = value;\n"same";').entries.map((e) => [e.key, e.value]), [['key', 'value'], ['same', 'same']]);
  assert.match(lib.parseStrings('"a" = "1";\n"b" = "2"\n"c" = "3";').errors[0], /line 3: expected ; after "b"/);
  assert.match(lib.parseStrings('"a" = "1;').errors[0], /unterminated/);
  assert.match(lib.parseStrings('/* open').errors[0], /unclosed/);
});

test('writes entries as the games always have', () => {
  assert.strictEqual(lib.entryLine('a "b"', 'c\\d\ne'), '"a \\"b\\"" = "c\\\\d\\ne";');
  const { entries } = lib.parseStrings(lib.entryLine('k\n"', 'v\\'));
  assert.deepStrictEqual([entries[0].key, entries[0].value], ['k\n"', 'v\\']);
});

test('placeholders: printf, positional, %% and text after a lone %', () => {
  assert.deepStrictEqual(lib.placeholders('%@ has %d of %ld'), ['1:@', '2:d', '3:ld']);
  assert.deepStrictEqual(lib.placeholders('%2$@ before %1$@'), lib.placeholders('%1$@ after %2$@'));
  assert.deepStrictEqual(lib.placeholders('50% off, 100%% sure'), []);
  assert.deepStrictEqual(lib.placeholders('%.1f%% done, %02d:%02d'), ['1:f', '2:d', '3:d']);
  assert.deepStrictEqual(lib.placeholders('You found %#@words@.'), ['1:#@words@']);
  assert.deepStrictEqual(lib.placeholders('{2} and {1}', ['braces']), ['{1}', '{2}']);
  assert.deepStrictEqual(lib.placeholders('{1} %d', ['printf', 'braces']), ['1:d', '{1}']);
});

test('compares a translation with its base', () => {
  const base = lib.parseStrings(BASE).entries;
  const good = lib.parseStrings('"title.play" = "Jouer";\n"score.format" = "Score : %d";\n"greeting.format" = "Salut %@ ! %2$d sur %1$d.";\n"quote" = "x";').entries;
  assert.deepStrictEqual(lib.compareTables(base, good), []);
  const bad = lib.parseStrings('"score.format" = "Score";\n"title.play" = "Jouer";\n"extra" = "?";\n"title.play" = "Encore";').entries;
  const kinds = lib.compareTables(base, bad).map((p) => `${p.kind}:${p.key}`);
  assert.deepStrictEqual(kinds, [
    'duplicate:title.play',
    'missing:greeting.format',
    'missing:quote',
    'extra:extra',
    'order:score.format',
    'placeholders:score.format',
  ]);
  assert.deepStrictEqual(lib.compareTables(base, bad, { order: false }).map((p) => p.kind).includes('order'), false);
  assert.deepStrictEqual(lib.duplicates(bad).map((p) => p.key), ['title.play']);
});

test('reads the keys a strings layer names', () => {
  const swift = `enum LocalizedString {
    case play, score(Int)
    private var key: String {
        switch self {
        case .play: return "title.play"
        case .score: return "score.format"
        }
    }
    private var fallback: String {
        switch self {
        case .play: return "Play"
        case .score: return "Score: %d"
        }
    }
}`;
  assert.deepStrictEqual(lib.layerKeys(swift, { property: 'key' }), ['title.play', 'score.format']);
  assert.deepStrictEqual(lib.layerKeys(swift), ['title.play', 'score.format', 'Play', 'Score: %d']);
  assert.strictEqual(lib.layerKeys(swift, { property: 'rawKey' }), null);
  assert.deepStrictEqual(lib.layerKeys('K.a = s("one")\nK.b = s("two")', { pattern: 's\\("([^"]+)"\\)' }), ['one', 'two']);
});

test('reads the keys a @LocalizedStrings layer names', () => {
  const swift = `@LocalizedStrings
enum LocalizedString {
    @L("title.play", "Play", comment: "Title button")
    case play
    @L( "score.format", "Score: %d") case score(Int)
    @L("quote.\\"mark\\"") case quote
    @L(.custom) case kind(Kind)

    private var customKey: String {
        switch self {
        case .kind: return "kind.small"
        default: return ""
        }
    }
}`;
  assert.deepStrictEqual(lib.layerKeys(swift), ['title.play', 'score.format', 'quote."mark"', 'kind.small']);
  assert.deepStrictEqual(lib.layerKeys(swift, { property: 'key' }), ['title.play', 'score.format', 'quote."mark"']);
  assert.deepStrictEqual(lib.layerKeys(swift, { property: 'customKey' }), ['kind.small', 'title.play', 'score.format', 'quote."mark"']);
  assert.deepStrictEqual(lib.layerKeys(swift, { pattern: 'return "([^"]+)"' }), ['kind.small']);
  assert.strictEqual(lib.layerKeys('enum E { case a }', { property: 'key' }), null);
});

test('reads a .stringsdict\'s top-level keys', () => {
  const xml = `<plist version="1.0"><dict>
    <key>words.format</key><dict><key>NSStringLocalizedFormatKey</key><string>%#@w@</string><key>w</key><dict><key>one</key><string>%d word</string></dict></dict>
    <key>a &amp; b</key><dict/>
  </dict></plist>`;
  assert.deepStrictEqual(lib.stringsdictKeys(xml), ['words.format', 'a & b']);
});

test('lays a translation out as its base, under its own header', () => {
  const base = lib.parseStrings(BASE);
  const text = '/* Langue : français */\n\n"quote" = "Dis \\"salut\\"";\n"title.play" = "Jouer";\n"gone" = "x";\n';
  const translation = lib.withRaw(text, lib.parseStrings(text));
  const result = lib.layOut(BASE, base.entries, translation);
  assert.deepStrictEqual(result.missing, ['score.format', 'greeting.format']);
  assert.deepStrictEqual(result.dropped, ['gone']);
  assert.strictEqual(result.text, '/* Langue : français */\n\n// MARK: - Title\n\n/* The title\'s play button */\n"title.play" = "Jouer";\n\n"quote" = "Dis \\"salut\\"";\n');
  // A translation already laid out comes back unchanged.
  const full = BASE.replace('"Play"', '"Jouer"');
  assert.strictEqual(lib.layOut(BASE, base.entries, lib.withRaw(full, lib.parseStrings(full))).text, full);
});

test('CSV and XLIFF round trips', () => {
  const rows = [['table', 'key', 'en'], ['T', 'a,b', 'say "hi"\nthere'], ['T', 'plain', '']];
  assert.deepStrictEqual(lib.parseCSV(lib.formatCSV(rows)), rows);
  const files = [{ original: 'Base.lproj/T.strings', language: 'fr', units: [{ key: 'a<b>', source: 'A & "B"', target: 'à', note: 'n' }, { key: 'c', source: 'C' }] }];
  const back = lib.parseXLIFF(lib.formatXLIFF(files, 'en'));
  assert.deepStrictEqual(back, [{ original: 'Base.lproj/T.strings', language: 'fr', units: [{ key: 'a<b>', source: 'A & "B"', target: 'à', note: 'n' }, { key: 'c', source: 'C', target: undefined, note: undefined }] }]);
});

test('generates entries from JSON tables', () => {
  const entries = lib.generatedEntries([
    { table: { Hello: 'Bonjour', skipped: 3 } },
    { table: { '{1} apples': { one: '{1} pomme', other: '{1} pommes', few: '' }, odd: '' }, plural: '{key}#{form}' },
    { table: undefined },
  ]);
  assert.deepStrictEqual(entries, [['Hello', 'Bonjour'], ['{1} apples#one', '{1} pomme'], ['{1} apples#other', '{1} pommes']]);
});

// MARK: - The CLI on a scratch game

function scratchGame() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'strings-'));
  const dir = path.join(root, 'Tools', 'Strings');
  fs.mkdirSync(dir, { recursive: true });
  const put = (file, text) => {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.writeFileSync(path.join(root, file), text);
  };
  put('Assets/Base.lproj/Localizable.strings', BASE);
  put('Assets/fr.lproj/Localizable.strings', '/* fr */\n\n"title.play" = "Jouer";\n\n"score.format" = "Score : %d";\n"greeting.format" = "Salut %@ ! %1$d / %2$d";\n"quote" = "q";\n');
  put('Assets/de.lproj/Localizable.strings', '"title.play" = "Spielen";\n"score.format" = "Punkte";\n');
  put('Source/LocalizedString.swift', 'private var key: String {\n  switch self {\n  case .play: return "title.play"\n  case .gone: return "missing.key"\n  }\n}\n');
  fs.writeFileSync(path.join(dir, 'strings.json'), JSON.stringify({ layer: { file: 'Source/LocalizedString.swift', property: 'key' } }));
  return { root, dir };
}

const run = (dir, ...args) => spawnSync(process.execPath, [path.join(__dirname, 'strings.js'), '--dir', dir, ...args], { encoding: 'utf8' });

test('check reports each language\'s problems and the layer\'s unknown keys', () => {
  const { root, dir } = scratchGame();
  const result = run(dir, 'check');
  assert.strictEqual(result.status, 1);
  assert.match(result.stdout, /de\.lproj\/Localizable\.strings:\n {2}missing "greeting\.format"\n {2}missing "quote"\n {2}placeholders of "score\.format"/);
  assert.doesNotMatch(result.stdout, /fr\.lproj/);
  assert.match(result.stdout, /names "missing\.key", which no base table has/);
  assert.match(run(dir, 'check', '--lang', 'fr', '--table', 'Localizable').stdout, /Every language matches the base/);
  fs.rmSync(root, { recursive: true });
});

test('export --missing, then import, fills a language in the base\'s layout', () => {
  const { root, dir } = scratchGame();
  const exported = JSON.parse(run(dir, 'export', '--missing', '--lang', 'de').stdout);
  assert.deepStrictEqual(exported.de.Localizable.map((u) => u.key), ['greeting.format', 'quote']);
  exported.de.Localizable[0].target = 'Hallo %@! %1$d von %2$d.';
  exported.de.Localizable[1].target = 'Zitat';
  const file = path.join(root, 'de.json');
  fs.writeFileSync(file, JSON.stringify(exported));
  assert.strictEqual(run(dir, 'import', file, '--dry-run').status, 0);
  assert.strictEqual(fs.readFileSync(path.join(root, 'Assets/de.lproj/Localizable.strings'), 'utf8'), '"title.play" = "Spielen";\n"score.format" = "Punkte";\n');
  const imported = run(dir, 'import', file);
  assert.match(imported.stdout, /wrote Assets\/de\.lproj\/Localizable\.strings/);
  const de = fs.readFileSync(path.join(root, 'Assets/de.lproj/Localizable.strings'), 'utf8');
  assert.strictEqual(de, BASE.replace('"Play"', '"Spielen"').replace('"Score: %d"', '"Punkte"').replace('"Hello, %@! You have %1$d of %2$d."', '"Hallo %@! %1$d von %2$d."').replace('"Say \\"hi\\"\\n\\U2019"', '"Zitat"'));
  fs.rmSync(root, { recursive: true });
});

test('generate builds tables from JSON and removes ones no longer generated', () => {
  const { root, dir } = scratchGame();
  fs.mkdirSync(path.join(root, 'i18n'));
  fs.writeFileSync(path.join(root, 'i18n/en.json'), JSON.stringify({ Hi: 'Hi' }));
  fs.writeFileSync(path.join(root, 'i18n/fr.json'), JSON.stringify({ Hi: 'Salut' }));
  fs.writeFileSync(path.join(root, 'extra.json'), JSON.stringify({ fr: { Bye: 'Ciao' } }));
  fs.writeFileSync(path.join(dir, 'strings.json'), JSON.stringify({ lproj: 'Out', base: 'en', generate: { languages: ['en', 'fr'], sources: [{ file: 'i18n/{language}.json' }, { file: 'extra.json', select: '{language}' }] } }));
  fs.mkdirSync(path.join(root, 'Out/old.lproj'), { recursive: true });
  fs.writeFileSync(path.join(root, 'Out/old.lproj/Localizable.strings'), '');
  const result = run(dir, 'generate');
  assert.strictEqual(result.status, 0, result.stderr);
  assert.strictEqual(result.stdout, 'en: 1 strings\nfr: 2 strings\nremoved Out/old.lproj/Localizable.strings\n');
  assert.strictEqual(fs.readFileSync(path.join(root, 'Out/fr.lproj/Localizable.strings'), 'utf8'), '"Hi" = "Salut";\n"Bye" = "Ciao";\n');
  assert.strictEqual(fs.existsSync(path.join(root, 'Out/old.lproj')), false);
  fs.rmSync(root, { recursive: true });
});

test('refuses without a game directory or a known command', () => {
  const none = spawnSync(process.execPath, [path.join(__dirname, 'strings.js'), 'check'], { encoding: 'utf8', env: { ...process.env, STRINGS_DIR: '' } });
  assert.strictEqual(none.status, 2);
  assert.match(none.stderr, /--dir/);
  const { root, dir } = scratchGame();
  assert.strictEqual(run(dir, 'nope').status, 2);
  fs.rmSync(root, { recursive: true });
});
