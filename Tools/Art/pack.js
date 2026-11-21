#!/usr/bin/env node
'use strict';
// Packs a game's asset catalogs into its Android art (index.json and its
// pages) with xcassets-art.js, under the memory guard: what every game's
// Android/Scripts/art.sh runs, through Scripts/art.sh. It builds the ASTC
// encoder the first time a checkout needs it, and with a cache keeps each
// pack under a hash of everything it is made from, so a pack whose inputs
// haven't changed is copied rather than encoded again.
//
//   Scripts/art.sh [--png] [--out <dir>] [--cache <dir>]
//
// The game's settings, from its Android/Scripts/runtime.sh, are paths from
// the game's root (GAME_ANDROID_DIR's parent):
//
//   GAME_ANDROID_DIR   the game's Android directory (default: the runtime's parent)
//   SKA_ART_CATALOGS   its catalogs, space-separated, in order (default Assets/Assets.xcassets)
//   SKA_ART_OUT        where the pack goes (default Android/Assets)
//   SKA_ART_PNG        1 for PNG pages, which need no encoder, instead of ASTC
//   SKA_ART_CACHE      a cache directory, as --cache
//
// Flags win over settings; their paths are from the current directory.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const RUNTIME_DIR = path.resolve(__dirname, '../..');
const PACKER = path.join(__dirname, 'xcassets-art.js');
const GUARD = path.join(RUNTIME_DIR, 'Tools/guard.js');
const BUILD_ENCODER = path.join(__dirname, 'ASTC/build-astcenc.sh');
// What a pack's bytes depend on besides its catalogs: the packer, the
// compressor and the encoder's pinned release.
const TOOLS = [PACKER, path.join(__dirname, 'ASTC/compress.js'), BUILD_ENCODER];
const MEMORY_GB = 12;
// Packs a cache keeps, the most recently used.
const CACHE_KEEP = 3;
const USAGE = 'Usage: Scripts/art.sh [--png] [--out <dir>] [--cache <dir>]';

/// The flags, or `{ error }`.
function parseArgs(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--png') flags.png = true;
    else if (arg === '--help' || arg === '-h') flags.help = true;
    else if (arg === '--out' || arg === '--cache') {
      const value = argv[++i];
      if (!value || value.startsWith('--')) return { error: `${arg} needs a directory` };
      flags[arg.slice(2)] = value;
    } else return { error: `unknown argument ${arg}` };
  }
  return flags;
}

/// What to pack and where, from the flags and the game's settings.
function settings({ flags, env, cwd, runtimeDir = RUNTIME_DIR }) {
  const androidDir = path.resolve(env.GAME_ANDROID_DIR || path.join(runtimeDir, '..'));
  const root = path.dirname(androidDir);
  const catalogs = (env.SKA_ART_CATALOGS || 'Assets/Assets.xcassets').split(/\s+/).filter(Boolean)
    .map((catalog) => path.resolve(root, catalog));
  const out = flags.out ? path.resolve(cwd, flags.out) : path.resolve(root, env.SKA_ART_OUT || 'Android/Assets');
  const cache = flags.cache ? path.resolve(cwd, flags.cache) : env.SKA_ART_CACHE ? path.resolve(root, env.SKA_ART_CACHE) : null;
  return { root, catalogs, out, cache, png: Boolean(flags.png) || env.SKA_ART_PNG === '1' };
}

/// Every file under `dir` but hidden ones (.DS_Store), as sorted paths relative to it.
function filesUnder(dir) {
  const found = [];
  const walk = (rel) => {
    for (const entry of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
      if (entry.name.startsWith('.')) continue;
      const child = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory()) walk(child);
      else if (entry.isFile()) found.push(child);
    }
  };
  walk('');
  return found.sort();
}

const digest = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

