#!/usr/bin/env node
'use strict';
// A game's strings, for every game on this runtime: checks that every
// language's tables match the base (keys, order, placeholders) and that the
// type-safe strings layer names only keys the base has; exports them for
// translators and imports their work back (JSON, CSV or XLIFF); lays
// translations out as the base; and builds tables from JSON. A game keeps its
// settings in strings.json beside a two-line strings.js that runs this one.
// README.md beside this file.
//
//   node <game strings dir>/strings.js <command> [options]
//   node Tools/Strings/strings.js --dir <game strings dir> <command> [options]
//
// Commands:
//   check     every table in every language against the base: syntax,
//             duplicate keys, missing and extra keys, the base's order and
//             placeholders, and the strings layer's keys (exit 1 on a
//             problem). --unused lists base keys the layer doesn't name.
//   export    the strings for translators, to --out <file> or stdout:
//             --format json|csv|xliff (default json), --missing for only
//             what a language lacks.
//   import    <file>: translations from an export (by its extension or
//             --format), into each language's tables, laid out as the base.
//   sync      lays each translation out as its base: the base's comments,
//             blank lines and order, the translation's values; keys the base
//             doesn't have are dropped.
//   generate  builds tables from JSON sources (strings.json's `generate`).
//
//   --lang <l,...>   only these languages
//   --table <t,...>  only these tables (by name, without .strings)
//   --dry-run        import, sync, generate: say what would change, write
//                    nothing
//   --help, -h       print this and stop

const fs = require('fs');
const path = require('path');
const lib = require('./lib');

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
function option(name, fallback) {
  const at = argv.indexOf(name);
  if (at < 0) return fallback;
  const value = argv[at + 1];
  if (value === undefined || value.startsWith('--')) die(`${name} needs a value`);
  argv.splice(at, 2);
  return value;
}

function die(message) {
  console.error(`strings: ${message}`);
  process.exit(2);
}

if (flag('--help') || flag('-h')) {
  const source = fs.readFileSync(__filename, 'utf8').split('\n');
  console.log(source.slice(2, source.findIndex((l) => l.startsWith('const fs'))).map((l) => l.replace(/^\/\/ ?/, '')).join('\n').trim());
  process.exit(0);
}

const DIR = path.resolve(option('--dir', process.env.STRINGS_DIR ?? '') || die('run it through a game\'s strings.js, or pass --dir <game strings dir>'));
const onlyLanguages = option('--lang')?.split(',').map((s) => s.trim()).filter(Boolean);
const onlyTables = option('--table')?.split(',').map((s) => s.trim()).filter(Boolean);
const format = option('--format');
const out = option('--out');
const dryRun = flag('--dry-run');
const command = argv.find((a) => !a.startsWith('--'));

const settingsFile = path.join(DIR, 'strings.json');
const settings = fs.existsSync(settingsFile) ? JSON.parse(fs.readFileSync(settingsFile, 'utf8')) : {};
const ROOT = path.resolve(DIR, settings.root ?? '../..');
const LPROJ = path.resolve(ROOT, settings.lproj ?? 'Assets');
const BASE = settings.base ?? 'Base';
const SOURCE_LANGUAGE = settings.sourceLanguage ?? (BASE === 'Base' ? 'en' : BASE);
const STYLES = [].concat(settings.placeholders ?? 'printf');
const ORDER = settings.order ?? true;

const lprojPath = (language, table, ext = '.strings') => path.join(LPROJ, `${language}.lproj`, `${table}${ext}`);
const rel = (file) => path.relative(ROOT, file);
const read = (file) => {
  const buffer = fs.readFileSync(file);
  if (buffer[0] === 0xff && buffer[1] === 0xfe) return buffer.toString('utf16le').slice(1);
  if (buffer[0] === 0xfe && buffer[1] === 0xff) return Buffer.from(buffer).swap16().toString('utf16le').slice(1);
  return buffer.toString('utf8');
};

