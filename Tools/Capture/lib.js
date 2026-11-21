'use strict';
// The capture tools' pure parts: a game's capture.json read into a plan
// (shots, languages, launch arguments, file names), when a launch has
// settled by its log, the stores' rules for a screenshot, and the ffmpeg
// framing of a recording. Nothing here runs a device; capture.test.js
// tests it all.
const fs = require('fs');
const path = require('path');

// MARK: - Settings

// What every scratch copy leaves out: history, build products, and
// whatever a game's own `exclude` adds.
const BASE_EXCLUDES = ['.git', '.claude', 'node_modules', '.build', '/Android/App/app/build', '/Android/App/.gradle'];
const LANGUAGE_ARGS = ['-AppleLanguages', '({language})'];
// What the Android renderer logs as it first draws a scene (SceneRenderer).
const LANDED = 'scene {scene} at';
// The Android renderer logs every texture page it reads (AssetBundle) and
// decodes (SceneRenderer); a screen has settled once none is still decoding.
const PAGE_READ = /read page (\d+)/g;
const PAGE_DECODED = /page (\d+) decoded/g;

const isStrings = (v) => Array.isArray(v) && v.every((s) => typeof s === 'string');

// Checks a capture.json (already parsed) and fills in its defaults. Throws
// with every problem at once.
function readSettings(json, where = 'capture.json') {
  const problems = [];
  const s = json && typeof json === 'object' ? json : {};
  if (typeof s.name !== 'string' || !/^[\w.-]+$/.test(s.name)) problems.push('name: a short name for the work folder (letters, digits, _ . -)');
  if (s.languages !== undefined && !(isStrings(s.languages) && s.languages.length)) problems.push('languages: a list of language codes');
  if (s.languageArgs !== undefined && !isStrings(s.languageArgs)) problems.push('languageArgs: a list of strings');
  if (s.exclude !== undefined && !isStrings(s.exclude)) problems.push('exclude: a list of rsync patterns');
  if (!Array.isArray(s.shots) || !s.shots.length) problems.push('shots: a list of shots');
  const names = new Set();
  const files = new Set();
  (Array.isArray(s.shots) ? s.shots : []).forEach((shot, i) => {
    const at = `shots[${i}]`;
    if (typeof shot?.name !== 'string' || !shot.name) return problems.push(`${at}: needs a name`);
    if (names.has(shot.name)) problems.push(`${at}: ${shot.name} named twice`);
    names.add(shot.name);
    if (typeof shot.file !== 'string' || !/^[\w.-]+$/.test(shot.file) || /\.png$/i.test(shot.file)) problems.push(`${at} (${shot.name}): file is a name without .png (letters, digits, _ . -)`);
    else if (!shot.optional && files.has(shot.file)) problems.push(`${at} (${shot.name}): file ${shot.file} is another shot's`);
    if (!shot.optional) files.add(shot.file);
    if (shot.args !== undefined && !isStrings(shot.args)) problems.push(`${at} (${shot.name}): args is a list of strings`);
    for (const key of ['settle', 'wait']) {
      if (shot[key] !== undefined && !(typeof shot[key] === 'number' && shot[key] >= 0)) problems.push(`${at} (${shot.name}): ${key} is seconds`);
    }
  });
  const android = s.android;
  if (android !== undefined) {
    if (typeof android.package !== 'string') problems.push('android.package: the app\'s package');
    if (android.screen !== undefined && !(/^\d+x\d+$/.test(android.screen.size ?? '') && Number.isInteger(android.screen.density))) {
      problems.push('android.screen: { "size": "<w>x<h>", "density": <dpi> }');
    }
    if (android.log !== undefined && typeof android.log.landed !== 'string') problems.push('android.log.landed: the line a scene logs once it is in ({scene} for its name)');
    for (const shot of s.shots ?? []) {
      if (shot && typeof shot.scene !== 'string' && (android.log?.landed ?? LANDED).includes('{scene}')) problems.push(`shot ${shot.name}: scene, the scene Android waits for`);
    }
  }
  const ios = s.ios;
  if (ios !== undefined && typeof ios.bundle !== 'string') problems.push('ios.bundle: the app\'s bundle ID');
  for (const [platform, block] of [['android', android], ['ios', ios]]) {
    if (block?.args !== undefined && !isStrings(block.args)) problems.push(`${platform}.args: a list of strings`);
    if (block?.push !== undefined && !(Array.isArray(block.push) && block.push.every((p) => typeof p?.from === 'string' && typeof p?.to === 'string'))) {
      problems.push(`${platform}.push: [{ "from": "<folder in the work folder>", "to": "<folder in the app's data>" }]`);
    }
  }
  if (problems.length) throw new Error(`${where}:\n  ${problems.join('\n  ')}`);
  return {
    ...s,
    languageArgs: s.languageArgs ?? LANGUAGE_ARGS,
    exclude: [...BASE_EXCLUDES, ...(s.exclude ?? [])],
    android: android && {
      app: 'Android/App',
      timeout: 120,
      settle: 6,
      flatten: false,
      args: [],
      push: [],
      ...android,
      log: { filter: null, landed: LANDED, ...(android.log ?? {}) },
    },
    ios: ios && { wait: 8, args: [], push: [], ...ios },
  };
}

