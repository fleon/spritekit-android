'use strict';
// Compresses the runtime's packed pages to ASTC, with their mip levels, into
// KTX 1.1 files the shell uploads as they are (GLESRenderer's
// CompressedPage, GLDevice.createTexture(compressed:)).
//
// Arm's astcenc does the encoding (build it once with build-astcenc.sh in
// this folder). A page goes in straight RGBA8, top row first, as a PNG
// decodes, and comes out the way the renderer wants it on the GPU:
//
//   premultiplied  SpriteKit's textures are, and the renderer blends
//                  ONE, ONE_MINUS_SRC_ALPHA; compressing premultiplied
//                  colour also keeps a transparent texel's colour from
//                  costing the block anything.
//   bottom first   GL takes a texture's first row as its bottom, so each
//                  level is turned over before it's encoded: the blocks
//                  then upload with no flip (the PNG path flips as it
//                  decodes, `Premultiply.rgbaFlipped`).
//   mip levels     each half the last (rounded down), averaged by area in
//                  premultiplied colour, as glGenerateMipmap would.
//
// The block size is chosen per page: atlas pages hold everything from the
// interface's pieces to painted kits, so they take 4×4 (8 bits a texel,
// the format's best); a whole page takes the biggest block whose decode
// stays within QUALITY of the painting, trying 8×8, 6×6, then 5×5, and
// falls back to 4×4. Everything is deterministic: the same page gives the
// same bytes on every run.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ENCODER = path.join(__dirname, 'out', 'astcenc');

/// GL's internal format for each block size (KHR_texture_compression_astc_ldr).
const FORMATS = {
  '4x4': 0x93b0, '5x4': 0x93b1, '5x5': 0x93b2, '6x5': 0x93b3, '6x6': 0x93b4, '8x5': 0x93b5,
  '8x6': 0x93b6, '8x8': 0x93b7, '10x5': 0x93b8, '10x6': 0x93b9, '10x8': 0x93ba, '10x10': 0x93bb,
  '12x10': 0x93bc, '12x12': 0x93bd,
};

/// What "looks as painted" means for a whole page, measured over every
/// texel either image covers (both fully transparent are skipped), all four
/// premultiplied channels: a PSNR of at least `psnr` dB, and no more than
/// `outliers` channel values in 10,000 more than `outlier` levels off.
const QUALITY = { psnr: 46, outlier: 24, outliers: 0.1 };
const CANDIDATES = ['8x8', '6x6', '5x5'];
const FALLBACK = '4x4';

function encoder() {
  if (!fs.existsSync(ENCODER)) {
    throw new Error(`No ASTC encoder at ${ENCODER}: run Tools/Art/ASTC/build-astcenc.sh`);
  }
  return ENCODER;
}

/// Premultiplied, rows turned over: what a level is encoded from.
function prepare({ width, height, data }) {
  const out = new Uint8Array(width * height * 4);
  const stride = width * 4;
  for (let row = 0; row < height; row++) {
    const from = row * stride, to = (height - 1 - row) * stride;
    for (let i = 0; i < stride; i += 4) {
      const a = data[from + i + 3];
      if (a === 255) {
        out[to + i] = data[from + i];
        out[to + i + 1] = data[from + i + 1];
        out[to + i + 2] = data[from + i + 2];
      } else {
        // As Premultiply.rgba rounds.
        out[to + i] = Math.floor((data[from + i] * a + 127) / 255);
        out[to + i + 1] = Math.floor((data[from + i + 1] * a + 127) / 255);
        out[to + i + 2] = Math.floor((data[from + i + 2] * a + 127) / 255);
      }
      out[to + i + 3] = a;
    }
  }
  return { width, height, data: out };
}

/// Half the level each way (rounded down, at least 1), each texel the mean
/// of the area of the level above it covers.
function halve({ width, height, data }) {
  const w = Math.max(1, width >> 1), h = Math.max(1, height >> 1);
  const across = spans(width, w), down = spans(height, h);
  const rows = new Float32Array(w * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < w; x++) {
      const acc = [0, 0, 0, 0];
      for (const [from, weight] of across[x]) {
        const at = (y * width + from) * 4;
        for (let c = 0; c < 4; c++) acc[c] += data[at + c] * weight;
      }
      for (let c = 0; c < 4; c++) rows[(y * w + x) * 4 + c] = acc[c];
    }
  }
  const out = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const acc = [0, 0, 0, 0];
      for (const [from, weight] of down[y]) {
        const at = (from * w + x) * 4;
        for (let c = 0; c < 4; c++) acc[c] += rows[at + c] * weight;
      }
      for (let c = 0; c < 4; c++) out[(y * w + x) * 4 + c] = Math.min(255, Math.round(acc[c]));
    }
  }
  return { width: w, height: h, data: out };
}

/// For each of `to` texels, the texels of `from` it covers and how much of each.
function spans(from, to) {
  const ratio = from / to;
  return Array.from({ length: to }, (_, i) => {
    const start = i * ratio, end = (i + 1) * ratio;
    const cover = [];
    for (let j = Math.floor(start); j < Math.ceil(end); j++) {
      const share = Math.min(end, j + 1) - Math.max(start, j);
      if (share > 1e-9) cover.push([j, share / ratio]);
    }
    return cover;
  });
}

