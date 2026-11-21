#!/usr/bin/env node
'use strict';
// Brings a game's Game Center achievements and leaderboards to Play Games
// Services, as drafts: one tool for every game on this runtime, run through
// the game's own two-line games.js on its Play directory (as play.js is),
// with play.json's `games` settings (README.md beside this file). A plan is
// printed; --send creates or updates the Play side. Nothing is published: the
// API can't, and publishing is a click in the Play Console.
//
//   node <game>/games.js [--application-id <id>] [--languages en-US,de-DE] [--send]
//   node Tools/Play/games.js --dir <game Play dir> [...]
//
// Where the achievements come from (play.json `games.source`):
//   { "appStoreConnect": "<app id>" }  Game Center live, read with asc:
//       order, points, whether each shows before it's earned, every language
//       and its image (downloaded at 512 x 512); its live leaderboards too
//       (whole-number best scores only; archived ones left out)
//   { "gameCenterFile": "<file>" }  a Game Center definitions file
//       ({ achievements: [{ vendorIdentifier, points, image,
//       localizations: { <locale>: { name, beforeEarnedDescription } } }] }),
//       every one shown before it's earned; images relative to the file
//   { "snapshot": "<file>" }  achievements and leaderboards written out
//       ({ achievements: [{ id, points, hidden, steps, icon, localizations:
//       { <locale>: { name, description } } }], leaderboards: [{ id, order,
//       min, max, icon, localizations: { <locale>: name } }] }), icons
//       relative to the repository
//
// Each achievement becomes a Play Games one with the same points (at least
// Play's 5), REVEALED or HIDDEN as Game Center shows it, and INCREMENTAL with
// its steps when it counts towards a goal (Play's progress bar for Game
// Center's percentage), else STANDARD. Steps come from the snapshot, else the
// game's steps module (play.json `games.stepsModule`, a file exporting
// `stepsFor(id)`), else play.json `games.steps` rules ([{ "match": "<regex on
// the ID without games.idPrefix>", "steps": <n or "$1">, "max": <cap> }],
// the first that matches; `games.stepsRequired` makes an ID none match an
// error). A new one takes Game Center's place in the order; an existing one
// keeps Play's, which only the Console changes.
//
// After --send, or a plan that matched every one, the IDs Play gave them go
// into the mapping file (play.json `games.mapping`, default
// PlayGames/PlayGamesAchievements.json) with the project's ID: the Android
// build packs it into the APK (`PlayGamesMapping`) and names it in its
// manifest. It is generated: never edit it by hand. Later runs match by it,
// then by English name. Icons (Play's API takes none) are written as 512 x
// 512 PNGs to games.out (default PlayGames/Out) for the Play Console.
//
// The application ID is the numeric project ID under Play Games Services →
// Setup and management → Configuration: --application-id, else play.json
// `games.applicationId`, else the mapping file's. Without one the plan reads
// nothing from Play. Play Games only takes translations in languages its
// project lists; until they're added there, --languages sends only those.

const fs = require('fs');

