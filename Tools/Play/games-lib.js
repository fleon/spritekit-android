'use strict';
// games.js's pure parts, apart so they test on any machine (games.test.js):
// no gplay, no asc, no files.

// Play Games' bounds on points: each at least 5 and a multiple of 5, and
// 1000 a game.
const MIN_POINTS = 5;
const MAX_POINTS = 1000;

// App Store Connect's (Game Center's) locales as Play names them.
const ASC_LOCALES = {
  'en-US': 'en-US', 'de-DE': 'de-DE', 'es-ES': 'es-ES', 'es-MX': 'es-419', 'fr-FR': 'fr-FR', hi: 'hi-IN',
  id: 'id', ja: 'ja-JP', ko: 'ko-KR', 'nl-NL': 'nl-NL', 'pt-BR': 'pt-BR', 'pt-PT': 'pt-PT', ru: 'ru-RU',
  th: 'th', vi: 'vi', 'zh-Hans': 'zh-CN', 'zh-Hant': 'zh-TW',
};

// A source locale's Play name. With a listing's `locales` (game language →
// Play locale), that map, by language where Game Center adds a region, else
// as it is; without one, App Store Connect's table, refusing a locale it
// doesn't know.
function localeMap(listingLocales) {
  if (listingLocales) {
    const map = Object.fromEntries(Object.entries(listingLocales).flatMap(([game, play]) => [[game, play], [play, play]]));
    return (locale) => map[locale] ?? map[locale.split('-')[0]] ?? locale;
  }
  return (locale) => {
    if (!(locale in ASC_LOCALES)) throw new Error(`no Play locale for App Store Connect's ${locale}`);
    return ASC_LOCALES[locale];
  };
}

// An ID without the game's prefix (com.fleon.game.achievements.levels10 →
// levels10), else its last part.
const shortId = (id, prefix) => (prefix && id.startsWith(prefix) ? id.slice(prefix.length) : id.split('.').pop());

// Steps for an incremental achievement; fewer than 2 make it standard (0).
const incremental = (steps) => { const n = Number(steps) || 0; return n >= 2 ? n : 0; };

// Steps by the first rule whose `match` matches `id` ({ match, steps: n or
// "$1", max }), or null when none does.
function stepsByRules(id, rules) {
  for (const rule of rules) {
    const found = id.match(new RegExp(rule.match));
    if (!found) continue;
    let steps = typeof rule.steps === 'string' ? Number(rule.steps.replace(/\$(\d)/g, (_, i) => found[Number(i)] ?? '')) : Number(rule.steps);
    if (!Number.isFinite(steps)) throw new Error(`${id}: steps rule ${rule.match} gives no number`);
    if (rule.max !== undefined) steps = Math.min(steps, rule.max);
    return steps;
  }
  return null;
}

// A localized string bundle of `texts` ({ <locale>: value }), in Play's
// locales, only those in `languages` when given.
function bundle(texts, { playLocale, languages }) {
  return {
    kind: 'gamesConfiguration#localizedStringBundle',
    translations: Object.entries(texts)
      .map(([locale, value]) => [playLocale(locale), value])
      .filter(([locale]) => !languages || languages.includes(locale))
      .map(([locale, value]) => ({ kind: 'gamesConfiguration#localizedString', locale, value })),
  };
}

const field = (localizations, key) => Object.fromEntries(Object.entries(localizations).map(([locale, text]) => [locale, text[key]]));

// An achievement ({ id, points, hidden, steps, localizations: { <locale>:
// { name, description } } }) as Play's configuration, `rank` its place.
function achievementBody(item, rank, options) {
  if (item.points % 5 !== 0) throw new Error(`${item.id}: Play Games points must be a multiple of 5`);
  const steps = incremental(item.steps);
  return {
    kind: 'gamesConfiguration#achievementConfiguration',
    achievementType: steps ? 'INCREMENTAL' : 'STANDARD',
    initialState: item.hidden ? 'HIDDEN' : 'REVEALED',
    ...(steps ? { stepsToUnlock: steps } : {}),
    draft: {
      kind: 'gamesConfiguration#achievementConfigurationDetail',
      name: bundle(field(item.localizations, 'name'), options),
      description: bundle(field(item.localizations, 'description'), options),
      pointValue: Math.max(item.points, MIN_POINTS),
      sortRank: rank + 1,
    },
  };
}

// A leaderboard ({ id, order, min, max, localizations: { <locale>: name } })
// as Play's configuration: whole numbers, best score kept.
function leaderboardBody(item, rank, options) {
  return {
    kind: 'gamesConfiguration#leaderboardConfiguration',
    scoreOrder: item.order,
    ...(item.min !== undefined ? { scoreMin: String(item.min) } : {}),
    ...(item.max !== undefined ? { scoreMax: String(item.max) } : {}),
    draft: {
      kind: 'gamesConfiguration#leaderboardConfigurationDetail',
      name: bundle(item.localizations, options),
      scoreFormat: { kind: 'gamesConfiguration#gamesNumberFormatConfiguration', numberFormatType: 'NUMERIC', numDecimalPlaces: 0 },
      sortRank: rank + 1,
    },
  };
}

// A configuration's English name, from its draft, else what's published.
const englishName = (config) => (config.draft ?? config.published)?.name?.translations?.find((t) => t.locale === 'en-US')?.value;

// What is compared between Play's configuration and the wanted one: the
// draft if there is one, else what's published, keys sorted. Not the order:
// Play keeps an existing one's sortRank whatever an update says.
function comparable(config) {
  const detail = config.draft ?? config.published ?? {};
  const strings = (b) => Object.fromEntries((b?.translations ?? []).map((t) => [t.locale, t.value]));
  return JSON.stringify({
    type: config.achievementType, state: config.initialState, steps: config.stepsToUnlock ?? 0,
    order: config.scoreOrder, min: config.scoreMin, max: config.scoreMax,
    format: detail.scoreFormat?.numberFormatType, decimals: detail.scoreFormat ? detail.scoreFormat.numDecimalPlaces ?? 0 : undefined,
    name: strings(detail.name), description: strings(detail.description),
    points: detail.pointValue ?? 0,
  }, (key, value) => (value && typeof value === 'object' && !Array.isArray(value)
    ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b))) : value));
}

// The mapping the Android app reads: the project's ID, and each Game Center
// ID's Play ID (and steps, for an incremental achievement), in source order.
function mapping(applicationId, achievements, leaderboards, achievementIds, leaderboardIds) {
  return {
    applicationId,
    achievements: Object.fromEntries(achievements.filter(({ item }) => achievementIds[item.id])
      .map(({ item, body }) => [item.id, { id: achievementIds[item.id], ...(body.stepsToUnlock ? { steps: body.stepsToUnlock } : {}) }])),
    leaderboards: Object.fromEntries(leaderboards.filter(({ item }) => leaderboardIds[item.id])
      .map(({ item }) => [item.id, { id: leaderboardIds[item.id] }])),
  };
}

module.exports = {
  MIN_POINTS, MAX_POINTS, ASC_LOCALES, localeMap, shortId, incremental, stepsByRules, bundle,
  achievementBody, leaderboardBody, englishName, comparable, mapping,
};
