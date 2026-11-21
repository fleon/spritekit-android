'use strict';
// play.js's pure parts, apart so they test on any machine (play.test.js),
// with no gplay, no Play and no files.

// The tracks a beta build goes to. Production takes a build of its own.
const TESTING = ['internal', 'alpha', 'beta'];

// Play's limits on a listing, checked before gplay's own lint.
const LIMITS = { title: 30, shortDescription: 80, fullDescription: 4000 };

// What a diff's summary reports that isn't an operation: left alone, never sent.
const KEPT = ['unchanged', 'untouchedLocales', 'untouched'];

// "a, b" or "a,b" as a list of tracks.
const tracksIn = (value) => (value || '').split(',').map((t) => t.trim()).filter(Boolean);

// Why `--also` can't copy a release uploaded to `track` to `also`, or null.
function alsoProblem(track, also) {
  if (!also.length) return null;
  if (!TESTING.includes(track)) return `--also is for a release to a testing track (${TESTING.join(', ')}), not ${track}`;
  const wrong = also.filter((t) => t === track || !TESTING.includes(t));
  return wrong.length ? `--also takes other testing tracks (${TESTING.join(', ')}), not ${wrong.join(', ')}` : null;
}

// Release notes cut to Play's 500 characters a language at a line break;
// null when a single line is still over.
function cutNotes(text, limit = 500) {
  let notes = text.trim();
  while ([...notes].length > limit && notes.includes('\n')) notes = notes.slice(0, notes.lastIndexOf('\n')).trim();
  return [...notes].length > limit ? null : notes;
}

// Each listing field over Play's limit, as "<locale> <field> is n characters; Play allows m".
function overLimits(listings) {
  const over = [];
  for (const [locale, text] of Object.entries(listings ?? {})) {
    for (const [field, limit] of Object.entries(LIMITS)) {
      const length = [...(text[field] ?? '')].length;
      if (length > limit) over.push(`${locale} ${field} is ${length} characters; Play allows ${limit}`);
    }
  }
  return over;
}

// The operations a diff's summary counts, and a phrase for them.
function counted(summary = {}) {
  return Object.entries(summary).reduce((n, [k, v]) => n + (typeof v === 'number' && !KEPT.includes(k) ? v : 0), 0);
}

function describe(summary = {}) {
  const ops = Object.entries(summary).filter(([k, v]) => typeof v === 'number' && v > 0 && !KEPT.includes(k));
  const kept = Object.entries(summary)
    .filter(([k, v]) => typeof v === 'number' && v > 0 && KEPT.includes(k))
    .reduce((n, [, v]) => n + v, 0);
  const said = ops.map(([k, v]) => `${v} to ${k}`).join(', ') || 'changes';
  return kept ? `${said} (${kept} already right)` : said;
}

// The beta switch in a build's build.json (the runtime's Gradle template
// writes it from -P<game>.beta): true, false, or null when it has none.
function betaIn(json) {
  try {
    const { beta } = JSON.parse(json);
    return typeof beta === 'boolean' ? beta : null;
  } catch {
    return null;
  }
}

// From an AAB's entry list: its native libraries (<abi>/<lib>.so) and those
// without debug symbols (BUNDLE-METADATA/…/debugsymbols/<abi>/<lib>.so.sym or .dbg).
function nativeSymbols(entries) {
  const libraries = entries.map((e) => e.match(/^base\/lib\/([^/]+\/[^/]+\.so)$/)?.[1]).filter(Boolean);
  const symbols = new Set(entries
    .map((e) => e.match(/^BUNDLE-METADATA\/com\.android\.tools\.build\.debugsymbols\/([^/]+\/[^/]+\.so)\.(sym|dbg)$/)?.[1])
    .filter(Boolean));
  return { libraries, missing: libraries.filter((l) => !symbols.has(l)) };
}

// gplay's lint holds phone screenshots to 2:1, but Play takes taller ones.
// True when that is all the lint found, so Play's own commit can decide.
function onlyTallScreenshots(lintOutput) {
  const problems = lintOutput.split('\n').filter((l) => /^\s*- \[/.test(l));
  return problems.length > 0 && problems.every((l) => /phoneScreenshots #\d+\] \(ratio\)/.test(l));
}

// Whether any track has served a release (completed or rolling out): an app
// that never has sends every pending change for review with its first.
function everPublished(tracks) {
  return (tracks ?? []).some((t) => (t.releases ?? []).some((r) => r.status === 'completed' || r.status === 'inProgress'));
}

module.exports = {
  TESTING, LIMITS, KEPT, tracksIn, alsoProblem, cutNotes, overLimits, counted, describe,
  betaIn, nativeSymbols, onlyTallScreenshots, everPublished,
};
