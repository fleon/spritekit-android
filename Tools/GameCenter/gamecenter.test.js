'use strict';
// node --test Tools/GameCenter/gamecenter.test.js: the pure parts (lib.js).

const test = require('node:test');
const assert = require('node:assert');
const gc = require('./lib');

const text = { name: 'First', beforeEarnedDescription: 'Clear a level.', afterEarnedDescription: 'You cleared a level.' };
const achievement = {
  vendorIdentifier: 'com.example.game.first', referenceName: 'First', points: 10, image: 'Images/first.jpg',
  localizations: { 'en-US': text, 'de-DE': { ...text, name: 'Erstes' } },
};
const leaderboard = {
  vendorIdentifier: 'com.example.game.score', referenceName: 'Score', formatter: 'INTEGER', sort: 'DESC', submissionType: 'BEST_SCORE',
  localizations: { 'en-US': { name: 'Score' } },
};
const definitions = { app: '1', achievements: [achievement], leaderboards: [leaderboard] };

const resource = (id, attributes) => ({ id, attributes });
// App Store Connect holding exactly the definitions, images of 100 bytes.
function inSync() {
  const localizations = (item, image) => new Map(Object.entries(item.localizations).map(([locale, t]) => [locale, {
    resource: resource(`${item.vendorIdentifier}/${locale}`, { locale, ...t }),
    image: image ? resource(`${item.vendorIdentifier}/${locale}/image`, { fileSize: 100 }) : null,
  }]));
  return {
    detail: { id: 'detail' },
    achievements: new Map([[achievement.vendorIdentifier, {
      resource: resource('a1', { vendorIdentifier: achievement.vendorIdentifier, referenceName: 'First', points: 10, showBeforeEarned: true, repeatable: false }),
      version: resource('a1v', { version: 1 }),
      localizations: localizations(achievement, true),
    }]]),
    leaderboards: new Map([[leaderboard.vendorIdentifier, {
      resource: resource('l1', { vendorIdentifier: leaderboard.vendorIdentifier, referenceName: 'Score', defaultFormatter: 'INTEGER', scoreSortType: 'DESC', submissionType: 'BEST_SCORE', visibility: 'SHOW_FOR_ALL' }),
      version: resource('l1v', { version: 1 }),
      localizations: localizations(leaderboard, false),
    }]]),
  };
}
const sizeOf = () => 100;
const described = (actions) => actions.map((a) => a.description);

test('literal: a leading @ is doubled, so asc reads it as text', () => {
  assert.strictEqual(gc.literal('@home'), '@@home');
  assert.strictEqual(gc.literal('a@b'), 'a@b');
  assert.strictEqual(gc.literal(5), '5');
});

test('newest: the highest version, whatever order they come in', () => {
  assert.strictEqual(gc.newest([resource('b', { version: 2 }), resource('a', { version: 1 })]).id, 'b');
  assert.strictEqual(gc.newest([]), null);
  assert.strictEqual(gc.newest(null), null);
});

test('problems: a sound file has none', () => {
  assert.deepStrictEqual(gc.problems(definitions), []);
  assert.deepStrictEqual(gc.problems({ app: '1', achievements: [achievement] }), []);
});

test('problems: missing fields, duplicates, points and sorts', () => {
  const found = gc.problems({
    achievements: [
      achievement,
      { ...achievement, points: 101 },
      { vendorIdentifier: 'x', referenceName: 'X', points: 5, localizations: { 'en-US': { name: 'X' } } },
    ],
    leaderboards: [{ ...leaderboard, sort: 'UP', localizations: {} }],
  });
  assert.ok(found.includes('no "app" (the App Store Connect app ID)'));
  assert.ok(found.includes('com.example.game.first: com.example.game.first is defined twice'));
  assert.ok(found.includes('com.example.game.first: points must be a whole number from 0 to 100'));
  assert.ok(found.includes('x: en-US has no beforeEarnedDescription'));
  assert.ok(found.includes('com.example.game.score: sort must be ASC or DESC'));
  assert.ok(found.includes('com.example.game.score: no localizations'));
  const many = Array.from({ length: 11 }, (_, i) => ({ ...achievement, vendorIdentifier: `a${i}`, points: 100 }));
  assert.ok(gc.problems({ app: '1', achievements: many }).includes('the achievements give 1100 points; Game Center allows 1000'));
});