// `{name}` in a string from its value in `vars`; unknown names stay.
const fill = (text, vars) => text.replace(/\{(\w+)\}/g, (whole, key) => (vars[key] !== undefined ? String(vars[key]) : whole));

// Which shots and languages a run takes: every non-optional shot and every
// language, or those `filters` name (a shot's name or a language, in any
// mix). Throws on a name that is neither.
function selection(settings, filters = []) {
  const shots = settings.shots;
  const languages = settings.languages ?? [];
  const picked = { shots: [], languages: [] };
  for (const f of filters) {
    if (shots.some((s) => s.name === f)) picked.shots.push(f);
    else if (languages.includes(f)) picked.languages.push(f);
    else throw new Error(`no shot or language "${f}" (shots: ${shots.map((s) => s.name).join(', ')}${languages.length ? `; languages: ${languages.join(' ')}` : ''})`);
  }
  return {
    shots: picked.shots.length ? picked.shots.map((n) => shots.find((s) => s.name === n)) : shots.filter((s) => !s.optional),
    languages: picked.languages.length ? picked.languages : (languages.length ? languages : [null]),
  };
}

// Every capture of a run, in order (each language's set in turn): the shot,
// its language (null for a game that shoots one), its launch arguments and
// its file relative to the output folder (`<language>/<file>.png`, or
// `<file>.png`).
function plan(settings, platform, filters = [], vars = {}) {
  const block = settings[platform];
  if (!block) throw new Error(`capture.json has no ${platform} settings`);
  const { shots, languages } = selection(settings, filters);
  return languages.flatMap((language) => shots.map((shot) => ({
    shot,
    language,
    args: [
      ...(shot.args ?? []),
      ...(language ? settings.languageArgs.map((a) => fill(a, { language })) : []),
      ...block.args.map((a) => fill(a, vars)),
    ],
    file: language ? path.join(language, `${shot.file}.png`) : `${shot.file}.png`,
  })));
}

// The `args64` extra that hands launch arguments to the Android app
// (MainActivity.getArguments): base64 of a JSON array.
const args64 = (args) => Buffer.from(JSON.stringify(args), 'utf8').toString('base64');

// Whether an Android launch has settled, by its log so far: the scene's
// `landed` line logged, `event` (if any) logged, and every texture page
// it read decoded.
function settled(log, { landed, event } = {}) {
  if (landed && !log.includes(landed)) return false;
  if (event && !log.includes(event)) return false;
  const decoded = new Set([...log.matchAll(PAGE_DECODED)].map((m) => m[1]));
  return [...log.matchAll(PAGE_READ)].every((m) => decoded.has(m[1]));
}

// The log lines `filter` keeps (all of them when it's null).
const filterLog = (log, filter) => (filter ? log.split('\n').filter((l) => l.includes(filter)).join('\n') : log);

// MARK: - Images and stores