function languages() {
  const found = fs.existsSync(LPROJ)
    ? fs.readdirSync(LPROJ).filter((f) => f.endsWith('.lproj')).map((f) => f.slice(0, -6)).filter((l) => l !== BASE).sort()
    : [];
  const all = settings.languages ?? found;
  return onlyLanguages ? all.filter((l) => onlyLanguages.includes(l)) : all;
}

function tables() {
  const dir = path.join(LPROJ, `${BASE}.lproj`);
  const found = fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.endsWith('.strings')).map((f) => f.slice(0, -8)).sort() : [];
  const all = settings.tables ?? found;
  return onlyTables ? all.filter((t) => onlyTables.includes(t)) : all;
}

function load(file) {
  const text = read(file);
  const parsed = lib.parseStrings(text);
  return { file, text, ...parsed, ...lib.withRaw(text, parsed) };
}

// MARK: - check

function check() {
  let problems = 0;
  const report = (file, list) => {
    if (!list.length) return;
    problems += list.length;
    console.log(`${rel(file)}:`);
    for (const p of list) console.log(`  ${p.message ?? p}`);
  };
  for (const table of tables()) {
    const baseFile = lprojPath(BASE, table);
    if (!fs.existsSync(baseFile)) {
      report(baseFile, ['no base table']);
      continue;
    }
    const base = load(baseFile);
    report(baseFile, [...base.errors, ...lib.duplicates(base.entries)]);
    let checked = 0;
    for (const language of languages()) {
      const file = lprojPath(language, table);
      if (!fs.existsSync(file)) {
        report(file, ['missing: the base has this table']);
        continue;
      }
      const translation = load(file);
      report(file, translation.errors.length ? translation.errors : lib.compareTables(base.entries, translation.entries, { styles: STYLES, order: ORDER }));
      checked++;
    }
    console.log(`${table}: ${base.entries.length} keys, ${checked} translation${checked === 1 ? '' : 's'}`);
  }
  // The strings layer names keys from the tables it reads (`tables`, by
  // default every one, the base's .stringsdict files too).
  for (const layer of [].concat(settings.layer ?? []).map((l) => (typeof l === 'string' ? { file: l } : l))) {
    if (onlyTables) break;
    const file = path.resolve(ROOT, layer.file);
    if (!fs.existsSync(file)) {
      report(file, ['no strings layer here']);
      continue;
    }
    const keys = lib.layerKeys(read(file), layer);
    if (!keys) {
      report(file, [`no var ${layer.property} here`]);
      continue;
    }
    const known = new Set();
    const baseDir = path.join(LPROJ, `${BASE}.lproj`);
    for (const f of fs.existsSync(baseDir) ? fs.readdirSync(baseDir) : []) {
      const [name, ext] = [f.replace(/\.[^.]+$/, ''), path.extname(f)];
      if (layer.tables && !layer.tables.includes(name)) continue;
      if (ext === '.strings') load(path.join(baseDir, f)).entries.forEach((e) => known.add(e.key));
      else if (ext === '.stringsdict') lib.stringsdictKeys(read(path.join(baseDir, f))).forEach((k) => known.add(k));
    }
    const named = new Set(keys);
    report(file, [...named].filter((k) => !known.has(k)).map((k) => `names ${JSON.stringify(k)}, which no base table has`));
    console.log(`${rel(file)}: ${named.size} keys`);
    if (flag('--unused')) {
      const unused = [...known].filter((k) => !named.has(k));
      if (unused.length) console.log(`Base keys ${rel(file)} doesn't name (some may be built in code):\n${unused.map((k) => `  ${k}`).join('\n')}`);
    }
  }
  if (problems) {
    console.log(`${problems} problem${problems === 1 ? '' : 's'}.`);
    process.exit(1);
  }
  console.log('Every language matches the base.');
}

// MARK: - export

