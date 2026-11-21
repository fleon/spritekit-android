'use strict';
// The pure parts of gamecenter.js and generate-art.js: checking a definitions
// file, planning what App Store Connect lacks, and reading art prompts.
// Nothing here runs asc or Codex, so the tests can call all of it.

// asc reads a leading @ as a file or env reference.
const literal = (value) => String(value).replace(/^@/, '@@');

// Localizations belong to the newest version of an achievement or leaderboard.
const newest = (versions) => [...(versions ?? [])].sort((a, b) => (a.attributes.version ?? 0) - (b.attributes.version ?? 0)).at(-1) ?? null;

const SORTS = ['ASC', 'DESC'];
const SUBMISSIONS = ['BEST_SCORE', 'MOST_RECENT_SCORE'];
const MAX_POINTS = 100;
const MAX_TOTAL_POINTS = 1000;

// Every problem in a definitions file, as a list of messages.
function problems(definitions) {
  const found = [];
  if (!definitions || typeof definitions !== 'object') return ['the file holds no object'];
  if (!definitions.app) found.push('no "app" (the App Store Connect app ID)');
  const achievements = definitions.achievements ?? [];
  const leaderboards = definitions.leaderboards ?? [];
  if (!Array.isArray(achievements) || !Array.isArray(leaderboards)) {
    return [...found, '"achievements" and "leaderboards" must be lists'];
  }

  const seen = new Set();
  const unique = (id, where) => {
    if (seen.has(id)) found.push(`${where}: ${id} is defined twice`);
    seen.add(id);
  };
  const texts = (where, localizations, fields) => {
    const entries = Object.entries(localizations ?? {});
    if (!entries.length) found.push(`${where}: no localizations`);
    for (const [locale, text] of entries) {
      for (const field of fields) if (!text?.[field]) found.push(`${where}: ${locale} has no ${field}`);
    }
  };

  let total = 0;
  achievements.forEach((item, index) => {
    const where = item?.vendorIdentifier ?? `achievement ${index + 1}`;
    if (!item?.vendorIdentifier) found.push(`${where}: no vendorIdentifier`);
    else unique(item.vendorIdentifier, where);
    if (!item?.referenceName) found.push(`${where}: no referenceName`);
    if (!Number.isInteger(item?.points) || item.points < 0 || item.points > MAX_POINTS) found.push(`${where}: points must be a whole number from 0 to ${MAX_POINTS}`);
    else total += item.points;
    texts(where, item?.localizations, ['name', 'beforeEarnedDescription', 'afterEarnedDescription']);
  });
  if (total > MAX_TOTAL_POINTS) found.push(`the achievements give ${total} points; Game Center allows ${MAX_TOTAL_POINTS}`);

  leaderboards.forEach((item, index) => {
    const where = item?.vendorIdentifier ?? `leaderboard ${index + 1}`;
    if (!item?.vendorIdentifier) found.push(`${where}: no vendorIdentifier`);
    else unique(item.vendorIdentifier, where);
    if (!item?.referenceName) found.push(`${where}: no referenceName`);
    if (!item?.formatter) found.push(`${where}: no formatter`);
    if (!SORTS.includes(item?.sort)) found.push(`${where}: sort must be ${SORTS.join(' or ')}`);
    if (!SUBMISSIONS.includes(item?.submissionType)) found.push(`${where}: submissionType must be ${SUBMISSIONS.join(' or ')}`);
    texts(where, item?.localizations, ['name']);
  });
  return found;
}

// Leaderboard localization fields a definition may give, by asc flag. Only the
// ones a definition gives are compared: the rest stay as they are.
const LEADERBOARD_TEXT = {
  name: '--name',
  description: '--description',
  formatterOverride: '--formatter-override',
  formatterSuffix: '--formatter-suffix',
  formatterSuffixSingular: '--formatter-suffix-singular',
};

const achievementText = (text) => [
  '--name', text.name,
  '--before-earned-description', text.beforeEarnedDescription,
  '--after-earned-description', text.afterEarnedDescription,
];
const leaderboardText = (text) => Object.entries(LEADERBOARD_TEXT)
  .filter(([field]) => text[field] !== undefined)
  .flatMap(([field, flag]) => [flag, text[field]]);

const sameAchievementText = (attributes, text) => attributes.name === text.name
  && attributes.beforeEarnedDescription === text.beforeEarnedDescription
  && attributes.afterEarnedDescription === text.afterEarnedDescription;
const sameLeaderboardText = (attributes, text) => Object.keys(LEADERBOARD_TEXT)
  .every((field) => text[field] === undefined || (attributes[field] ?? null) === (text[field] ?? null));

// Flags for an achievement's settings beyond points; only the ones it gives.
const achievementSettings = (item) => [
  ...(item.hidden !== undefined ? ['--show-before-earned', String(!item.hidden)] : []),
  ...(item.repeatable !== undefined ? ['--repeatable', String(item.repeatable)] : []),
];
const sameAchievement = (attributes, item) => attributes.points === item.points
  && attributes.referenceName === item.referenceName
  && (item.hidden === undefined || attributes.showBeforeEarned === !item.hidden)
  && (item.repeatable === undefined || Boolean(attributes.repeatable) === item.repeatable);

