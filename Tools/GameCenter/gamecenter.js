#!/usr/bin/env node
'use strict';
// Syncs a game's Game Center achievements and leaderboards in App Store
// Connect with its definitions file, through the asc CLI (versioned "v2"
// achievements and leaderboards): one tool for every game on this runtime,
// run through the game's own two-line script on its Game Center directory
// (README.md beside this file). It turns Game Center on for the app, creates
// each missing achievement in list order (the order Game Center shows them),
// then each missing leaderboard, then their localizations and images. It
// prints the plan; --send makes the changes. Safe to rerun: achievements and
// leaderboards are matched by vendor ID and localizations by locale, and only
// what is missing or different is sent (an image whose file size changed is
// replaced). Nothing is submitted for review: that stays with the user.
//
//   node <game>/upload-achievements.js [--file <definitions>] [--send]
//   node Tools/GameCenter/gamecenter.js --dir <game Game Center dir> [...]
//
// The definitions file (default achievements.json in the directory):
//   { "app": "<App Store Connect app ID>",
//     "achievements": [{ vendorIdentifier, referenceName, points, image,
//       hidden?, repeatable?, localizations: { <locale>: { name,
//       beforeEarnedDescription, afterEarnedDescription } } }],
//     "leaderboards": [{ vendorIdentifier, referenceName, formatter, sort,
//       submissionType, visibility?, scoreRangeStart?, scoreRangeEnd?, image?,
//       localizations: { <locale>: { name, description?, formatterOverride?,
//       formatterSuffix?, formatterSuffixSingular? } } }] }
// Images are relative to the file. Optional fields are compared only when
// given; leaving one out leaves App Store Connect's value alone.

const fs = require('fs');