/// A hash of everything a pack is made from: the tools, the page format and
/// each catalog's files, by their place in the list and their paths inside
/// it, so the same catalogs in another checkout or worktree hash alike.
function inputKey({ catalogs, png, tools = TOOLS }) {
  const hash = crypto.createHash('sha256');
  hash.update(`format ${png ? 'png' : 'astc'}\n`);
  for (const tool of tools) hash.update(`tool ${path.basename(tool)} ${digest(tool)}\n`);
  catalogs.forEach((catalog, index) => {
    if (!fs.existsSync(catalog)) throw new Error(`No catalog at ${catalog}`);
    hash.update(`catalog ${index}\n`);
    for (const file of filesUnder(catalog)) hash.update(`${file}\0${digest(path.join(catalog, file))}\n`);
  });
  return hash.digest('hex').slice(0, 16);
}

/// Empties `out` for a pack, as the packer does: only when it is missing,
/// empty or an earlier pack (it holds index.json).
function clearOut(out) {
  if (fs.existsSync(out)) {
    const inside = fs.readdirSync(out);
    if (inside.length && !inside.includes('index.json')) {
      throw new Error(`Won't clear ${out}: it is neither empty nor a previous pack (no index.json)`);
    }
  }
  fs.rmSync(out, { recursive: true, force: true });
}

/// Removes all but the `keep` most recently used packs in `cache`.
function prune(cache, keep = CACHE_KEEP) {
  const packs = fs.readdirSync(cache, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^[0-9a-f]{16}$/.test(entry.name))
    .map((entry) => ({ dir: path.join(cache, entry.name), used: fs.statSync(path.join(cache, entry.name)).mtimeMs }))
    .sort((a, b) => b.used - a.used);
  for (const { dir } of packs.slice(keep)) fs.rmSync(dir, { recursive: true, force: true });
}

/// Puts the pack in `out` into `cache` under `key`, whole or not at all.
function store(cache, key, out) {
  const partial = path.join(cache, `${key}.partial-${process.pid}`);
  fs.rmSync(partial, { recursive: true, force: true });
  fs.cpSync(out, partial, { recursive: true });
  try {
    fs.renameSync(partial, path.join(cache, key));
  } catch {
    fs.rmSync(partial, { recursive: true, force: true }); // another run stored it first
  }
}

function main(argv) {
  const flags = parseArgs(argv);
  if (flags.help) { console.log(USAGE); return 0; }
  if (flags.error) { console.error(`art: ${flags.error}\n${USAGE}`); return 2; }
  const { catalogs, out, cache, png } = settings({ flags, env: process.env, cwd: process.cwd() });

  let key = null;
  if (cache) {
    key = inputKey({ catalogs, png });
    const hit = path.join(cache, key);
    if (fs.existsSync(hit)) {
      clearOut(out);
      fs.cpSync(hit, out, { recursive: true });
      const now = new Date();
      fs.utimesSync(hit, now, now);
      console.log(`art: unchanged, copied pack ${key} from ${cache} → ${out}`);
      return 0;
    }
  }

  if (!png && !fs.existsSync(require('./ASTC/compress').ENCODER)) {
    console.log('art: building the ASTC encoder (Tools/Art/ASTC/build-astcenc.sh)');
    const built = spawnSync('bash', [BUILD_ENCODER], { stdio: 'inherit' });
    if (built.status !== 0) return built.status || 1;
  }

  const packed = spawnSync(process.execPath, [
    GUARD, String(MEMORY_GB), '--', process.execPath, PACKER, out, ...catalogs, ...(png ? ['--png'] : []),
  ], { stdio: 'inherit' });
  if (packed.status !== 0) return packed.status ?? 1;

  if (cache) {
    fs.mkdirSync(cache, { recursive: true });
    store(cache, key, out);
    prune(cache);
    console.log(`art: cached pack ${key} in ${cache}`);
  }
  return 0;
}

module.exports = { parseArgs, settings, filesUnder, inputKey, clearOut, prune, store, CACHE_KEEP, MEMORY_GB };

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    console.error(`art: ${error.message}`);
    process.exitCode = 1;
  }
}
