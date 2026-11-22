'use strict';
// assets.js's pure parts: finding the asset and sound names a game's Swift
// passes, reading its asset catalogs and sound folders, and comparing them.

const fs = require('fs');
const path = require('path');

// A Swift string literal's body, escapes kept.
const LITERAL = String.raw`"((?:[^"\\\n]|\\.)*)"`;

// The calls that take an image's name first, and those that take a sound's.
const IMAGE_CALLS = [
  String.raw`(?<![\w.])txtr\(\s*`,
  String.raw`(?<![\w.])sprite\(\s*`,
  String.raw`(?<![\w.])tinted\(\s*`,
  String.raw`(?<![\w.])sliced\(\s*`,
  String.raw`\bSKTexture\(\s*imageNamed:\s*`,
  String.raw`\bSKSpriteNode\(\s*imageNamed:\s*`,
  String.raw`\bUIImage\(\s*named:\s*`,
  // The splash's logo: `StudioSplashScene.Style(logo: "Logo", ...)`.
  String.raw`(?<![\w])(?:StudioSplashScene\.)?Style\(\s*logo:\s*`,
];
const SOUND_CALLS = [
  String.raw`(?<![\w.])playSound\(\s*`,
  String.raw`(?<![\w.])playMusic\(\s*`,
  String.raw`\bAudioManager\.shared\.play\(\s*`,
  String.raw`\bAudioManager\.shared\.playMusic\(\s*`,
  String.raw`\bAudioManager\.shared\.playEffect\(\s*`,
  String.raw`\bAudioConfiguration\.Sound\(\s*`,
  String.raw`\bplaySoundFileNamed\(\s*`,
];

const lineOf = (text, index) => text.slice(0, index).split('\n').length;

