'use strict';
// The pure parts of strings.js: reading and writing Apple's .strings files,
// placeholders, the checks between a base table and a translation, laying a
// translation out as its base, and the translator formats (JSON, CSV,
// XLIFF 1.2). Nothing here touches the file system.

// MARK: - .strings

const UNQUOTED = /[A-Za-z0-9_$+/:.\-]/;
const SIMPLE_ESCAPES = { n: '\n', t: '\t', r: '\r', a: '\x07', b: '\b', f: '\f', v: '\v', '"': '"', '\\': '\\', "'": "'" };

// Parses a .strings file (the old-style property list Apple reads: quoted or
// bare keys and values, `/* */` and `//` comments). Each entry keeps the
// offsets of its whole `key = value;`, of its raw value, and of the comment
// right above it (its `lead`: what follows the last blank line before it).
function parseStrings(text) {
  const entries = [];
  const errors = [];
  let i = 0;
  let line = 1;
  const n = text.length;
  if (text.charCodeAt(0) === 0xfeff) i = 1;
  let lastEnd = i;

  const fail = (message) => {
    errors.push(`line ${line}: ${message}`);
  };
  const advance = (to) => {
    for (let k = i; k < to; k++) if (text[k] === '\n') line++;
    i = to;
  };
  const skipSpace = () => {
    while (i < n) {
      const c = text[i];
      if (c === ' ' || c === '\t' || c === '\r' || c === '\n') advance(i + 1);
      else if (c === '/' && text[i + 1] === '*') {
        const close = text.indexOf('*/', i + 2);
        if (close < 0) {
          fail('unclosed /* comment');
          advance(n);
          return;
        }
        advance(close + 2);
      } else if (c === '/' && text[i + 1] === '/') {
        const close = text.indexOf('\n', i);
        advance(close < 0 ? n : close);
      } else return;
    }
  };
  const readString = () => {
    const start = i;
    if (text[i] === '"') {
      let value = '';
      let k = i + 1;
      while (k < n && text[k] !== '"') {
        if (text[k] === '\\') {
          const e = text[k + 1];
          if (e === 'U' || e === 'u') {
            const hex = text.slice(k + 2, k + 6);
            if (!/^[0-9a-fA-F]{4}$/.test(hex)) return fail(`bad \\${e} escape`);
            value += String.fromCharCode(parseInt(hex, 16));
            k += 6;
          } else if (/[0-7]/.test(e)) {
            const oct = /^[0-7]{1,3}/.exec(text.slice(k + 1))[0];
            value += String.fromCharCode(parseInt(oct, 8));
            k += 1 + oct.length;
          } else if (e === undefined) {
            break;
          } else {
            value += SIMPLE_ESCAPES[e] ?? e;
            k += 2;
          }
        } else value += text[k++];
      }
      if (k >= n) return fail('unterminated string');
      advance(k + 1);
      return { value, start, end: i };
    }
    let k = i;
    while (k < n && UNQUOTED.test(text[k])) k++;
    if (k === i) return fail(`unexpected ${JSON.stringify(text[i])}`);
    advance(k);
    return { value: text.slice(start, k), start, end: k };
  };

  while (true) {
    skipSpace();
    if (i >= n || errors.length) break;
    const keyLine = line;
    const key = readString();
    if (!key) break;
    skipSpace();
    let value;
    if (text[i] === ';') value = { ...key };
    else if (text[i] === '=') {
      advance(i + 1);
      skipSpace();
      value = readString();
      if (!value) break;
      skipSpace();
    } else {
      fail(`expected = after ${JSON.stringify(key.value)}`);
      break;
    }
    if (text[i] !== ';') {
      fail(`expected ; after ${JSON.stringify(key.value)}`);
      break;
    }
    advance(i + 1);
    entries.push({
      key: key.value,
      value: value.value,
      line: keyLine,
      start: key.start,
      end: i,
      valueStart: value.start,
      valueEnd: value.end,
      leadStart: leadStart(text, lastEnd, key.start, entries.length === 0),
    });
    lastEnd = i;
  }
  return { entries, errors };
}

