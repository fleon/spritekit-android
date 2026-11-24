'use strict';
// The pieces of music.js that need no audio tools: the game's settings, WAV
// reading and writing, the loop cut and the generated Swift.

const fs = require('fs');
const path = require('path');

/// The formats a master may come in, the first found winning.
const MASTER_EXTENSIONS = ['wav', 'aif', 'aiff', 'caf', 'flac', 'm4a', 'mp3'];

/// Frames the exported file runs on past the loop end (see `cutLoop`).
const TAIL_FRAMES = 8192;

/// The game's settings from music.json in `dir`, with every path resolved.
function readSettings(dir) {
  const file = path.join(dir, 'music.json');
  if (!fs.existsSync(file)) throw new Error(`No music.json in ${dir}`);
  const json = JSON.parse(fs.readFileSync(file, 'utf8'));
  const root = path.resolve(dir, json.root || '../..');
  const at = (value, fallback) => path.resolve(root, value || fallback);
  if (!json.tracks || typeof json.tracks !== 'object' || !Object.keys(json.tracks).length) {
    throw new Error(`${file} lists no tracks`);
  }
  const tracks = Object.entries(json.tracks).map(([master, spec]) => {
    const track = typeof spec === 'string' ? { resource: spec } : { ...spec };
    if (!track.resource || !/^[\w-]+$/.test(track.resource)) throw new Error(`Track "${master}" needs a resource name (letters, digits, - and _)`);
    if (track.minLoopSeconds !== undefined && !(track.minLoopSeconds >= 0)) throw new Error(`Track "${master}": minLoopSeconds must be a number of seconds`);
    if (track.medley !== undefined) medleyProblem(master, track.medley);
    return { master, resource: track.resource, minLoopSeconds: track.minLoopSeconds || 0, ...(track.medley ? { medley: track.medley } : {}) };
  });
  const resources = new Set();
  for (const { resource } of tracks) {
    if (resources.has(resource)) throw new Error(`Two tracks export to ${resource}`);
    resources.add(resource);
  }
  return {
    root,
    masters: at(json.masters, 'Tools/Audio/Masters'),
    output: at(json.output, 'Assets/Music'),
    loops: at(json.loops, 'Tools/Audio/loops.json'),
    swift: at(json.swift, 'Source/Utils/MusicLoops.swift'),
    bitrate: json.bitrate || 128000,
    tracks,
  };
}

/// Throws when a track's medley isn't one `buildMedley` can build.
function medleyProblem(master, medley) {
  const fail = (why) => { throw new Error(`Track "${master}": medley ${why}`); };
  if (!medley || typeof medley !== 'object') fail('must be an object');
  if (!(medley.bpm > 0)) fail('needs the pieces\' common bpm');
  if (medley.blendBeats !== undefined && !(medley.blendBeats > 0)) fail('blendBeats must be a positive number of beats');
  if (medley.beatsPerBar !== undefined && !(Number.isInteger(medley.beatsPerBar) && medley.beatsPerBar > 0)) fail('beatsPerBar must be a positive whole number');
  if (!Array.isArray(medley.parts) || medley.parts.length < 2) fail('needs two or more parts');
  for (const part of medley.parts) {
    if (!part || typeof part.master !== 'string' || !part.master) fail('parts each name a master');
    if (!(part.firstDownbeat >= 0)) fail(`part "${part.master}" needs firstDownbeat (seconds)`);
    if (!(Number.isInteger(part.from) && Number.isInteger(part.to) && part.from >= 0 && part.to > part.from)) fail(`part "${part.master}" needs bars from < to`);
  }
}