test('plan: in sync, nothing to do', () => {
  assert.deepStrictEqual(gc.plan(definitions, inSync(), sizeOf), []);
});

test('plan: no Game Center yet turns it on and creates everything, in order', () => {
  const actions = gc.plan(definitions, { detail: null, achievements: new Map(), leaderboards: new Map() }, sizeOf);
  assert.deepStrictEqual(described(actions), [
    'turn on Game Center for the app',
    'create "First" (com.example.game.first, 10 points) with 2 localizations and images',
    'create leaderboard "Score" (com.example.game.score, INTEGER, DESC, BEST_SCORE) with 1 localizations',
  ]);
  assert.deepStrictEqual(actions.map((a) => a.kind), ['details', 'create-achievement', 'create-leaderboard']);
});

test('plan: changed settings, texts and images', () => {
  const state = inSync();
  const a = state.achievements.get(achievement.vendorIdentifier);
  a.resource.attributes.points = 5;
  a.localizations.get('de-DE').resource.attributes.name = 'Alt';
  a.localizations.get('en-US').image = {}; // asc's empty answer
  a.localizations.get('de-DE').image.attributes.fileSize = 99;
  const l = state.leaderboards.get(leaderboard.vendorIdentifier);
  l.resource.attributes.scoreSortType = 'ASC';
  l.localizations.delete('en-US');
  const actions = gc.plan(definitions, state, sizeOf);
  assert.deepStrictEqual(described(actions), [
    'update "First" (10 points)',
    'First: upload the en-US image',
    'First: update de-DE "Erstes"',
    'First: replace the de-DE image',
    'update leaderboard "Score" (INTEGER, DESC, BEST_SCORE)',
    'Score: add en-US "Score"',
  ]);
  assert.strictEqual(actions[3].imageId, 'com.example.game.first/de-DE/image');
  assert.strictEqual(actions[5].versionId, 'l1v');
});

test('plan: optional fields are compared only when given', () => {
  const state = inSync();
  state.leaderboards.get(leaderboard.vendorIdentifier).localizations.get('en-US').resource.attributes.formatterSuffix = ' pts';
  assert.deepStrictEqual(gc.plan(definitions, state, sizeOf), []);
  const hidden = { ...definitions, achievements: [{ ...achievement, hidden: true }], leaderboards: [{ ...leaderboard, localizations: { 'en-US': { name: 'Score', formatterSuffix: ' points' } } }] };
  assert.deepStrictEqual(described(gc.plan(hidden, state, sizeOf)), ['update "First" (10 points)', 'Score: update en-US "Score"']);
  assert.deepStrictEqual(gc.achievementSettings({ hidden: true, repeatable: false }), ['--show-before-earned', 'false', '--repeatable', 'false']);
  assert.deepStrictEqual(gc.leaderboardText({ name: 'Score', formatterSuffix: ' points' }), ['--name', 'Score', '--formatter-suffix', ' points']);
});

test('plan: an existing one with no version is an error', () => {
  const state = inSync();
  state.achievements.get(achievement.vendorIdentifier).version = null;
  assert.throws(() => gc.plan(definitions, state, sizeOf), /has no version/);
});

test('art: prompts, file names and what to paint', () => {
  assert.deepStrictEqual(gc.parsePrompt('References: sprite:Hero, file:a.png,sheet\nA hero.\n\n'), {
    references: ['sprite:Hero', 'file:a.png', 'sheet'], body: 'A hero.',
  });
  assert.deepStrictEqual(gc.parsePrompt('References:\nNothing attached.').references, []);
  assert.strictEqual(gc.imageFile('hero'), 'hero.jpg');
  assert.strictEqual(gc.imageFile('hero-cutout'), 'hero-cutout.png');
  assert.match(gc.promptFor('Brief', 'Body', 'hero'), /^Brief\n# This image\nBody\n\n.*save it as out\/hero\.png/s);
  const painted = new Set(['a.jpg', 'b-cutout.png']);
  assert.deepStrictEqual(gc.namesToPaint(['a', 'b-cutout', 'c'], [], (file) => painted.has(file)), ['c']);
  assert.deepStrictEqual(gc.namesToPaint(['a', 'c'], ['a'], () => true), ['a']);
  assert.throws(() => gc.namesToPaint(['a'], ['z'], () => false), /no prompt for z/);
});