// Where the comment right above an entry starts: after the last blank line
// since the entry before it, else on the line after that entry.
function leadStart(text, from, to, first) {
  const between = text.slice(from, to);
  let cut = -1;
  const blank = /\n[ \t]*\n/g;
  let m;
  while ((m = blank.exec(between))) {
    cut = m.index + m[0].length;
    blank.lastIndex = m.index + 1;
  }
  if (cut >= 0) return from + cut;
  if (first) return from;
  const eol = between.indexOf('\n');
  return eol < 0 ? to : from + eol + 1;
}

// The escaping the games' generators have always written: backslashes,
// quotes and newlines.
const escape = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
const entryLine = (key, value) => `"${escape(key)}" = "${escape(value)}";`;

// MARK: - .stringsdict

// The keys of a .stringsdict's top-level dictionary.
function stringsdictKeys(xml) {
  const keys = [];
  let depth = 0;
  const tag = /<(\/?)(dict|key)\b[^>]*?(\/?)>|<\/key>/g;
  let m;
  while ((m = tag.exec(xml))) {
    if (m[2] === 'dict') {
      if (m[3]) continue;
      depth += m[1] ? -1 : 1;
    } else if (m[2] === 'key' && !m[1] && depth === 1) {
      const close = xml.indexOf('</key>', tag.lastIndex);
      keys.push(unescapeXML(xml.slice(tag.lastIndex, close)));
      tag.lastIndex = close + 6;
    }
  }
  return keys;
}

// MARK: - Placeholders