/// Plays several masters in turn as one master, for a soundtrack that
/// alternates pieces sharing a tempo: the first part from its first frame to
/// its bar `to`, each other part from its bar `from` to its bar `to`, and the
/// first part again from its bar `from` to its own end, each handing over to
/// the next with an equal-power blend of `blendBeats` centred on the bar line.
/// The first part's second pass repeats its first one exactly, so the loop
/// search finds the whole round as the loop (similarity 1.0), and the track
/// then plays the first part's intro once and goes round the parts forever.
/// `pieces` maps each part's master to its decoded { sampleRate, samples }.
function buildMedley(medley, pieces) {
  const parts = medley.parts;
  const first = pieces[parts[0].master];
  const { sampleRate } = first;
  const channels = first.samples.length;
  for (const { master } of parts) {
    const piece = pieces[master];
    if (!piece) throw new Error(`Missing medley part "${master}"`);
    if (piece.sampleRate !== sampleRate || piece.samples.length !== channels) throw new Error(`Medley part "${master}" differs from "${parts[0].master}" in sample rate or channels`);
  }
  const beat = 60 / medley.bpm;
  const bar = (medley.beatsPerBar || 4) * beat;
  const blend = Math.round((medley.blendBeats || 4) * beat * sampleRate);
  const half = Math.floor(blend / 2);
  const frameAt = (part, b) => Math.round((part.firstDownbeat + b * bar) * sampleRate);
  const length = (part) => pieces[part.master].samples[0].length;
  for (const part of parts) {
    if (frameAt(part, part.from) - half < 0 || frameAt(part, part.to) - half + blend > length(part)) throw new Error(`Medley part "${part.master}": bars ${part.from}–${part.to} run past the master`);
  }
  // Runs of plain audio and blends, in order.
  const runs = [{ part: parts[0], start: 0, end: frameAt(parts[0], parts[0].to) - half }];
  parts.forEach((part, k) => {
    const next = parts[(k + 1) % parts.length];
    runs.push({ out: part, outStart: frameAt(part, part.to) - half, into: next, intoStart: frameAt(next, next.from) - half });
    const start = frameAt(next, next.from) - half + blend;
    runs.push({ part: next, start, end: k + 1 < parts.length ? frameAt(next, next.to) - half : length(next) });
  });
  const frames = runs.reduce((sum, r) => sum + (r.out ? blend : r.end - r.start), 0);
  const samples = Array.from({ length: channels }, () => new Float32Array(frames));
  let at = 0;
  for (const r of runs) {
    for (let c = 0; c < channels; c++) {
      if (r.out) {
        const a = pieces[r.out.master].samples[c];
        const b = pieces[r.into.master].samples[c];
        for (let i = 0; i < blend; i++) {
          const [gOut, gIn] = crossfadeGains((i + 1) / blend, 0);
          samples[c][at + i] = gOut * a[r.outStart + i] + gIn * b[r.intoStart + i];
        }
      } else {
        samples[c].set(pieces[r.part.master].samples[c].subarray(r.start, r.end), at);
      }
    }
    at += r.out ? blend : r.end - r.start;
  }
  return { sampleRate, samples, frames };
}

/// A master's file: `<master>.<ext>` in the masters folder.
function masterFile(settings, master) {
  for (const ext of MASTER_EXTENSIONS) {
    const file = path.join(settings.masters, `${master}.${ext}`);
    if (fs.existsSync(file)) return file;
  }
  throw new Error(`Missing master "${master}" in ${settings.masters} (${MASTER_EXTENSIONS.join(', ')})`);
}

/// Whether a file is a Git LFS pointer left in place of the real one.
function isLfsPointer(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const head = Buffer.alloc(7);
    fs.readSync(fd, head, 0, 7, 0);
    return head.toString('ascii') === 'version';
  } finally {
    fs.closeSync(fd);
  }
}

/// Reads a PCM (16/24/32-bit integer) or 32-bit float WAV into one
/// Float32Array per channel.
function readWav(file) {
  const buf = fs.readFileSync(file);
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') throw new Error(`Not a WAV file: ${file}`);
  let format = null;
  let data = null;
  for (let offset = 12; offset + 8 <= buf.length; ) {
    const id = buf.toString('ascii', offset, offset + 4);
    const size = buf.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === 'fmt ') {
      let tag = buf.readUInt16LE(body);
      if (tag === 0xfffe) tag = buf.readUInt16LE(body + 24); // WAVE_FORMAT_EXTENSIBLE sub-format
      format = { tag, channels: buf.readUInt16LE(body + 2), sampleRate: buf.readUInt32LE(body + 4), bits: buf.readUInt16LE(body + 14) };
    } else if (id === 'data') {
      data = buf.subarray(body, Math.min(buf.length, body + size));
    }
    offset = body + size + (size & 1);
  }
  if (!format || !data) throw new Error(`Missing fmt or data chunk: ${file}`);
  const { tag, channels, sampleRate, bits } = format;
  const bytes = bits / 8;
  const frames = Math.floor(data.length / (bytes * channels));
  const read = tag === 3 && bits === 32 ? (o) => data.readFloatLE(o)
    : tag === 1 && bits === 16 ? (o) => data.readInt16LE(o) / 32768
    : tag === 1 && bits === 24 ? (o) => data.readIntLE(o, 3) / 8388608
    : tag === 1 && bits === 32 ? (o) => data.readInt32LE(o) / 2147483648
    : null;
  if (!read) throw new Error(`Unsupported WAV format (tag ${tag}, ${bits}-bit): ${file}`);
  const samples = Array.from({ length: channels }, () => new Float32Array(frames));
  for (let i = 0; i < frames; i++) {
    for (let c = 0; c < channels; c++) samples[c][i] = read((i * channels + c) * bytes);
  }
  return { sampleRate, samples, frames };
}