if (process.argv.slice(2).some((a) => a === '--help' || a === '-h')) {
  const lines = fs.readFileSync(__filename, 'utf8').split('\n');
  const end = lines.findIndex((l, i) => i > 2 && !l.startsWith('//'));
  console.log(lines.slice(2, end).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}

const path = require('path');
const { execFileSync } = require('child_process');
const gc = require('./lib');

const args = process.argv.slice(2);
const option = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const send = args.includes('--send');

if (!option('--dir') && !process.env.GAME_CENTER_DIR) {
  console.error('Which game? Run its own script, or pass --dir <its Game Center directory>.');
  process.exit(2);
}
const HERE = path.resolve(option('--dir') ?? process.env.GAME_CENTER_DIR);
const FILE = path.resolve(HERE, option('--file') ?? 'achievements.json');
const definitions = JSON.parse(fs.readFileSync(FILE, 'utf8'));
const imagePath = (image) => path.resolve(path.dirname(FILE), image);

const found = gc.problems(definitions);
for (const item of [...(definitions.achievements ?? []), ...(definitions.leaderboards ?? [])]) {
  if (item?.image && !fs.existsSync(imagePath(item.image))) found.push(`missing ${item.image}`);
}
if (found.length) {
  console.error(`${path.relative(process.cwd(), FILE)}:\n${found.map((p) => `  ${p}`).join('\n')}`);
  process.exit(1);
}
const { app } = definitions;

function asc(...argv) {
  try {
    const stdout = execFileSync('asc', [...argv.map(gc.literal), '--output', 'json'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 * 1024 * 1024,
    });
    return stdout.trim() ? JSON.parse(stdout) : {};
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error('asc is not installed.');
    throw new Error(`asc ${argv.slice(0, 4).join(' ')} failed: ${(error.stderr || error.message).trim()}`);
  }
}

// Reads that may come back empty or as "not found" when nothing exists yet.
function maybe(...argv) {
  try {
    return asc(...argv).data ?? null;
  } catch (error) {
    if (/not installed/.test(error.message)) throw error;
    return null;
  }
}

// --- what App Store Connect holds ------------------------------------------

const API = {
  achievement: { list: ['achievements', 'v2'], versions: '--achievement-id' },
  leaderboard: { list: ['leaderboards', 'v2'], versions: '--leaderboard-id' },
};

// The defined ones App Store Connect has: each with its newest version and
// that version's localizations (with their images, when it has an image).
function readLive(kind, items) {
  const api = API[kind];
  const listed = new Map((maybe('game-center', ...api.list, 'list', '--app', app, '--paginate') ?? [])
    .map((resource) => [resource.attributes.vendorIdentifier, resource]));
  const live = new Map();
  for (const item of items) {
    const resource = listed.get(item.vendorIdentifier);
    if (!resource) continue;
    const version = gc.newest(maybe('game-center', ...api.list, 'versions', 'list', api.versions, resource.id, '--paginate'));
    const localizations = new Map();
    if (version) {
      for (const localization of maybe('game-center', ...api.list, 'localizations', 'list', '--version-id', version.id, '--paginate') ?? []) {
        const { locale } = localization.attributes;
        if (!item.localizations[locale]) continue;
        const image = item.image ? maybe('game-center', ...api.list, 'images', 'view', '--localization-id', localization.id) : null;
        localizations.set(locale, { resource: localization, image });
      }
    }
    live.set(item.vendorIdentifier, { resource, version, localizations });
  }
  return live;
}

const detail = (maybe('game-center', 'details', 'list', '--app', app) ?? [])[0] ?? null;
const state = {
  detail,
  achievements: detail ? readLive('achievement', definitions.achievements ?? []) : new Map(),
  leaderboards: detail ? readLive('leaderboard', definitions.leaderboards ?? []) : new Map(),
};
const actions = gc.plan(definitions, state, (image) => fs.statSync(imagePath(image)).size);

// --- sending ---------------------------------------------------------------

function uploadImage(kind, item, localizationId) {
  return asc('game-center', ...API[kind].list, 'images', 'upload', '--localization-id', localizationId, '--file', imagePath(item.image));
}

function addLocalization(kind, item, versionId, locale, text) {
  const create = kind === 'achievement' ? gc.achievementText(text) : gc.leaderboardText(text);
  const localization = asc('game-center', ...API[kind].list, 'localizations', 'create', '--version-id', versionId, '--locale', locale, ...create).data;
  if (item.image) {
    console.log(`Doing: ${item.referenceName}: upload the ${locale} image`);
    uploadImage(kind, item, localization.id);
  }
}

// A new achievement or leaderboard: created with its first version, then
// that version's localizations and images.
function create(kind, item) {
  const settings = kind === 'achievement'
    ? ['--points', item.points, ...gc.achievementSettings(item)]
    : gc.leaderboardSettings(item);
  const resource = asc('game-center', `${kind}s`, 'create', '--v2', '--app', app,
    '--reference-name', item.referenceName, '--vendor-id', item.vendorIdentifier, ...settings).data;
  const version = gc.newest(maybe('game-center', ...API[kind].list, 'versions', 'list', API[kind].versions, resource.id, '--paginate'));
  if (!version) throw new Error(`${item.vendorIdentifier} has no version`);
  for (const [locale, text] of Object.entries(item.localizations)) addLocalization(kind, item, version.id, locale, text);
}

function run(action) {
  const kind = action.kind.includes('leaderboard') ? 'leaderboard' : 'achievement';
  const { item } = action;
  switch (action.kind) {
    case 'details':
      return asc('game-center', 'details', 'create', '--app', app);
    case 'create-achievement':
    case 'create-leaderboard':
      return create(kind, item);
    case 'update-achievement':
      return asc('game-center', 'achievements', 'update', '--v2', '--id', action.id,
        '--reference-name', item.referenceName, '--points', item.points, ...gc.achievementSettings(item));
    case 'update-leaderboard':
      return asc('game-center', 'leaderboards', 'update', '--v2', '--id', action.id,
        '--reference-name', item.referenceName, ...gc.leaderboardSettings(item));
    case 'add-achievement-localization':
    case 'add-leaderboard-localization':
      return addLocalization(kind, item, action.versionId, action.locale, action.text);
    case 'update-achievement-localization':
      return asc('game-center', 'achievements', 'v2', 'localizations', 'update', '--id', action.id, ...gc.achievementText(action.text));
    case 'update-leaderboard-localization':
      return asc('game-center', 'leaderboards', 'v2', 'localizations', 'update', '--id', action.id, ...gc.leaderboardText(action.text));
    case 'upload-achievement-image':
    case 'upload-leaderboard-image':
      return uploadImage(kind, item, action.localizationId);
    case 'replace-achievement-image':
    case 'replace-leaderboard-image':
      asc('game-center', ...API[kind].list, 'images', 'delete', '--id', action.imageId, '--confirm');
      return uploadImage(kind, item, action.localizationId);
    default:
      throw new Error(`unknown action ${action.kind}`);
  }
}

for (const action of actions) {
  console.log(`${send ? 'Doing' : 'Would'}: ${action.description}`);
  if (send) run(action);
}
console.log(actions.length === 0 ? 'App Store Connect is up to date.'
  : send ? `Sent ${actions.length} changes.` : `${actions.length} changes. Run with --send to make them.`);