const PRINTF = /%(?:(\d+)\$)?(#@[A-Za-z0-9_]+@|[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%])/g;
const BRACES = /\{(\d+)\}/g;

// A value's placeholders, as sorted `<argument>:<conversion>` strings, so a
// translation may reorder positional ones (`%2$@ … %1$@`). `printf` reads
// Foundation's format specifiers (`%%` is a literal and no placeholder; a
// space after `%` is text, as in "50% off"), `braces` numbered `{1}` ones.
function placeholders(value, styles = ['printf']) {
  const found = [];
  if (styles.includes('printf')) {
    let next = 1;
    for (const m of value.matchAll(PRINTF)) {
      if (m[2] === '%') continue;
      const conversion = m[2].startsWith('#@') ? m[2] : m[2].replace(/^[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?/, '');
      const arg = m[1] ? Number(m[1]) : next++;
      found.push(`${arg}:${conversion}`);
    }
  }
  if (styles.includes('braces')) {
    for (const m of value.matchAll(BRACES)) found.push(`{${m[1]}}`);
  }
  return found.sort();
}

// MARK: - Checks

// What's wrong with a translation of a base table: keys it lacks or adds,
// duplicates, keys out of the base's order, and placeholders that differ.
// Each problem is { kind, key?, message }.
function compareTables(base, translation, { styles = ['printf'], order = true } = {}) {
  const problems = [];
  const baseKeys = base.map((e) => e.key);
  const baseSet = new Set(baseKeys);
  const byKey = new Map();
  for (const e of translation) {
    if (byKey.has(e.key)) problems.push({ kind: 'duplicate', key: e.key, message: `duplicate key ${JSON.stringify(e.key)} (line ${e.line})` });
    else byKey.set(e.key, e);
  }
  for (const key of baseKeys) {
    if (!byKey.has(key)) problems.push({ kind: 'missing', key, message: `missing ${JSON.stringify(key)}` });
  }
  for (const key of byKey.keys()) {
    if (!baseSet.has(key)) problems.push({ kind: 'extra', key, message: `not in the base: ${JSON.stringify(key)}` });
  }
  if (order) {
    const common = baseKeys.filter((k) => byKey.has(k));
    const seen = new Set();
    const theirs = translation.map((e) => e.key).filter((k) => baseSet.has(k) && !seen.has(k) && seen.add(k));
    const at = common.findIndex((k, index) => theirs[index] !== k);
    if (at >= 0) {
      problems.push({
        kind: 'order',
        key: theirs[at],
        message: `out of the base's order from ${JSON.stringify(theirs[at])} (line ${byKey.get(theirs[at]).line}), where the base has ${JSON.stringify(common[at])}`,
      });
    }
  }
  const baseByKey = new Map(base.map((e) => [e.key, e]));
  for (const [key, e] of byKey) {
    const b = baseByKey.get(key);
    if (!b) continue;
    const want = placeholders(b.value, styles);
    const got = placeholders(e.value, styles);
    if (want.join() !== got.join()) {
      problems.push({
        kind: 'placeholders',
        key,
        message: `placeholders of ${JSON.stringify(key)} (line ${e.line}): ${show(got)}, the base has ${show(want)}`,
      });
    }
  }
  return problems;
}

const show = (list) => (list.length ? list.join(' ') : 'none');

function duplicates(entries) {
  const seen = new Set();
  return entries.filter((e) => seen.has(e.key) || !seen.add(e.key)).map((e) => ({ kind: 'duplicate', key: e.key, message: `duplicate key ${JSON.stringify(e.key)} (line ${e.line})` }));
}

// The keys a type-safe strings layer names: each match of `pattern` (its
// first group the key; by default `case .name: return "key"`), only inside
// the body of `var <property>` when one is given, so the layer's English
// fallbacks and comments aren't taken for keys.
const LAYER_PATTERN = 'case\\s+\\.\\w+[^:\\n]*:\\s*return\\s+"((?:[^"\\\\]|\\\\.)*)"';
function layerKeys(source, { property, pattern = LAYER_PATTERN } = {}) {
  let text = source;
  if (property) {
    const head = new RegExp(`\\bvar\\s+${property}\\s*:\\s*String\\s*\\{`).exec(source);
    if (!head) return null;
    let depth = 1;
    let k = head.index + head[0].length;
    for (; k < source.length && depth; k++) {
      if (source[k] === '{') depth++;
      else if (source[k] === '}') depth--;
    }
    text = source.slice(head.index + head[0].length, k - 1);
  }
  const keys = [];
  for (const m of text.matchAll(new RegExp(pattern, 'g'))) if (m[1] !== undefined) keys.push(m[1].replace(/\\(.)/g, '$1'));
  return keys;
}

// MARK: - Layout

// A translation laid out as its base: the base file's text (comments, blank
// lines, order), each entry's value taken from the translation, under the
// translation's own header comment when it has one (`Language: French`). A
// key the translation lacks is left out with the comment right above it;
// keys the base doesn't have are dropped. Returns the text and what was left
// out and dropped.
function layOut(baseText, base, translation) {
  const values = new Map();
  for (const e of translation.entries) if (!values.has(e.key)) values.set(e.key, e.rawValue);
  const missing = [];
  const baseHeader = headerEnd(baseText, base);
  const ownHeader = translation.text === undefined ? 0 : headerEnd(translation.text, translation.entries);
  let out = ownHeader ? translation.text.slice(0, ownHeader) : '';
  let at = ownHeader ? baseHeader : 0;
  for (const e of base) {
    const raw = values.get(e.key);
    if (raw === undefined) {
      missing.push(e.key);
      out += baseText.slice(at, e.leadStart);
      at = e.end;
      const eol = /^[ \t]*\r?\n/.exec(baseText.slice(at));
      if (eol) at += eol[0].length;
      // Two blank lines don't close up round a gap.
      if (out.endsWith('\n\n') && (baseText[at] === '\n' || at === baseText.length)) at += at < baseText.length ? 1 : 0;
      continue;
    }
    out += baseText.slice(at, e.valueStart) + raw;
    at = e.valueEnd;
  }
  out += baseText.slice(at);
  const baseKeys = new Set(base.map((e) => e.key));
  const dropped = [...values.keys()].filter((k) => !baseKeys.has(k));
  return { text: out, missing, dropped };
}

// Where a file's header comment ends: the `/* */` it opens with, unless
// that's the first entry's own comment. 0 when it has none.
function headerEnd(text, entries) {
  const m = /^\uFEFF?\s*\/\*[\s\S]*?\*\//.exec(text);
  if (!m) return 0;
  const first = entries.find((e) => e.leadStart !== undefined);
  return first && m[0].length > first.leadStart ? 0 : m[0].length;
}

// A parsed file as layOut takes a translation: its text, and its entries with
// their raw value text.
const withRaw = (text, parsed) => ({
  text,
  entries: parsed.entries.map((e) => ({ ...e, rawValue: text.slice(e.valueStart, e.valueEnd) })),
});

// A raw quoted value for a new string.
const rawValue = (value) => `"${escape(value)}"`;

// MARK: - Comments

// The comment right above each entry, without its markers, as a note for
// translators.
function noteOf(text, entry) {
  const lead = text.slice(entry.leadStart, entry.start).trim();
  const block = /\/\*([\s\S]*?)\*\/\s*$/.exec(lead);
  if (block) return block[1].trim();
  const lines = lead.split('\n').map((l) => l.trim()).filter((l) => l.startsWith('//') && !/^\/\/\s*MARK:/.test(l));
  return lines.map((l) => l.replace(/^\/\/\s?/, '')).join('\n') || undefined;
}

// MARK: - CSV

function csvField(value) {
  const s = value ?? '';
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}
const formatCSV = (rows) => rows.map((r) => r.map(csvField).join(',')).join('\n') + '\n';

function parseCSV(text) {
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;
  let i = text.charCodeAt(0) === 0xfeff ? 1 : 0;
  for (; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') {
        field += '"';
        i++;
      } else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') {
      row.push(field);
      field = '';
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++;
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else field += c;
  }
  if (field !== '' || row.length) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

// MARK: - XLIFF 1.2

const escapeXML = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const unescapeXML = (s) =>
  s
    .replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');

// One <file> per language and table, as Xcode exports: `original` names the
// base table, each trans-unit's id is the key.
function formatXLIFF(files, sourceLanguage) {
  const out = ['<?xml version="1.0" encoding="UTF-8"?>', '<xliff xmlns="urn:oasis:names:tc:xliff:document:1.2" version="1.2">'];
  for (const f of files) {
    out.push(`  <file original="${escapeXML(f.original)}" source-language="${escapeXML(sourceLanguage)}" target-language="${escapeXML(f.language)}" datatype="plaintext">`);
    out.push('    <body>');
    for (const u of f.units) {
      out.push(`      <trans-unit id="${escapeXML(u.key)}" xml:space="preserve">`);
      out.push(`        <source>${escapeXML(u.source)}</source>`);
      if (u.target !== undefined) out.push(`        <target>${escapeXML(u.target)}</target>`);
      if (u.note) out.push(`        <note>${escapeXML(u.note)}</note>`);
      out.push('      </trans-unit>');
    }
    out.push('    </body>');
    out.push('  </file>');
  }
  out.push('</xliff>');
  return out.join('\n') + '\n';
}

function parseXLIFF(xml) {
  const files = [];
  const attr = (tag, name) => {
    const m = new RegExp(`\\s${name}="([^"]*)"`).exec(tag);
    return m ? unescapeXML(m[1]) : undefined;
  };
  for (const f of xml.matchAll(/<file\b([^>]*)>([\s\S]*?)<\/file>/g)) {
    const units = [];
    for (const u of f[2].matchAll(/<trans-unit\b([^>]*)>([\s\S]*?)<\/trans-unit>/g)) {
      const body = (name) => {
        const m = new RegExp(`<${name}\\b[^>]*?(?:/>|>([\\s\\S]*?)</${name}>)`).exec(u[2]);
        return m ? unescapeXML(m[1] ?? '') : undefined;
      };
      units.push({ key: attr(u[1], 'id'), source: body('source'), target: body('target'), note: body('note') });
    }
    files.push({ original: attr(f[1], 'original'), language: attr(f[1], 'target-language'), units });
  }
  return files;
}

// MARK: - Generating from JSON

// One language's entries from JSON tables keyed by their key: string values
// as they are, plural sources' `{ form: value }` under `plural` (for example
// `{key}#{form}`), forms with no text left out, anything else skipped.
function generatedEntries(sources) {
  const lines = [];
  for (const { table, plural } of sources) {
    for (const [key, value] of Object.entries(table || {})) {
      if (plural) {
        if (!value || typeof value !== 'object') continue;
        for (const [form, text] of Object.entries(value)) {
          if (typeof text === 'string' && text) lines.push([plural.replace('{key}', key).replace('{form}', form), text]);
        }
      } else if (typeof value === 'string') lines.push([key, value]);
    }
  }
  return lines;
}

module.exports = {
  parseStrings,
  escape,
  entryLine,
  stringsdictKeys,
  placeholders,
  compareTables,
  duplicates,
  layerKeys,
  LAYER_PATTERN,
  layOut,
  withRaw,
  rawValue,
  noteOf,
  formatCSV,
  parseCSV,
  formatXLIFF,
  parseXLIFF,
  escapeXML,
  unescapeXML,
  generatedEntries,
};