const leaderboardSettings = (item) => [
  '--formatter', item.formatter, '--sort', item.sort, '--submission-type', item.submissionType,
  ...(item.visibility !== undefined ? ['--visibility', item.visibility] : []),
  ...(item.scoreRangeStart !== undefined ? ['--score-range-start', item.scoreRangeStart] : []),
  ...(item.scoreRangeEnd !== undefined ? ['--score-range-end', item.scoreRangeEnd] : []),
];
const sameLeaderboard = (attributes, item) => attributes.referenceName === item.referenceName
  && attributes.defaultFormatter === item.formatter
  && attributes.scoreSortType === item.sort
  && attributes.submissionType === item.submissionType
  && (item.visibility === undefined || attributes.visibility === item.visibility)
  && (item.scoreRangeStart === undefined || String(attributes.scoreRangeStart) === String(item.scoreRangeStart))
  && (item.scoreRangeEnd === undefined || String(attributes.scoreRangeEnd) === String(item.scoreRangeEnd));

const KINDS = {
  achievement: {
    noun: '',
    summary: (item) => `${item.points} points`,
    same: sameAchievement,
    settings: achievementSettings,
    sameText: sameAchievementText,
    text: achievementText,
  },
  leaderboard: {
    noun: 'leaderboard ',
    summary: (item) => `${item.formatter}, ${item.sort}, ${item.submissionType}`,
    same: sameLeaderboard,
    settings: leaderboardSettings,
    sameText: sameLeaderboardText,
    text: leaderboardText,
  },
};

// What App Store Connect lacks, in the order to send it: Game Center turned
// on, then each achievement in list order (the order Game Center shows them),
// then each leaderboard, each with its localizations and their images.
//
// `state` is what App Store Connect holds, read beforehand:
//   { detail, achievements: Map, leaderboards: Map }, each map from vendor ID
//   to { resource, version, localizations: Map(locale → { resource, image }) }
// `sizeOf(image)` gives the size in bytes of a definition's image file.
//
// Each action is { kind, description, ... } with what sending it needs. A
// missing achievement or leaderboard is one action, its localizations and
// images included; a missing localization is one, its image included.
function plan(definitions, state, sizeOf) {
  const actions = [];
  if (!state.detail) actions.push({ kind: 'details', description: 'turn on Game Center for the app' });
  for (const [kind, list, existing] of [
    ['achievement', definitions.achievements ?? [], state.achievements],
    ['leaderboard', definitions.leaderboards ?? [], state.leaderboards],
  ]) {
    const rules = KINDS[kind];
    for (const item of list) {
      const locales = Object.entries(item.localizations);
      const live = state.detail ? existing?.get(item.vendorIdentifier) : null;
      if (!live) {
        actions.push({
          kind: `create-${kind}`, item,
          description: `create ${rules.noun}"${item.referenceName}" (${item.vendorIdentifier}, ${rules.summary(item)}) with ${locales.length} localizations${item.image ? ' and images' : ''}`,
        });
        continue;
      }
      if (!rules.same(live.resource.attributes, item)) {
        actions.push({
          kind: `update-${kind}`, item, id: live.resource.id,
          description: `update ${rules.noun}"${item.referenceName}" (${rules.summary(item)})`,
        });
      }
      if (!live.version) throw new Error(`${item.vendorIdentifier} has no version`);
      const size = item.image ? sizeOf(item.image) : null;
      for (const [locale, text] of locales) {
        const current = live.localizations.get(locale);
        if (!current) {
          actions.push({
            kind: `add-${kind}-localization`, item, locale, text, versionId: live.version.id,
            description: `${item.referenceName}: add ${locale} "${text.name}"`,
          });
          continue;
        }
        if (!rules.sameText(current.resource.attributes, text)) {
          actions.push({
            kind: `update-${kind}-localization`, item, locale, text, id: current.resource.id,
            description: `${item.referenceName}: update ${locale} "${text.name}"`,
          });
        }
        if (!item.image) continue;
        // Without an image asc answers with an empty resource rather than nothing.
        if (!current.image?.id) {
          actions.push({
            kind: `upload-${kind}-image`, item, locale, localizationId: current.resource.id,
            description: `${item.referenceName}: upload the ${locale} image`,
          });
        } else if (current.image.attributes?.fileSize !== size) {
          actions.push({
            kind: `replace-${kind}-image`, item, locale, localizationId: current.resource.id, imageId: current.image.id,
            description: `${item.referenceName}: replace the ${locale} image`,
          });
        }
      }
    }
  }
  return actions;
}

// --- art prompts -----------------------------------------------------------

// A prompt file: its first line names the references to attach
// (`References: a, b`), the rest describes the image.
function parsePrompt(text) {
  const [first, ...rest] = text.split('\n');
  const references = first.replace(/^References:\s*/, '').split(',').map((ref) => ref.trim()).filter(Boolean);
  return { references, body: rest.join('\n').trim() };
}

// A `<name>-cutout` prompt paints a subject on a transparent ground, kept as
// a PNG to compose with; every other image is a JPEG.
const imageFile = (name) => (name.endsWith('-cutout') ? `${name}.png` : `${name}.jpg`);

const promptFor = (brief, body, name) => `${brief}\n# This image\n${body}\n\n`
  + `Use your image generation tool to paint this one square image, then save it as out/${name}.png `
  + '(relative to this folder) and stop: no checks, edits or other files.';

// The names to paint: those asked for, else every prompt not painted yet.
function namesToPaint(all, asked, painted) {
  const names = asked.length ? asked : all.filter((name) => !painted(imageFile(name)));
  const unknown = names.filter((name) => !all.includes(name));
  if (unknown.length) throw new Error(`no prompt for ${unknown.join(', ')}`);
  return names;
}

module.exports = {
  literal, newest, problems, plan, achievementText, leaderboardText, achievementSettings, leaderboardSettings,
  parsePrompt, imageFile, promptFor, namesToPaint,
};