// A PNG's size and whether it can hold alpha, from its header.
function pngInfo(buffer) {
  if (buffer.length < 33 || buffer.toString('latin1', 1, 4) !== 'PNG') throw new Error('not a PNG');
  const colorType = buffer[25];
  let alpha = colorType === 4 || colorType === 6;
  // A palette or truecolour image with a tRNS chunk carries transparency too.
  for (let at = 8; !alpha && at + 8 <= buffer.length;) {
    const length = buffer.readUInt32BE(at);
    const type = buffer.toString('latin1', at + 4, at + 8);
    if (type === 'tRNS') alpha = true;
    if (type === 'IDAT' || type === 'IEND') break;
    at += 12 + length;
  }
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20), colorType, alpha };
}

function isCompletePNG(file) {
  try {
    const data = fs.readFileSync(file);
    return data.length > 100 && data.subarray(data.length - 8, data.length - 4).toString('latin1') === 'IEND';
  } catch { return false; }
}

// What each store takes. Play: sides of 320 to 3840 px, the long side at
// most twice the short, eight to a slot. App Store Connect: ten to a set.
// Neither takes an alpha channel.
const STORES = {
  play: { min: 320, max: 3840, maxRatio: 2, perSet: 8 },
  appstore: { perSet: 10 },
};

// The sizes the games' sets are made at, by the slot they fill.
const SIZES = {
  'appstore-iphone-6.9': [1320, 2868],
  'appstore-iphone-6.3': [1206, 2622],
  'appstore-ipad-13': [2064, 2752],
  'appstore-mac': [2880, 1800],
  'appstore-appletv': [3840, 2160],
  'appstore-duo-closed': [1398, 2034],
  'appstore-duo-open': [2853, 2007],
  'play-phone-9x16': [1080, 1920],
  'play-tablet-16x9': [2880, 1620],
};

// Why a screenshot of `info` (pngInfo) won't go to `store`, or null.
function screenshotProblem(info, store, size) {
  const rules = STORES[store];
  if (!rules) throw new Error(`no store "${store}" (stores: ${Object.keys(STORES).join(', ')})`);
  const { width, height } = info;
  if (info.alpha) return 'has an alpha channel (flatten it to RGB)';
  if (size && (width !== size[0] || height !== size[1])) return `is ${width} × ${height}, not ${size[0]} × ${size[1]}`;
  if (rules.min && Math.min(width, height) < rules.min) return `is ${width} × ${height}: a side under ${rules.min} px`;
  if (rules.max && Math.max(width, height) > rules.max) return `is ${width} × ${height}: a side over ${rules.max} px`;
  if (rules.maxRatio && Math.max(width, height) > rules.maxRatio * Math.min(width, height)) return `is ${width} × ${height}: the long side more than ${rules.maxRatio}× the short`;
  return null;
}

// Every problem with a set of screenshots for `store`: each file's, and too
// many of them.
function setProblems(files, store, size) {
  const problems = files.flatMap(({ name, info }) => {
    const problem = screenshotProblem(info, store, size);
    return problem ? [`${name} ${problem}`] : [];
  });
  if (files.length > STORES[store].perSet) problems.push(`${files.length} screenshots: ${store} takes ${STORES[store].perSet} a set`);
  return problems;
}

// MARK: - Recordings

// ffmpeg's filters that stand a recording up and frame its capture's
// screen: `turn` (simctl records a turned simulator as its screen lies)
// and, for a view capped to an aspect (-SimulateViewSize), `crop` to the
// view, `screen` pixels at `crop`'s x and y.
function framing({ turn, crop, screen }) {
  return [...(turn ? [turn] : []), ...(crop ? [`crop=${screen[0]}:${screen[1]}:${crop[0]}:${crop[1]}`] : [])];
}

// The moment `from` names: `scene` (the scene `scene` in), or a marker by
// name (`board`, `move N`, `celebrate`, `win`), in seconds.
function markTime(marks, from, scene) {
  const name = from === 'scene' ? `scene ${scene}` : from;
  return marks.find((m) => m.name === name)?.t;
}

module.exports = {
  BASE_EXCLUDES, LANGUAGE_ARGS, STORES, SIZES,
  readSettings, fill, selection, plan, args64, settled, filterLog,
  pngInfo, isCompletePNG, screenshotProblem, setProblems,
  framing, markTime,
};
