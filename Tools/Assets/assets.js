#!/usr/bin/env node
'use strict';
// A game's asset names, for every game on this runtime: finds the image and
// sound names its Swift passes (txtr, sprite, tinted, sliced,
// SKTexture(imageNamed:), SKSpriteNode(imageNamed:), UIImage(named:),
// playSound, playMusic, AudioManager.shared.play/playMusic/playEffect,
// AudioConfiguration.Sound, playSoundFileNamed) and checks each against its
// asset catalogs and sound files. A game keeps its settings in assets.json
// beside a two-line assets.js that runs this one. README.md beside this file.
//
//   node <game assets dir>/assets.js check [--json]
//   node Tools/Assets/assets.js --dir <game assets dir> check [--json]
//
// Commands:
//   check   names asked for that no catalog or sound folder has (exit 1 on
//           any), assets nothing names, assets a run-time name may reach,
//           and the names built at run time, which can't be checked.
//
//   --json        the report as JSON
//   --quiet       counts only
//   --help, -h    print this and stop

const fs = require('fs');
const path = require('path');
const lib = require('./lib');

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
function option(name, fallback) {
  const at = argv.indexOf(name);
  if (at < 0) return fallback;
  const value = argv[at + 1];
  if (value === undefined || value.startsWith('--')) die(`${name} needs a value`);
  argv.splice(at, 2);
  return value;
}

function die(message) {
  console.error(`assets: ${message}`);
  process.exit(2);
}

if (flag('--help') || flag('-h')) {
  const source = fs.readFileSync(__filename, 'utf8').split('\n');
  console.log(source.slice(2, source.findIndex((l) => l.startsWith('const fs'))).map((l) => l.replace(/^\/\/ ?/, '')).join('\n').trim());
  process.exit(0);
}

const DIR = path.resolve(option('--dir', process.env.ASSETS_DIR ?? '') || die('run it through a game\'s assets.js, or pass --dir <game assets dir>'));
const command = argv.find((a) => !a.startsWith('--'));
if (command !== 'check') die(command ? `no command ${command}` : 'say check');

const settingsFile = path.join(DIR, 'assets.json');
const settings = fs.existsSync(settingsFile) ? JSON.parse(fs.readFileSync(settingsFile, 'utf8')) : {};
const ROOT = path.resolve(DIR, settings.root ?? '../..');
const resolve = (list, fallback) => [].concat(list ?? fallback).map((p) => path.resolve(ROOT, p));
const sources = resolve(settings.sources, 'Source');
const catalogs = resolve(settings.catalogs, []);
const soundDirs = resolve(settings.sounds, []);
const ignore = new Set(settings.ignore ?? []);
const rel = (file) => path.relative(ROOT, file);

function swiftFiles(dir) {
  if (!fs.existsSync(dir)) die(`no source folder ${rel(dir)}`);
  const files = [];
  const walk = (folder) => {
    for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
      const full = path.join(folder, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.swift')) files.push(full);
    }
  };
  walk(dir);
  return files.sort();
}

const files = sources.flatMap(swiftFiles);
const texts = new Map(files.map((f) => [f, fs.readFileSync(f, 'utf8')]));
// `String` enums name sounds (and images) by their raw values.
const enums = {};
for (const text of texts.values()) Object.assign(enums, lib.stringEnums(text));
if (settings.enums) for (const name of Object.keys(enums)) if (!settings.enums.includes(name)) delete enums[name];

const images = [];
const sounds = [];
const unchecked = [];
for (const [file, text] of texts) {
  const found = lib.scanSwift(text, enums, settings.calls ?? {});
  const at = (item) => ({ ...item, file: rel(file) });
  images.push(...found.images.map(at));
  sounds.push(...found.sounds.map(at));
  unchecked.push(...found.unchecked.map(at));
}

const haveImages = new Set();
for (const catalog of catalogs) {
  if (!fs.existsSync(catalog)) die(`no asset catalog ${rel(catalog)}`);
  for (const name of lib.catalogImages(catalog)) haveImages.add(name);
}
const haveSounds = new Set();
for (const dir of soundDirs) {
  if (!fs.existsSync(dir)) die(`no sound folder ${rel(dir)}`);
  for (const name of lib.soundFiles(dir)) haveSounds.add(name);
}
for (const name of ignore) {
  haveImages.delete(name);
  haveSounds.delete(name);
}

const imageReport = lib.compare({ used: images.filter((u) => !ignore.has(u.name)), have: haveImages, unchecked: unchecked.filter((u) => u.kind === 'images') });
const soundReport = lib.compare({ used: sounds.filter((u) => !ignore.has(u.name)), have: haveSounds, unchecked: unchecked.filter((u) => u.kind === 'sounds'), variants: true });
const report = {
  images: { named: images.length, catalog: haveImages.size, ...imageReport },
  sounds: { named: sounds.length, files: haveSounds.size, ...soundReport },
  unchecked,
};

if (flag('--json')) {
  console.log(JSON.stringify(report, null, 2));
} else {
  const counts = (kind, r, have) =>
    `${kind}: ${r.named} named, ${have} there; ${r.missing.length} missing, ${r.unused.length} unused, ${r.maybeUsed.length} maybe used by a run-time name`;
  console.log(counts('images', report.images, haveImages.size));
  console.log(counts('sounds', report.sounds, haveSounds.size));
  console.log(`unchecked: ${unchecked.length} names built at run time`);
  if (!flag('--quiet')) {
    for (const [kind, r] of [['image', report.images], ['sound', report.sounds]]) {
      for (const m of r.missing) console.log(`missing ${kind} "${m.name}" at ${m.file}:${m.line}`);
      for (const name of r.unused) console.log(`unused ${kind} ${name}`);
      for (const name of r.maybeUsed) console.log(`maybe used ${kind} ${name}`);
    }
    for (const u of unchecked) console.log(`unchecked ${u.kind.slice(0, -1)} ${u.expression} at ${u.file}:${u.line}`);
  }
}
process.exit(report.images.missing.length + report.sounds.missing.length > 0 ? 1 : 0);
