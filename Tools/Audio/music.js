#!/usr/bin/env node
'use strict';
// A game's soundtrack, for every game on this runtime: finds where each
// track loops musically, cuts and encodes the tracks the game bundles so
// they loop seamlessly, and checks the result. A game keeps its settings in
// music.json beside a two-line music.js that runs this one. README.md beside
// this file. macOS only (afconvert and AVFoundation).
//
//   node <game audio dir>/music.js <command> [options]
//   node Tools/Audio/music.js --dir <game audio dir> <command> [options]
//
// Commands:
//   loops    finds each master's intro, ending and a loop on matching bars,
//            into the loops file (find-loops.swift). --only <master> for
//            one track, --debug <dir> for each track's similarity map and
//            candidates.
//   export   cuts each master at its loop (the seam crossfaded into the
//            file), encodes it to AAC (.m4a) in the output folder, writes
//            the Swift file of loop points, then runs check.
//   check    decodes the exported files and checks them against the
//            masters: the encoder delay is compensated, the seams render
//            through AVAudioPlayerNode as the game plays them, and prints
//            each seam's measurements. --seams <dir> writes each seam as a
//            WAV to listen to.
//
//   --help, -h   print this and stop

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const lib = require('./lib');

const argv = process.argv.slice(2);
function option(name) {
  const at = argv.indexOf(name);
  if (at < 0) return undefined;
  const value = argv[at + 1];
  if (value === undefined || value.startsWith('--')) die(`${name} needs a value`);
  argv.splice(at, 2);
  return value;
}

function die(message) {
  console.error(`music: ${message}`);
  process.exit(2);
}

if (argv.includes('--help') || argv.includes('-h')) {
  const source = fs.readFileSync(__filename, 'utf8').split('\n');
  console.log(source.slice(2, source.findIndex((l) => l.startsWith('const fs'))).map((l) => l.replace(/^\/\/ ?/, '')).join('\n').trim());
  process.exit(0);
}

const dir = option('--dir') || process.env.MUSIC_DIR;
if (!dir) die('run it through the game\'s Tools/Audio/music.js, or pass --dir');
const only = option('--only');
const debugDir = option('--debug');
const seamDir = option('--seams');
const command = argv.shift();
if (!['loops', 'export', 'check'].includes(command)) die('a command: loops, export or check (--help)');
if (argv.length) die(`unknown arguments: ${argv.join(' ')}`);
if (process.platform !== 'darwin') die('needs macOS (afconvert and AVFoundation)');

let settings;
try {
  settings = lib.readSettings(path.resolve(dir));
} catch (error) {
  die(error.message);
}
if (only && !settings.tracks.some((t) => t.master === only)) die(`no track "${only}" in music.json`);

const tracks = settings.tracks.map((track) => {
  const file = lib.masterFile(settings, track.master);
  if (lib.isLfsPointer(file)) die(`${path.relative(settings.root, file)} is a Git LFS pointer: download it first (git lfs pull)`);
  return { ...track, file };
});

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'music-'));
try {
  if (command === 'loops') findLoops();
  if (command === 'export') exportTracks();
  if (command === 'export' || command === 'check') check();
} catch (error) {
  console.error(`music: ${error.message}`);
  process.exitCode = 1;
} finally {
  fs.rmSync(scratch, { recursive: true, force: true });
}

/// Runs find-loops.swift with the settings it needs.
function swift(args) {
  const file = path.join(scratch, 'settings.json');
  fs.writeFileSync(file, JSON.stringify({ loops: settings.loops, music: settings.output, tracks }));
  execFileSync('xcrun', ['swift', '-O', path.join(__dirname, 'find-loops.swift'), ...args, '--settings', file], { stdio: 'inherit' });
}

function findLoops() {
  swift([...(only ? ['--only', only] : []), ...(debugDir ? ['--debug', path.resolve(debugDir)] : [])]);
}

function exportTracks() {
  if (!fs.existsSync(settings.loops)) throw new Error(`no loops file at ${path.relative(settings.root, settings.loops)}; run music.js loops`);
  const loops = JSON.parse(fs.readFileSync(settings.loops, 'utf8'));
  fs.mkdirSync(settings.output, { recursive: true });
  const entries = [];
  for (const track of tracks) {
    // Decoded through afconvert, as AVAudioFile reads it: a compressed
    // master's encoder delay and padding are dropped.
    const decoded = path.join(scratch, `${track.resource}-master.wav`);
    execFileSync('afconvert', ['-f', 'WAVE', '-d', 'LEF32', track.file, decoded]);
    const { sampleRate, samples, frames } = lib.readWav(decoded);
    fs.rmSync(decoded);
    const loop = loops[track.master];
    const problem = lib.loopProblem(track.master, loop, frames, sampleRate);
    if (problem) throw new Error(problem);
    const cut = path.join(scratch, `${track.resource}.wav`);
    lib.writeFloatWav(cut, sampleRate, lib.cutLoop(samples, loop));
    const output = path.join(settings.output, `${track.resource}.m4a`);
    // -s 2: constrained VBR around the target bitrate.
    execFileSync('afconvert', ['-f', 'm4af', '-d', 'aac', '-b', String(settings.bitrate), '-s', '2', cut, output]);
    fs.rmSync(cut);
    const size = (fs.statSync(output).size / 1e6).toFixed(1);
    const seconds = (frame) => (frame / sampleRate).toFixed(2);
    console.log(`${track.resource}.m4a: ${size} MB, loops ${seconds(loop.loopStart)}s → ${seconds(loop.loopEnd)}s`);
    entries.push({ resource: track.resource, loop });
  }
  fs.mkdirSync(path.dirname(settings.swift), { recursive: true });
  fs.writeFileSync(settings.swift, lib.swiftSource(entries));
  console.log(`Wrote ${path.relative(settings.root, settings.swift)}`);
}

function check() {
  try {
    swift(['check', ...(seamDir ? ['--seams', path.resolve(seamDir)] : [])]);
  } catch {
    console.error('music: the loop check failed (see above)');
    process.exitCode = 1;
  }
}
