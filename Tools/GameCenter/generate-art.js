#!/usr/bin/env node
'use strict';
// Paints a game's Game Center achievement images with the Codex CLI's image
// generation: one tool for every game on this runtime, run through the game's
// own two-line generate-art.js on its Game Center directory (README.md beside
// this file). Art/brief.md is the shared art direction and each
// Art/<name>.txt describes one image; its first line names the references to
// attach (`References: a, b`):
//   file:<path>      an image in the repository (from its root)
//   sprite:<set>     one image set's @3x file from the asset catalog
//   anything else    what the game's references module resolves it to, else
//                    <name>.png among the sheets that module renders
// A prompt named `<name>-cutout` paints a subject on a transparent ground and
// is kept as a PNG, to be composed by another tool; everything else is a JPEG.
// Codex only paints: one image a run. Results land in Images/<name>.jpg at
// 1024 x 1024. Generation isn't deterministic: review each image and rerun a
// name to draw it again.
//
//   node <game>/generate-art.js [--art <folder>] [name...]
//
// No names: every image not drawn yet. `--art <folder>` paints another
// folder's prompts the same way, with its own brief.md, into the Images
// folder beside it (an in-app purchase's art, say). CODEX picks the Codex
// binary and ART_CATALOG another asset catalog.
//
// Settings, all optional: `art` in gamecenter.json beside the game's script:
//   references  a game module exporting prepare(dir, tools), which renders
//               reference sheets into dir, and resolve(ref, dir), which
//               returns a reference's file or null; tools is { spriteFile,
//               catalog, root }
//   catalog     the asset catalog (default Assets/Assets.xcassets)
//   root        the repository root (default ../..)
//   model, effort, size, jpegQuality, parallel
// each path relative to the Game Center directory.

const fs = require('fs');

if (process.argv.slice(2).some((a) => a === '--help' || a === '-h')) {
  const lines = fs.readFileSync(__filename, 'utf8').split('\n');
  const end = lines.findIndex((l, i) => i > 2 && !l.startsWith('//'));
  console.log(lines.slice(2, end).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}

const os = require('os');
const path = require('path');
const { spawn, execFileSync } = require('child_process');
const gc = require('./lib');

const args = process.argv.slice(2);
const take = (name) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : null; };
const dirFlag = take('--dir');
if (!dirFlag && !process.env.GAME_CENTER_DIR) {
  console.error('Which game? Run its own generate-art.js, or pass --dir <its Game Center directory>.');
  process.exit(2);
}
const HERE = path.resolve(dirFlag ?? process.env.GAME_CENTER_DIR);
const settingsFile = path.join(HERE, 'gamecenter.json');
const SETTINGS = (fs.existsSync(settingsFile) ? JSON.parse(fs.readFileSync(settingsFile, 'utf8')) : {}).art ?? {};
const ROOT = path.resolve(HERE, SETTINGS.root ?? '../..');
const artFlag = take('--art');
const ART = artFlag ? path.resolve(artFlag) : path.join(HERE, 'Art');
const IMAGES = path.join(path.dirname(ART), 'Images');
const CATALOG = path.resolve(process.env.ART_CATALOG
  || (SETTINGS.catalog ? path.resolve(HERE, SETTINGS.catalog) : path.join(ROOT, 'Assets/Assets.xcassets')));
const CODEX = process.env.CODEX || 'codex';
const MODEL = SETTINGS.model ?? 'gpt-6.1-sol';
const EFFORT = SETTINGS.effort ?? 'low';
const SIZE = SETTINGS.size ?? 1024;
const JPEG_QUALITY = SETTINGS.jpegQuality ?? 90;
const PARALLEL = SETTINGS.parallel ?? 4;
const GAME = SETTINGS.references ? require(path.resolve(HERE, SETTINGS.references)) : {};

// The @3x file of an image set, wherever it sits in the catalog.
function spriteFile(set) {
  const folder = fs.readdirSync(CATALOG).find((name) => fs.existsSync(path.join(CATALOG, name, `${set}.imageset`)));
  if (!folder) throw new Error(`no image set ${set}`);
  const dir = path.join(CATALOG, folder, `${set}.imageset`);
  return path.join(dir, fs.readdirSync(dir).find((name) => name.endsWith('@3x.png')));
}

function reference(ref, dir) {
  if (ref.startsWith('file:')) return path.resolve(ROOT, ref.slice('file:'.length));
  if (ref.startsWith('sprite:')) return spriteFile(ref.slice('sprite:'.length));
  return GAME.resolve?.(ref, dir) ?? path.join(dir, `${ref}.png`);
}

function draw(name, dir, brief) {
  const { references, body } = gc.parsePrompt(fs.readFileSync(path.join(ART, `${name}.txt`), 'utf8'));
  const files = references.map((ref) => reference(ref, dir));
  const output = path.join(dir, 'out', `${name}.png`);
  const codexArgs = ['exec', '-m', MODEL, '-c', `model_reasoning_effort="${EFFORT}"`, '--skip-git-repo-check',
    '-s', 'workspace-write', '-C', dir, ...files.flatMap((file) => ['-i', file])];
  return new Promise((resolve) => {
    const codex = spawn(CODEX, codexArgs, { stdio: ['pipe', 'ignore', 'inherit'] });
    const fail = (why) => {
      console.error(`${name}: ${why}`);
      resolve(false);
    };
    // A Codex run that ends early closes its input; the exit is what matters.
    codex.stdin.on('error', () => {});
    codex.on('error', (error) => fail(error.message));
    codex.stdin.end(gc.promptFor(brief, body, name));
    codex.on('close', (code) => {
      if (!fs.existsSync(output)) return fail(`Codex saved no image (exit ${code})`);
      const file = gc.imageFile(name);
      try {
        const format = file.endsWith('.png') ? ['png'] : ['jpeg', '-s', 'formatOptions', String(JPEG_QUALITY)];
        execFileSync('sips', ['-s', 'format', ...format, '-z', String(SIZE), String(SIZE),
          output, '--out', path.join(IMAGES, file)], { stdio: 'ignore' });
      } catch (error) {
        return fail(`converting failed: ${error.message}`);
      }
      console.log(`${name}: ${path.relative(path.dirname(IMAGES), path.join(IMAGES, file))}`);
      resolve(true);
    });
  });
}

async function main() {
  const all = fs.readdirSync(ART).filter((file) => file.endsWith('.txt')).map((file) => file.replace(/\.txt$/, ''));
  const names = gc.namesToPaint(all, args, (file) => fs.existsSync(path.join(IMAGES, file)));
  if (!names.length) return console.log('Every image is drawn; name one to draw it again.');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'achievement-art-'));
  fs.mkdirSync(path.join(dir, 'out'));
  fs.mkdirSync(IMAGES, { recursive: true });
  GAME.prepare?.(dir, { spriteFile, catalog: CATALOG, root: ROOT });
  const brief = fs.readFileSync(path.join(ART, 'brief.md'), 'utf8');
  const queue = [...names];
  const worker = async () => {
    while (queue.length) await draw(queue.shift(), dir, brief);
  };
  await Promise.all(Array.from({ length: Math.min(PARALLEL, names.length) }, worker));
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