/// The levels from `image` down: `count` of them, or (with no count) every
/// one whose shorter side is at least `floor` px.
function mipChain(image, { count, floor = 16 } = {}) {
  const levels = [image];
  for (;;) {
    const last = levels[levels.length - 1];
    if (count !== undefined ? levels.length >= count : Math.min(last.width >> 1, last.height >> 1) < floor) break;
    if (last.width === 1 && last.height === 1) break;
    levels.push(halve(last));
  }
  return levels;
}

/// One level's ASTC blocks (no header), and the PNG `astcenc -dl` decoded
/// them to when `decodeTo` is given.
function encodeLevel(level, block, { png, work, decodeTo }) {
  const input = path.join(work, 'level.png');
  const output = path.join(work, 'level.astc');
  fs.writeFileSync(input, png.encode(level, { level: 1 }));
  execFileSync(encoder(), ['-cl', input, output, block, '-thorough', '-silent'], { stdio: ['ignore', 'ignore', 'inherit'] });
  if (decodeTo) execFileSync(encoder(), ['-dl', output, decodeTo, '-silent'], { stdio: ['ignore', 'ignore', 'inherit'] });
  const file = fs.readFileSync(output);
  return file.subarray(16);
}

/// How far `decoded` strays from `original` (both premultiplied RGBA8).
function measure(original, decoded) {
  let sum = 0, count = 0, outliers = 0, worst = 0;
  const a = original.data, b = decoded.data;
  for (let p = 0; p < a.length; p += 4) {
    if (a[p + 3] === 0 && b[p + 3] === 0) continue;
    for (let c = 0; c < 4; c++) {
      const e = Math.abs(a[p + c] - b[p + c]);
      sum += e * e;
      if (e > worst) worst = e;
      if (e > QUALITY.outlier) outliers++;
      count++;
    }
  }
  const mse = count ? sum / count : 0;
  return {
    psnr: mse === 0 ? 99 : +(10 * Math.log10((255 * 255) / mse)).toFixed(2),
    worst,
    outliers: count ? +((outliers / count) * 1e4).toFixed(3) : 0,
  };
}

const passes = (m) => m.psnr >= QUALITY.psnr && m.outliers <= QUALITY.outliers;

/// A KTX 1.1 file: ASTC levels, level 0 first.
function ktx(format, width, height, levels) {
  const header = Buffer.alloc(64);
  Buffer.from([0xab, 0x4b, 0x54, 0x58, 0x20, 0x31, 0x31, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a]).copy(header, 0);
  const fields = [0x04030201, 0, 1, 0, format, 0x1908, width, height, 0, 0, 1, levels.length, 0];
  fields.forEach((value, i) => header.writeUInt32LE(value, 12 + i * 4));
  const parts = [header];
  for (const level of levels) {
    const size = Buffer.alloc(4);
    size.writeUInt32LE(level.length, 0);
    parts.push(size, level);
  }
  return Buffer.concat(parts);
}

/// Compresses one page. `image` is straight RGBA8, top row first.
/// `block` is a block size ('4x4'…) or 'auto'; `levels` a count of mip
/// levels, or undefined for every level down to `floor` px.
/// Returns { file: the KTX bytes, block, levels, quality: level 0's measure }.
function compress(image, { block = 'auto', levels, floor, png }) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'xcassets-art-astc-'));
  try {
    const chain = mipChain(prepare(image), { count: levels, floor });
    const decoded = path.join(work, 'decoded.png');
    let chosen = block, first = null, quality = null;
    const tried = block === 'auto' ? [...CANDIDATES, FALLBACK] : [block];
    for (const candidate of tried) {
      const blocks = encodeLevel(chain[0], candidate, { png, work, decodeTo: decoded });
      const measured = measure(chain[0], png.decode(fs.readFileSync(decoded), decoded));
      chosen = candidate;
      first = blocks;
      quality = measured;
      if (block !== 'auto' || passes(measured)) break;
    }
    const encoded = [first, ...chain.slice(1).map((level) => encodeLevel(level, chosen, { png, work }))];
    const [bw, bh] = chosen.split('x').map(Number);
    return {
      file: ktx(FORMATS[chosen], image.width, image.height, encoded),
      block: [bw, bh],
      levels: encoded.length,
      quality,
    };
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

/// The levels a KTX file holds, for checks: { format, width, height, levels: [Buffer] }.
function readKTX(file) {
  const field = (i) => file.readUInt32LE(12 + i * 4);
  const count = field(11);
  const levels = [];
  let at = 64 + field(12);
  for (let i = 0; i < count; i++) {
    const size = file.readUInt32LE(at);
    levels.push(file.subarray(at + 4, at + 4 + size));
    at += 4 + size + ((4 - (size % 4)) % 4);
  }
  return { format: field(4), width: field(6), height: field(7), levels };
}

module.exports = { compress, prepare, halve, mipChain, measure, ktx, readKTX, encoder, FORMATS, QUALITY, ENCODER };