if (process.argv.slice(2).some((a) => a === '--help' || a === '-h')) {
  const lines = fs.readFileSync(__filename, 'utf8').split('\n');
  const end = lines.findIndex((l, i) => i > 2 && !l.startsWith('//'));
  console.log(lines.slice(2, end).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}

const path = require('path');
const https = require('https');
const { spawnSync } = require('child_process');
const games = require('./games-lib');

const args = process.argv.slice(2);
const option = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const send = args.includes('--send');

const HERE = path.resolve(option('--dir') ?? process.env.PLAY_DIR ?? '');
if (!option('--dir') && !process.env.PLAY_DIR) {
  console.error('Which game? Run its own games.js, or pass --dir <its Play directory>.');
  process.exit(2);
}
const read = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const LISTING = fs.existsSync(path.join(HERE, 'listing.json')) ? read(path.join(HERE, 'listing.json')) : {};
const SETTINGS = (fs.existsSync(path.join(HERE, 'play.json')) ? read(path.join(HERE, 'play.json')) : {}).games;
if (!SETTINGS?.source) {
  console.error(`No Play Games settings: play.json in ${HERE} has no \`games.source\`.`);
  process.exit(2);
}
const ROOT = path.resolve(HERE, SETTINGS.root ?? '../..');
const MAPPING = path.resolve(HERE, SETTINGS.mapping ?? 'PlayGames/PlayGamesAchievements.json');
const OUT = path.resolve(HERE, SETTINGS.out ?? 'PlayGames/Out');
const shown = (file) => path.relative(ROOT, file);
const saved = fs.existsSync(MAPPING) ? read(MAPPING) : { applicationId: '', achievements: {}, leaderboards: {} };
const applicationId = String(option('--application-id') ?? SETTINGS.applicationId ?? saved.applicationId ?? '');
const languages = option('--languages')?.split(',');
const playLocale = games.localeMap(SETTINGS.locales === 'listing' ? LISTING.locales : null);
const localName = (id) => games.shortId(id, SETTINGS.idPrefix);

// --- the source ------------------------------------------------------------

function asc(...argv) {
  const run = spawnSync('asc', [...argv, '--output', 'json'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (run.error?.code === 'ENOENT') throw new Error('asc is not installed.');
  if (run.status !== 0) throw new Error(`asc ${argv.slice(0, 4).join(' ')}: ${(run.stderr || run.stdout).trim().split('\n')[0]}`);
  return run.stdout.trim() ? JSON.parse(run.stdout) : {};
}

const liveVersion = (versions) => versions.find((v) => v.attributes.state === 'LIVE') ?? versions.at(-1);

// Game Center's achievements and live leaderboards, in its order, from App Store Connect.
function fromAppStoreConnect(app) {
  const achievements = asc('game-center', 'achievements', 'v2', 'list', '--app', app, '--paginate').data.map((item) => {
    const version = liveVersion(asc('game-center', 'achievements', 'v2', 'versions', 'list', '--achievement-id', item.id, '--paginate').data);
    const localizations = {};
    let image = null;
    for (const loc of asc('game-center', 'achievements', 'v2', 'localizations', 'list', '--version-id', version.id, '--paginate').data) {
      const { locale, name, beforeEarnedDescription } = loc.attributes;
      localizations[locale] = { name, description: beforeEarnedDescription };
      if (locale === 'en-US') image = asc('game-center', 'achievements', 'v2', 'images', 'view', '--localization-id', loc.id).data?.attributes?.imageAsset ?? null;
    }
    const { vendorIdentifier, points, showBeforeEarned } = item.attributes;
    return { id: vendorIdentifier, points, hidden: !showBeforeEarned, localizations, icon: image?.templateUrl ? { url: image.templateUrl } : null };
  });
  const leaderboards = asc('game-center', 'leaderboards', 'v2', 'list', '--app', app, '--paginate').data
    .filter((item) => !item.attributes.archived)
    .map((item) => {
      const { vendorIdentifier, scoreSortType, defaultFormatter, submissionType } = item.attributes;
      if (defaultFormatter !== 'INTEGER' || submissionType !== 'BEST_SCORE') {
        throw new Error(`${vendorIdentifier}: only whole-number best-score leaderboards are mapped (${defaultFormatter}, ${submissionType})`);
      }
      const version = liveVersion(asc('game-center', 'leaderboards', 'v2', 'versions', 'list', '--leaderboard-id', item.id, '--paginate').data);
      const localizations = Object.fromEntries(asc('game-center', 'leaderboards', 'v2', 'localizations', 'list', '--version-id', version.id, '--paginate').data
        .map((loc) => [loc.attributes.locale, loc.attributes.name]));
      return { id: vendorIdentifier, order: scoreSortType === 'ASC' ? 'SMALLER_IS_BETTER' : 'LARGER_IS_BETTER', localizations, icon: null };
    });
  return { achievements, leaderboards };
}

// A Game Center definitions file: achievements only, every one revealed.
function fromGameCenterFile(file) {
  const dir = path.dirname(file);
  const achievements = read(file).achievements.map((item) => ({
    id: item.vendorIdentifier,
    points: item.points,
    hidden: false,
    localizations: Object.fromEntries(Object.entries(item.localizations)
      .map(([locale, text]) => [locale, { name: text.name, description: text.beforeEarnedDescription }])),
    icon: item.image ? { file: path.join(dir, item.image) } : null,
  }));
  return { achievements, leaderboards: [] };
}

// A snapshot with everything written out, steps included.
function fromSnapshot(file) {
  const source = read(file);
  return {
    achievements: (source.achievements ?? []).map((item) => ({
      id: item.id, points: item.points, hidden: Boolean(item.hidden), steps: item.steps ?? 0,
      localizations: item.localizations, icon: item.icon ? { file: path.join(ROOT, item.icon) } : null,
    })),
    leaderboards: (source.leaderboards ?? []).map((item) => ({
      id: item.id, order: item.order, min: item.min, max: item.max,
      localizations: item.localizations, icon: item.icon ? { file: path.join(ROOT, item.icon) } : null,
    })),
  };
}

function load() {
  const source = SETTINGS.source;
  if (source.appStoreConnect) return fromAppStoreConnect(String(source.appStoreConnect));
  if (source.gameCenterFile) return fromGameCenterFile(path.resolve(HERE, source.gameCenterFile));
  if (source.snapshot) return fromSnapshot(path.resolve(HERE, source.snapshot));
  throw new Error('play.json `games.source` names none of appStoreConnect, gameCenterFile or snapshot.');
}

// Steps to unlock (0 for a standard achievement): the snapshot's, else the
// game's steps module, else play.json's rules.
const stepsModule = SETTINGS.stepsModule ? require(path.resolve(HERE, SETTINGS.stepsModule)) : null;
function stepsFor(item) {
  if (item.steps !== undefined) return games.incremental(item.steps);
  const fromModule = stepsModule?.stepsFor?.(item.id, { root: ROOT });
  if (fromModule !== undefined && fromModule !== null) return games.incremental(fromModule);
  const steps = games.stepsByRules(localName(item.id), SETTINGS.steps ?? []);
  if (steps === null && SETTINGS.stepsRequired) throw new Error(`${item.id}: no steps rule matches it`);
  return games.incremental(steps ?? 0);
}

// --- Play ------------------------------------------------------------------

function gplay(argv) {
  const run = spawnSync('gplay', [...argv, '--retry', '3', '--output', 'json'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (run.error?.code === 'ENOENT') throw new Error('gplay is not installed: `brew install --cask PollyGlot/tap/gplay`.');
  if (run.status !== 0) throw new Error(`gplay ${argv.slice(0, 3).join(' ')}: ${(run.stderr || run.stdout).trim().split('\n')[0]}`);
  return run.stdout.trim() ? JSON.parse(run.stdout) : {};
}

function listLive(kind) {
  if (!applicationId) return [];
  const items = [];
  let token = null;
  do {
    const page = gplay(['games', kind, 'list', '--application-id', applicationId, ...(token ? ['--page-token', token] : [])]);
    items.push(...(page.items ?? []));
    token = page.nextPageToken;
  } while (token);
  return items;
}

let scratch = 0;
function write(body) {
  fs.mkdirSync(OUT, { recursive: true });
  const file = path.join(OUT, `request-${scratch++}.json`);
  fs.writeFileSync(file, JSON.stringify(body));
  return file;
}

// Creates or updates each wanted configuration (`kind`: achievements or
// leaderboards), matched by the saved mapping, then by English name; returns
// each one's Play ID by Game Center ID.
function sync(kind, wanted, live, savedIds, describe) {
  const byId = new Map(live.map((config) => [config.id, config]));
  const byName = new Map(live.map((config) => [games.englishName(config), config]));
  const ids = {};
  let pending = 0;
  for (const { item, body } of wanted) {
    const known = savedIds?.[item.id];
    const existing = byId.get(typeof known === 'string' ? known : known?.id) ?? byName.get(games.englishName(body));
    const label = `${games.englishName(body)} (${describe(body)}, ${body.draft.name.translations.length} languages)`;
    let id = existing?.id;
    if (!existing) {
      pending += 1;
      console.log(`${send ? 'Creating' : 'Would create'}: ${label}`);
      if (send) id = gplay(['games', kind, 'create', '--application-id', applicationId, '--file', write(body)]).id;
    } else if (games.comparable(existing) !== games.comparable(body)) {
      pending += 1;
      console.log(`${send ? 'Updating' : 'Would update'}: ${label}`);
      // A full replace: carry over the icon uploaded in the Play Console.
      const iconUrl = existing.draft?.iconUrl ?? existing.published?.iconUrl;
      const draft = iconUrl ? { ...body.draft, iconUrl } : body.draft;
      if (send) gplay(['games', kind, 'set', existing.id, '--file', write({ ...body, draft, id: existing.id, token: existing.token })]);
    }
    if (id) ids[item.id] = id;
  }
  return { ids, pending };
}

// --- icons -----------------------------------------------------------------

const download = (url) => new Promise((resolve, reject) => {
  https.get(url, (response) => {
    if (response.statusCode !== 200) { response.resume(); reject(new Error(`${url}: HTTP ${response.statusCode}`)); return; }
    const chunks = [];
    response.on('data', (chunk) => chunks.push(chunk));
    response.on('end', () => resolve(Buffer.concat(chunks)));
  }).on('error', reject);
});

// Each icon as a 512 x 512 PNG in OUT: downloaded from Game Center, or made
// from the repository's image when that is newer than the last one made.
async function writeIcons(items) {
  fs.mkdirSync(OUT, { recursive: true });
  for (const item of items) {
    const target = path.join(OUT, `${localName(item.id)}.png`);
    if (item.icon?.url) {
      fs.writeFileSync(target, await download(item.icon.url.replace('{w}', '512').replace('{h}', '512').replace('{f}', 'png')));
    } else if (item.icon?.file) {
      if (!fs.existsSync(item.icon.file)) { console.log(`${item.id}: no image at ${shown(item.icon.file)}`); continue; }
      if (fs.existsSync(target) && fs.statSync(target).mtimeMs >= fs.statSync(item.icon.file).mtimeMs) continue;
      const run = spawnSync('sips', ['-s', 'format', 'png', '-z', '512', '512', item.icon.file, '--out', target], { encoding: 'utf8' });
      if (run.status !== 0) console.log(`Could not write ${shown(target)}: ${run.stderr.trim()}`);
    }
  }
}

// --- run -------------------------------------------------------------------

async function main() {
  const { achievements, leaderboards } = load();
  const options = { playLocale, languages };
  const wantedAchievements = achievements.map((item, rank) => ({ item, body: games.achievementBody({ ...item, steps: stepsFor(item) }, rank, options) }));
  const wantedLeaderboards = leaderboards.map((item, rank) => ({ item, body: games.leaderboardBody(item, rank, options) }));
  const total = wantedAchievements.reduce((sum, { body }) => sum + body.draft.pointValue, 0);
  if (total > games.MAX_POINTS) throw new Error(`Play Games allows ${games.MAX_POINTS} points a game; these come to ${total}`);
  console.log(`${achievements.length} achievements, ${total} points (Play Games allows ${games.MAX_POINTS}); ${leaderboards.length} leaderboards.`);
  if (!applicationId) {
    console.log('No Play Games application ID (--application-id, play.json or the mapping file): planning as if none existed on Play.');
    if (send) throw new Error('--send needs the application ID');
  }

  const unlocked = sync('achievements', wantedAchievements, listLive('achievements'), saved.achievements,
    (body) => `${body.initialState.toLowerCase()}, ${body.stepsToUnlock ? `${body.stepsToUnlock} steps` : 'standard'}, ${body.draft.pointValue} points`);
  const boards = leaderboards.length
    ? sync('leaderboards', wantedLeaderboards, listLive('leaderboards'), saved.leaderboards, (body) => body.scoreOrder.toLowerCase().replaceAll('_', ' '))
    : { ids: {}, pending: 0 };

  const mapping = games.mapping(applicationId, wantedAchievements, wantedLeaderboards, unlocked.ids, boards.ids);
  const complete = Object.keys(mapping.achievements).length === achievements.length
    && Object.keys(mapping.leaderboards).length === leaderboards.length;
  // A game without leaderboards keeps a mapping without the key.
  if (!leaderboards.length && !('leaderboards' in saved)) delete mapping.leaderboards;
  if (send || (applicationId && complete)) {
    const text = JSON.stringify(mapping, null, 2) + '\n';
    if (!fs.existsSync(MAPPING) || fs.readFileSync(MAPPING, 'utf8') !== text) {
      fs.mkdirSync(path.dirname(MAPPING), { recursive: true });
      fs.writeFileSync(MAPPING, text);
      console.log(`Wrote ${shown(MAPPING)}: rebuild the Android app to pack it.`);
    }
  }
  await writeIcons([...achievements, ...leaderboards]);
  console.log(`Icons for the Play Console (512 x 512): ${shown(OUT)}/`);
  const pending = unlocked.pending + boards.pending;
  console.log(pending === 0 ? 'Play Games is up to date.' : `${pending} change${pending === 1 ? '' : 's'} ${send ? 'sent as drafts: publish them in the Play Console' : 'planned; pass --send to make them'}.`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