function units() {
  const files = [];
  for (const table of tables()) {
    const base = load(lprojPath(BASE, table));
    for (const language of languages()) {
      const file = lprojPath(language, table);
      const translation = fs.existsSync(file) ? load(file) : { entries: [] };
      const have = new Map(translation.entries.map((e) => [e.key, e.value]));
      const list = [];
      for (const e of base.entries) {
        if (flag('--missing') && have.has(e.key)) continue;
        list.push({ key: e.key, source: e.value, target: have.get(e.key), note: lib.noteOf(base.text, e) });
      }
      if (list.length) files.push({ table, language, original: `${BASE}.lproj/${table}.strings`, units: list });
    }
  }
  return files;
}

function exportStrings() {
  const kind = format ?? (out ? extension(out) : 'json');
  const files = units();
  let text;
  if (kind === 'json') {
    const json = {};
    for (const f of files) ((json[f.language] ??= {})[f.table] = f.units);
    text = JSON.stringify(json, null, 2) + '\n';
  } else if (kind === 'csv') {
    const langs = [...new Set(files.map((f) => f.language))];
    const rows = new Map();
    for (const f of files) {
      for (const u of f.units) {
        const id = `${f.table}\0${u.key}`;
        if (!rows.has(id)) rows.set(id, { table: f.table, key: u.key, note: u.note, source: u.source, targets: {} });
        rows.get(id).targets[f.language] = u.target ?? '';
      }
    }
    text = lib.formatCSV([['table', 'key', 'note', SOURCE_LANGUAGE, ...langs], ...[...rows.values()].map((r) => [r.table, r.key, r.note, r.source, ...langs.map((l) => r.targets[l] ?? '')])]);
  } else if (kind === 'xliff') text = lib.formatXLIFF(files, SOURCE_LANGUAGE);
  else die(`no format ${kind}: json, csv or xliff`);
  if (out) {
    fs.writeFileSync(out, text);
    console.error(`${files.reduce((n, f) => n + f.units.length, 0)} strings in ${files.length} table${files.length === 1 ? '' : 's'} to ${out}`);
  } else process.stdout.write(text);
}

function extension(file) {
  const ext = path.extname(file).slice(1).toLowerCase();
  return ext === 'xlf' ? 'xliff' : ext;
}

// MARK: - import and sync

// Translations by language, then table, then key.
function readTranslations(file) {
  const kind = format ?? extension(file);
  const text = read(file);
  const found = {};
  const put = (language, table, key, value) => {
    if (value === undefined || value === null || value === '') return;
    ((found[language] ??= {})[table] ??= new Map()).set(key, value);
  };
  if (kind === 'json') {
    for (const [language, byTable] of Object.entries(JSON.parse(text))) {
      for (const [table, list] of Object.entries(byTable)) {
        if (Array.isArray(list)) list.forEach((u) => put(language, table, u.key, u.target));
        else for (const [key, value] of Object.entries(list)) put(language, table, key, typeof value === 'string' ? value : value?.target);
      }
    }
  } else if (kind === 'csv') {
    const [header, ...rows] = lib.parseCSV(text);
    const at = (name) => header.indexOf(name);
    if (at('table') < 0 || at('key') < 0) die(`${file}: a CSV needs table and key columns`);
    const langs = header.map((h, i) => [h, i]).filter(([h]) => !['table', 'key', 'note', SOURCE_LANGUAGE].includes(h));
    for (const row of rows) for (const [language, i] of langs) put(language, row[at('table')], row[at('key')], row[i]);
  } else if (kind === 'xliff') {
    for (const f of lib.parseXLIFF(text)) {
      const table = path.basename(f.original ?? '', '.strings');
      for (const u of f.units) put(f.language, table, u.key, u.target);
    }
  } else die(`no format ${kind}: json, csv or xliff`);
  return found;
}