/// Writes 32-bit float WAV (no requantisation before the encoder).
function writeFloatWav(file, sampleRate, samples) {
  const channels = samples.length;
  const frames = samples[0].length;
  const dataSize = frames * channels * 4;
  const buf = Buffer.alloc(44 + dataSize);
  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + dataSize, 4);
  buf.write('WAVE', 8, 'ascii');
  buf.write('fmt ', 12, 'ascii');
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(3, 20);
  buf.writeUInt16LE(channels, 22);
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(sampleRate * channels * 4, 28);
  buf.writeUInt16LE(channels * 4, 32);
  buf.writeUInt16LE(32, 34);
  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(dataSize, 40);
  const interleaved = new Float32Array(buf.buffer, buf.byteOffset + 44, frames * channels);
  for (let i = 0; i < frames; i++) {
    for (let c = 0; c < channels; c++) interleaved[i * channels + c] = samples[c][i];
  }
  fs.writeFileSync(file, buf);
}

/// Correlation-compensated equal-power crossfade (Bristow-Johnson): gains
/// g_in = e + o and g_out = e - o keep the power constant for two signals
/// with correlation rho, from equal power (rho = 0) to equal gain (rho = 1).
/// Returns [gOut, gIn] for fade position t in (0, 1].
function crossfadeGains(t, rho) {
  const u = 2 * t - 1;
  const o = 0.5 * Math.sin((Math.PI / 2) * u);
  const e = Math.sqrt((0.5 - o * o * (1 - rho)) / (1 + rho));
  return [e - o, e + o];
}

/// The audio [0, loopEnd) with its last `crossfadeFrames` faded into the
/// frames just before loopStart, followed by the audio from loopStart for
/// TAIL_FRAMES, so the encoder codes the seam as it is heard instead of as
/// the end of a stream (which smears the last AAC frame). The player never
/// plays past loopEnd.
function cutLoop(samples, loop) {
  const { loopStart, loopEnd, crossfadeFrames: fade } = loop;
  const rho = Math.min(1, Math.max(0, loop.crossfadeCorrelation));
  return samples.map((channel) => {
    const out = new Float32Array(loopEnd + TAIL_FRAMES);
    out.set(channel.subarray(0, loopEnd));
    for (let i = 0; i < fade; i++) {
      const [gOut, gIn] = crossfadeGains((i + 1) / fade, rho);
      out[loopEnd - fade + i] = gOut * channel[loopEnd - fade + i] + gIn * channel[loopStart - fade + i];
    }
    out.set(channel.subarray(loopStart, loopStart + TAIL_FRAMES), loopEnd);
    return out;
  });
}

/// Whether a loop found for a master still fits it.
function loopProblem(master, loop, frames, sampleRate) {
  if (!loop) return `No loop for "${master}"; run music.js loops`;
  if (frames !== loop.masterFrames || sampleRate !== loop.sampleRate) {
    return `"${master}" changed since its loop was found (${frames} frames at ${sampleRate} Hz); run music.js loops`;
  }
  if (!(loop.crossfadeFrames < loop.loopStart && loop.loopStart + TAIL_FRAMES < loop.loopEnd && loop.loopEnd <= frames)) {
    return `Bad loop points for "${master}"`;
  }
  return null;
}

/// The Swift file that hands the loop points to `AudioConfiguration.musicLoops`.
function swiftSource(entries) {
  const lines = entries.map(({ resource, loop }) => `        "${resource}": MusicLoop(start: ${loop.loopStart}, end: ${loop.loopEnd}),`);
  return `// Generated by the runtime's Tools/Audio/music.js (export); do not edit.
import PlatformAudio

/// Where each soundtrack file repeats, in frames at its sample rate, for
/// \`AudioConfiguration.musicLoops\`. A track plays from its first frame once,
/// then repeats \`start..<end\`. The frames before \`end\` already crossfade
/// into the frames before \`start\`, and the file runs on past \`end\` only so
/// the encoder codes the seam cleanly; playback never reaches that tail.
enum MusicLoops {
    static let all: [String: MusicLoop] = [
${lines.join('\n')}
    ]
}
`;
}

module.exports = {
  MASTER_EXTENSIONS,
  TAIL_FRAMES,
  readSettings,
  buildMedley,
  masterFile,
  isLfsPointer,
  readWav,
  writeFloatWav,
  crossfadeGains,
  cutLoop,
  loopProblem,
  swiftSource,
};