/// Strips `//` and `/* */` comments, keeping every line where it was.
function stripComments(text) {
  return text
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .replace(/(^|[^:"])\/\/.*$/gm, (m, before) => before + ' '.repeat(m.length - before.length));
}

/// The first argument of the call starting at `start`: up to the first
/// comma or closing parenthesis at its own depth.
function firstArgument(text, start) {
  let depth = 0;
  let inString = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (c === '\\') i++;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) {
      if (depth === 0) return text.slice(start, i).trim();
      depth--;
    } else if (c === ',' && depth === 0) return text.slice(start, i).trim();
  }
  return text.slice(start).trim();
}

/// A `String` enum's cases' raw values, by case name, from Swift source:
/// `case tap = "Tap"`, or the case's own name where it has none.
function stringEnums(text) {
  const found = {};
  const source = stripComments(text);
  const header = /\benum\s+(\w+)\s*:\s*String\b[^{]*\{/g;
  let match;
  while ((match = header.exec(source))) {
    let depth = 1;
    let i = header.lastIndex;
    while (i < source.length && depth > 0) {
      if (source[i] === '{') depth++;
      else if (source[i] === '}') depth--;
      i++;
    }
    const body = source.slice(header.lastIndex, i - 1);
    const cases = {};
    for (const line of body.split('\n')) {
      const m = line.match(/^\s*case\s+(.+)$/);
      if (!m) continue;
      for (const part of m[1].split(',')) {
        const c = part.trim().match(/^`?(\w+)`?(?:\s*=\s*"((?:[^"\\]|\\.)*)")?$/);
        if (c) cases[c[1]] = c[2] ?? c[1];
      }
    }
    found[match[1]] = cases;
  }
  return found;
}

/// The names one Swift file passes: `images` and `sounds` as
/// `{ name, line }`, and `unchecked` as `{ kind, expression, line,
/// prefix }` for names built at run time (`prefix` is a literal's text
/// before its first interpolation).
/// `enums` resolves `.case` and `Type.case` arguments: by type name, each
/// case's raw value. `calls` names a game's own functions that take an
/// image's (`images`) or a sound's (`sounds`) name first; an enum passed to
/// `AudioConfiguration.sounds(T.self)` names every one of its cases.
function scanSwift(text, enums = {}, calls = {}) {
  const source = stripComments(text);
  const result = { images: [], sounds: [], unchecked: [] };
  const byCase = {};
  for (const [type, cases] of Object.entries(enums)) {
    for (const [name, raw] of Object.entries(cases)) {
      (byCase[name] ??= new Set()).add(raw);
      byCase[`${type}.${name}`] = new Set([raw]);
    }
  }
  const scan = (patterns, kind) => {
    for (const pattern of patterns) {
      const re = new RegExp(pattern, 'g');
      let match;
      while ((match = re.exec(source))) {
        // A helper's own declaration (`func img(_ name: String)`) names nothing.
        if (/\bfunc\s+$/.test(source.slice(Math.max(0, match.index - 40), match.index))) continue;
        const line = lineOf(source, match.index);
        const argument = firstArgument(source, re.lastIndex);
        const literal = argument.match(new RegExp(`^${LITERAL}$`));
        if (literal && !literal[1].includes('\\(')) {
          result[kind].push({ name: literal[1], line });
          continue;
        }
        const caseName = argument.replace(/^\./, '');
        const resolved = byCase[argument.startsWith('.') ? caseName : argument];
        if (/^\.?[\w.]+$/.test(argument) && resolved && resolved.size === 1) {
          result[kind].push({ name: [...resolved][0], line });
          continue;
        }
        if (argument === '' || argument === 'nil') continue;
        const prefix = literal ? literal[1].split('\\(')[0] : argument.startsWith('"') ? argument.slice(1).split(/\\\(|"/)[0] : '';
        result.unchecked.push({ kind, expression: argument, line, prefix });
      }
    }
  };
  const own = (names) => (names ?? []).map((name) => String.raw`(?<![\w])${name.replace(/[.$]/g, '\\$&')}\(\s*`);
  scan([...IMAGE_CALLS, ...own(calls.images)], 'images');
  scan([...SOUND_CALLS, ...own(calls.sounds)], 'sounds');
  // Every case of an enum the audio configuration lists is a sound.
  const listed = /\bAudioConfiguration\.sounds\(\s*(\w+)\.self/g;
  let match;
  while ((match = listed.exec(source))) {
    const line = lineOf(source, match.index);
    for (const raw of Object.values(enums[match[1]] ?? {})) result.sounds.push({ name: raw, line });
  }
  return result;
}

/// Every image an asset catalog holds, by the name code asks for it with:
/// `.imageset` folders (and `.spriteatlas`'s), under a folder's name where
/// it provides a namespace.
function catalogImages(catalog) {
  const names = new Set();
  const walk = (dir, namespace) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const full = path.join(dir, entry.name);
      const ext = path.extname(entry.name);
      const base = path.basename(entry.name, ext);
      if (ext === '.imageset') {
        names.add(namespace + base);
      } else if (ext === '' || ext === '.spriteatlas') {
        let provides = false;
        const contents = path.join(full, 'Contents.json');
        if (fs.existsSync(contents)) {
          try {
            provides = JSON.parse(fs.readFileSync(contents, 'utf8')).properties?.['provides-namespace'] === true;
          } catch { /* not a namespace */ }
        }
        walk(full, provides ? `${namespace}${base}/` : namespace);
      }
    }
  };
  walk(catalog, '');
  return names;
}

const SOUND_EXTENSIONS = new Set(['.wav', '.caf', '.m4a', '.mp3', '.aac', '.aiff', '.ogg']);

/// Every sound file under `dir`, by its name without the extension.
function soundFiles(dir) {
  const names = new Set();
  const walk = (folder) => {
    for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
      const full = path.join(folder, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (SOUND_EXTENSIONS.has(path.extname(entry.name).toLowerCase())) names.add(path.basename(entry.name, path.extname(entry.name)));
    }
  };
  walk(dir);
  return names;
}

/// Whether `name` is among `have`: itself, or for a sound its variants
/// (`Name 1`, `Name 2`, ... as `AudioConfiguration.variantName` makes them).
function has(have, name, variants) {
  if (have.has(name)) return true;
  if (!variants) return false;
  for (const candidate of have) if (candidate.startsWith(`${name} `) && /^\d+$/.test(candidate.slice(name.length + 1))) return true;
  return false;
}

/// What's asked for and isn't there, and what's there and never asked for.
/// An asset no literal names but whose name starts with a run-time name's
/// literal prefix is `maybeUsed`, not `unused`.
function compare({ used, have, unchecked, variants = false }) {
  const usedNames = new Set(used.map((u) => u.name));
  const missing = used.filter((u) => !has(have, u.name, variants));
  const prefixes = unchecked.map((u) => u.prefix).filter((p) => p.length > 0);
  const unused = [];
  const maybeUsed = [];
  for (const name of [...have].sort()) {
    const asked = usedNames.has(name) || (variants && [...usedNames].some((u) => name.startsWith(`${u} `) && /^\d+$/.test(name.slice(u.length + 1))));
    if (asked) continue;
    if (prefixes.some((p) => name.startsWith(p))) maybeUsed.push(name);
    else unused.push(name);
  }
  return { missing, unused, maybeUsed };
}

module.exports = { stripComments, firstArgument, stringEnums, scanSwift, catalogImages, soundFiles, has, compare };