function layOutAll(incoming) {
  let changed = 0;
  let missing = 0;
  for (const table of tables()) {
    const base = load(lprojPath(BASE, table));
    if (base.errors.length) die(`${rel(base.file)}: ${base.errors[0]}`);
    for (const language of languages()) {
      const file = lprojPath(language, table);
      const added = incoming?.[language]?.[table];
      if (incoming && !added) continue;
      const translation = fs.existsSync(file) ? load(file) : { entries: [], errors: [], text: '' };
      if (translation.errors.length) die(`${rel(file)}: ${translation.errors[0]}`);
      // An imported string replaces the translation's unless it's the same.
      const current = new Map(translation.entries.map((e) => [e.key, e.value]));
      const changes = [...(added ?? [])].filter(([key, value]) => current.get(key) !== value);
      const replaced = new Set(changes.map(([key]) => key));
      const entries = translation.entries.filter((e) => !replaced.has(e.key));
      for (const [key, value] of changes) entries.push({ key, rawValue: lib.rawValue(value) });
      const result = lib.layOut(base.text, base.entries, { text: translation.text, entries });
      for (const key of added?.keys() ?? []) if (!base.entries.some((e) => e.key === key)) console.log(`${rel(file)}: skipped ${JSON.stringify(key)}, which the base doesn't have`);
      if (result.dropped.length) console.log(`${rel(file)}: dropped ${result.dropped.map((k) => JSON.stringify(k)).join(', ')}`);
      if (result.missing.length) {
        missing += result.missing.length;
        console.log(`${rel(file)}: still lacks ${result.missing.length}`);
      }
      if (result.text !== translation.text) {
        changed++;
        console.log(`${dryRun ? 'would write' : 'wrote'} ${rel(file)}`);
        if (!dryRun) {
          fs.mkdirSync(path.dirname(file), { recursive: true });
          fs.writeFileSync(file, result.text);
        }
      }
    }
  }
  console.log(`${changed} file${changed === 1 ? '' : 's'} ${dryRun ? 'would change' : 'changed'}${missing ? `; ${missing} string${missing === 1 ? '' : 's'} still to translate` : ''}.`);
}

// MARK: - generate

function generate() {
  const g = settings.generate || die('strings.json has no generate section');
  const table = g.table ?? 'Localizable';
  const langs = g.languages ?? die('generate needs its languages');
  for (const language of langs) {
    const sources = (g.sources ?? []).map((s) => {
      const file = path.resolve(ROOT, s.file.replace(/\{language\}/g, language));
      if (!fs.existsSync(file)) {
        if (s.optional) return {};
        die(`no ${rel(file)}`);
      }
      let json = JSON.parse(read(file));
      if (s.select) json = json[s.select.replace(/\{language\}/g, language)];
      return { table: json, plural: s.plural };
    });
    const lines = lib.generatedEntries(sources).map(([k, v]) => lib.entryLine(k, v));
    const file = lprojPath(language, table);
    const text = lines.join('\n') + '\n';
    const same = fs.existsSync(file) && read(file) === text;
    if (!dryRun && !same) {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, text);
    }
    console.log(`${language}: ${lines.length} strings${same ? '' : dryRun ? ' (would change)' : ''}`);
  }
  // Tables of languages no longer generated go.
  for (const folder of fs.existsSync(LPROJ) ? fs.readdirSync(LPROJ).filter((f) => f.endsWith('.lproj')) : []) {
    const language = folder.slice(0, -6);
    const file = lprojPath(language, table);
    if (langs.includes(language) || !fs.existsSync(file)) continue;
    console.log(`${dryRun ? 'would remove' : 'removed'} ${rel(file)}`);
    if (dryRun) continue;
    fs.rmSync(file);
    if (!fs.readdirSync(path.dirname(file)).length) fs.rmdirSync(path.dirname(file));
  }
}

switch (command) {
  case 'check':
    check();
    break;
  case 'export':
    exportStrings();
    break;
  case 'import': {
    const file = argv.filter((a) => !a.startsWith('--'))[1] || die('import needs a file');
    layOutAll(readTranslations(file));
    break;
  }
  case 'sync':
    layOutAll(null);
    break;
  case 'generate':
    generate();
    break;
  default:
    die(command ? `no command ${command}: check, export, import, sync or generate (--help)` : 'name a command: check, export, import, sync or generate (--help)');
}
