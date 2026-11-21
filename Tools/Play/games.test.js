'use strict';
// node --test Tools/Play/games.test.js: games.js's pure parts (games-lib.js).

const test = require('node:test');
const assert = require('node:assert');
const games = require('./games-lib');

const options = { playLocale: games.localeMap(null), languages: null };
const item = {
  id: 'com.example.game.achievements.levels20', points: 10, hidden: false, steps: 20,
  localizations: { 'en-US': { name: 'Twenty', description: 'Clear 20 levels' }, 'es-MX': { name: 'Veinte', description: 'Supera 20 niveles' } },
};

test('locales: App Store Connect\'s table, or a listing\'s map', () => {
  assert.strictEqual(games.localeMap(null)('es-MX'), 'es-419');
  assert.strictEqual(games.localeMap(null)('zh-Hans'), 'zh-CN');
  assert.throws(() => games.localeMap(null)('xx'), /no Play locale/);
  const listing = games.localeMap({ de: 'de-DE', 'zh-Hans': 'zh-CN' });
  assert.strictEqual(listing('de-DE'), 'de-DE');
  assert.strictEqual(listing('de'), 'de-DE');
  assert.strictEqual(listing('zh-Hans'), 'zh-CN');
  assert.strictEqual(listing('fr-FR'), 'fr-FR');
});

test('steps: rules, caps, and fewer than 2 make it standard', () => {
  const huerings = [{ match: '(\\d+)$', steps: '$1', max: 100 }];
  assert.strictEqual(games.stepsByRules('levelsCleared20', huerings), 20);
  assert.strictEqual(games.stepsByRules('levelsCleared500', huerings), 100);
  assert.strictEqual(games.stepsByRules('perfect', huerings), null);
  const phantom = [{ match: '^classicLevelsCleared(\\d+)$', steps: '$1' }, { match: '^allClassicLevelsCleared$', steps: 100 }];
  assert.strictEqual(games.stepsByRules('allClassicLevelsCleared', phantom), 100);
  assert.strictEqual(games.incremental(1), 0);
  assert.strictEqual(games.incremental(2), 2);
  assert.strictEqual(games.shortId('com.fleon.game.achievement.levels.10', 'com.fleon.game.achievement.'), 'levels.10');
  assert.strictEqual(games.shortId('com.fleon.zyl.achievements.steady'), 'steady');
});

test('an achievement as Play takes it', () => {
  const body = games.achievementBody(item, 2, options);
  assert.strictEqual(body.achievementType, 'INCREMENTAL');
  assert.strictEqual(body.stepsToUnlock, 20);
  assert.strictEqual(body.initialState, 'REVEALED');
  assert.strictEqual(body.draft.sortRank, 3);
  assert.deepStrictEqual(body.draft.name.translations.map((t) => t.locale), ['en-US', 'es-419']);
  const standard = games.achievementBody({ ...item, steps: 0, hidden: true, points: 0 }, 0, options);
  assert.strictEqual(standard.achievementType, 'STANDARD');
  assert.strictEqual(standard.stepsToUnlock, undefined);
  assert.strictEqual(standard.initialState, 'HIDDEN');
  assert.strictEqual(standard.draft.pointValue, games.MIN_POINTS);
  assert.throws(() => games.achievementBody({ ...item, points: 7 }, 0, options), /multiple of 5/);
  const english = games.achievementBody(item, 0, { ...options, languages: ['en-US'] });
  assert.deepStrictEqual(english.draft.name.translations.map((t) => t.locale), ['en-US']);
});

test('a leaderboard as Play takes it, its range only when given', () => {
  const board = { id: 'stars', order: 'LARGER_IS_BETTER', localizations: { 'en-US': 'Stars' } };
  assert.strictEqual(games.leaderboardBody(board, 0, options).scoreMin, undefined);
  const ranged = games.leaderboardBody({ ...board, min: 1, max: 1000 }, 0, options);
  assert.strictEqual(ranged.scoreMin, '1');
  assert.strictEqual(ranged.scoreMax, '1000');
  assert.strictEqual(games.englishName(ranged), 'Stars');
});

test('comparing ignores the order and the order of keys', () => {
  const wanted = games.achievementBody(item, 0, options);
  const live = JSON.parse(JSON.stringify(wanted));
  live.draft.sortRank = 9;
  live.draft.name.translations.reverse();
  assert.strictEqual(games.comparable(live), games.comparable(wanted));
  live.draft.pointValue = 15;
  assert.notStrictEqual(games.comparable(live), games.comparable(wanted));
  // What's published counts when there's no draft.
  assert.strictEqual(games.comparable({ ...wanted, draft: undefined, published: wanted.draft }), games.comparable(wanted));
});

test('the mapping names each Play ID, with steps for an incremental one', () => {
  const wanted = [{ item, body: games.achievementBody(item, 0, options) }, { item: { ...item, id: 'b' }, body: games.achievementBody({ ...item, id: 'b', steps: 0 }, 1, options) }];
  const mapping = games.mapping('123', wanted, [], { [item.id]: 'CgkI1', b: 'CgkI2' }, {});
  assert.deepStrictEqual(mapping, { applicationId: '123', achievements: { [item.id]: { id: 'CgkI1', steps: 20 }, b: { id: 'CgkI2' } }, leaderboards: {} });
});
