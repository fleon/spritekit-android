'use strict';
// Packs Apple asset catalogs (`Assets.xcassets`) straight into the runtime's
// art: texture atlases plus one `index.json`, the format
// Sources/SpriteKitShim/AssetIndex.swift reads.
//
//   node Tools/guard.js 12 -- node Tools/Art/xcassets-art.js <outDir> <Assets.xcassets> [<more.xcassets> ...] [--png]
//
// Several catalogs pack into one index (a game's own art and, say, its SF
// Symbols pre-rendered into a second catalog); an image name two catalogs
// share is an error. `--png` writes every page as a PNG instead of ASTC,
// which needs no encoder and is quick; without it, a checkout with no
// encoder builds one first (Tools/Art/ASTC/build-astcenc.sh).
//
// What it reads, as Xcode does:
//
//   names        Every `*.imageset` at any depth is an asset named after the
//                set, prefixed with "Folder/" for each enclosing folder whose
//                Contents.json says `provides-namespace` (so
//                SystemSymbols/clock.fill.imageset is "SystemSymbols/clock.fill").
//   pixels       Each set's highest-scale PNG (3x, 2x, 1x, then a
//                single-scale image as 1x), preferring universal, then
//                iPhone, then iPad renditions, and leaving out dark-mode and
//                other appearance, size-class and P3 variants. The asset's
//                size in points is its pixels over that scale, as
//                `SKTexture(imageNamed:).size()` reports on Apple.
//   slicing      An image's `resizing` (Xcode's Slicing inspector): its
//                `cap-insets` are pixels, and become the index's `caps` in
//                points. Like actool, the pixels between the end of the
//                `center` and the far cap are cut out, so the packed image
//                and its size are the ones the app gets on Apple.
//   skipped      Vector images (PDF, SVG), JPEGs, interlaced PNGs and sets
//                with no image are reported and left out; colour sets, app
//                icons, data sets and the other kinds of set are reported and
//                ignored.
//
// What it writes:
//
//   pages        Images whose longest side is over STANDALONE px get a page
//                to themselves (`repeats`), so a tiling ground stays a whole
//                texture that can be sampled with GL_REPEAT. Everything else
//                is packed into PAGE×PAGE pages, the size GLES 3.0
//                guarantees, by a bottom-left skyline over a total order on
//                name and size: the same catalogs always give the same pages
//                at the same rects, byte for byte.
//   gutter       Each packed image sits in a cell of its own, GUTTER px round
//                it and ALIGN-px aligned, its edge pixels extruded over the
//                rest of the cell, so linear filtering, 9-slice stretching,
//                an ASTC block and a mip level's texel never pull in a
//                neighbour.
//   ASTC         Pages ship as KTX files of ASTC blocks with mip levels
//                (ASTC/compress.js): atlas pages 4×4 and ATLAS_LEVELS levels,
//                whole pages the biggest block that keeps them looking as
//                painted and every level down to MIP_FLOOR px.
//
// Memory stays small: one decoded image and one page at a time, 8-bit RGBA
// in Uint8Arrays. Run it under Tools/guard.js all the same.

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const astc = require('./ASTC/compress');

const PAGE = 2048;
// A cell's gutter and alignment: one texel of the smallest atlas mip level
// (ATLAS_LEVELS 3: 2048, 1024, 512 px, so 4 px), and the 4×4 ASTC block.
const GUTTER = 4;
const ALIGN = 4;
const STANDALONE = 512;
const INDEX_VERSION = 2;
const ATLAS_LEVELS = 3;
const MIP_FLOOR = 16;
// Whole pages wider or taller than this are packed but warned about: GLES
// guarantees 2048, and GPUs reporting a GL_MAX_TEXTURE_SIZE of 4096 exist.
const LARGE = 4096;

// ── PNG ──────────────────────────────────────────────────────────────────
// A small reader and writer. Reads every non-interlaced PNG (grey, RGB,
// palette, grey+alpha, RGBA; 1 to 16 bits, tRNS honoured) to straight 8-bit
// RGBA; writes 8-bit RGBA.

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const CHANNELS = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };
const DEPTHS = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };

/// The IHDR's fields, without decoding the pixels.
function readHeader(file) {
  const head = Buffer.alloc(29);
  const fd = fs.openSync(file, 'r');
  try {
    if (fs.readSync(fd, head, 0, 29, 0) !== 29) throw new Error(`${file}: too short for a PNG`);
  } finally {
    fs.closeSync(fd);
  }
  if (!head.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error(`${file}: not a PNG`);
  return {
    width: head.readUInt32BE(16), height: head.readUInt32BE(20),
    depth: head[24], colour: head[25], interlace: head[28],
  };
}

const paeth = (a, b, c) => {
  const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
};

/// Decodes a PNG to straight (non-premultiplied) 8-bit RGBA.
function decode(buffer, label = 'image') {
  if (!buffer.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error(`${label}: not a PNG`);
  let header = null, palette = null, trns = null;
  const parts = [];
  for (let at = 8; at + 8 <= buffer.length;) {
    const length = buffer.readUInt32BE(at);
    const type = buffer.toString('ascii', at + 4, at + 8);
    const body = buffer.subarray(at + 8, at + 8 + length);
    if (type === 'IHDR') {
      header = { width: body.readUInt32BE(0), height: body.readUInt32BE(4), depth: body[8], colour: body[9], interlace: body[12] };
    } else if (type === 'PLTE') {
      palette = body;
    } else if (type === 'tRNS') {
      trns = body;
    } else if (type === 'IDAT') {
      parts.push(body);
    } else if (type === 'IEND') {
      break;
    }
    at += length + 12;
  }
  if (!header) throw new Error(`${label}: no IHDR`);
  const { width, height, depth, colour, interlace } = header;
  const channels = CHANNELS[colour];
  if (!channels || !DEPTHS[colour].includes(depth)) throw new Error(`${label}: colour type ${colour} at ${depth} bits is not a PNG format`);
  if (interlace !== 0) throw new Error(`${label}: interlaced, only non-interlaced is read`);
  if (colour === 3 && !palette) throw new Error(`${label}: palette image with no PLTE`);

  const raw = zlib.inflateSync(Buffer.concat(parts));
  const stride = Math.ceil((width * channels * depth) / 8);
  const bpp = Math.max(1, (channels * depth) >> 3);
  if (raw.length < (stride + 1) * height) throw new Error(`${label}: truncated pixel data`);
  const lines = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const src = y * (stride + 1) + 1, dst = y * stride, up = dst - stride;
    for (let i = 0; i < stride; i++) {
      const x = raw[src + i];
      const a = i >= bpp ? lines[dst + i - bpp] : 0;
      const b = y > 0 ? lines[up + i] : 0;
      const c = y > 0 && i >= bpp ? lines[up + i - bpp] : 0;
      let value;
      switch (filter) {
        case 0: value = x; break;
        case 1: value = x + a; break;
        case 2: value = x + b; break;
        case 3: value = x + ((a + b) >> 1); break;
        case 4: value = x + paeth(a, b, c); break;
        default: throw new Error(`${label}: row ${y} has filter ${filter}`);
      }
      lines[dst + i] = value & 0xff;
    }
  }

  const rgba = new Uint8Array(width * height * 4);
  if (depth === 8 && colour === 6) {
    rgba.set(lines.subarray(0, rgba.length));
    return { width, height, data: rgba };
  }
  // A sample at its own depth, and that sample as 8 bits.
  const max = (1 << depth) - 1;
  const sample = (y, x, c) => {
    const row = y * stride;
    if (depth === 16) return lines.readUInt16BE(row + (x * channels + c) * 2);
    if (depth === 8) return lines[row + x * channels + c];
    const bit = x * depth;
    return (lines[row + (bit >> 3)] >> (8 - depth - (bit & 7))) & max;
  };
  const eight = (v) => (depth === 16 ? v >> 8 : depth === 8 ? v : Math.round((v * 255) / max));
  const key = trns && (colour === 0 || colour === 2)
    ? Array.from({ length: colour === 0 ? 1 : 3 }, (_, i) => trns.readUInt16BE(i * 2)) : null;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const d = (y * width + x) * 4;
      if (colour === 3) {
        const i = sample(y, x, 0);
        rgba[d] = palette[i * 3]; rgba[d + 1] = palette[i * 3 + 1]; rgba[d + 2] = palette[i * 3 + 2];
        rgba[d + 3] = trns && i < trns.length ? trns[i] : 255;
        continue;
      }
      const s = [];
      for (let c = 0; c < channels; c++) s.push(sample(y, x, c));
      const grey = colour === 0 || colour === 4;
      rgba[d] = eight(s[0]);
      rgba[d + 1] = eight(grey ? s[0] : s[1]);
      rgba[d + 2] = eight(grey ? s[0] : s[2]);
      if (colour === 4) rgba[d + 3] = eight(s[1]);
      else if (colour === 6) rgba[d + 3] = eight(s[3]);
      else rgba[d + 3] = key && key.every((k, i) => k === s[i]) ? 0 : 255;
    }
  }
  return { width, height, data: rgba };
}

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function chunk(type, body) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(body.length, 0);
  head.write(type, 4, 'ascii');
  let crc = 0xffffffff;
  for (const byte of head.subarray(4)) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  for (const byte of body) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  const tail = Buffer.alloc(4);
  tail.writeUInt32BE((crc ^ 0xffffffff) >>> 0, 0);
  return Buffer.concat([head, body, tail]);
}

/// Encodes straight 8-bit RGBA, picking each row's filter by the usual sum
/// of absolute differences. Deterministic: zlib at a fixed level.
function encode({ width, height, data }, { level = 9 } = {}) {
  const stride = width * 4;
  const rows = Buffer.alloc((stride + 1) * height);
  const candidates = [Buffer.alloc(stride), Buffer.alloc(stride), Buffer.alloc(stride), Buffer.alloc(stride), Buffer.alloc(stride)];
  for (let y = 0; y < height; y++) {
    const src = y * stride, up = src - stride;
    const scores = [0, 0, 0, 0, 0];
    for (let i = 0; i < stride; i++) {
      const x = data[src + i];
      const a = i >= 4 ? data[src + i - 4] : 0;
      const b = y > 0 ? data[up + i] : 0;
      const c = y > 0 && i >= 4 ? data[up + i - 4] : 0;
      const values = [x, (x - a) & 0xff, (x - b) & 0xff, (x - ((a + b) >> 1)) & 0xff, (x - paeth(a, b, c)) & 0xff];
      for (let f = 0; f < 5; f++) {
        candidates[f][i] = values[f];
        scores[f] += values[f] < 128 ? values[f] : 256 - values[f];
      }
    }
    let best = 0;
    for (let f = 1; f < 5; f++) if (scores[f] < scores[best]) best = f;
    rows[y * (stride + 1)] = best;
    candidates[best].copy(rows, y * (stride + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    PNG_SIGNATURE,
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(rows, { level })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ── The catalog ──────────────────────────────────────────────────────────

const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
const IDIOMS = ['universal', 'iphone', 'ipad'];
// Kinds of set that hold no image this packs, reported and left alone.
const OTHER_SETS = /\.(appiconset|colorset|dataset|symbolset|imagestack|brandassets|launchimage|textureset|cubetextureset|mipmapset|arimageset|arresourcegroup|complicationset|iconset|stickerpack|stickersequence|sticker|gcdashboardimage|gcleaderboard|gcleaderboardset|solidimagestack)$/;

function readContents(dir) {
  const file = path.join(dir, 'Contents.json');
  if (!fs.existsSync(file)) return {};
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`${file}: ${error.message}`);
  }
}

/// The rendition a set ships to a phone: the plain variants (no dark mode,
/// size class, P3, right-to-left…) when it has any, by idiom (universal,
/// iPhone, iPad, then the rest), then by scale, highest first.
function renditions(images) {
  const withFile = images.filter((image) => image.filename);
  const plain = withFile.filter((image) => !image.appearances && !image['width-class'] && !image['height-class']
    && !image.memory && !image['graphics-feature-set'] && !image.subtype
    && (!image['display-gamut'] || image['display-gamut'] === 'sRGB')
    && (!image['language-direction'] || image['language-direction'] === 'left-to-right'));
  const idiom = (image) => {
    const at = IDIOMS.indexOf(image.idiom ?? 'universal');
    return at < 0 ? IDIOMS.length : at;
  };
  const scale = (image) => (image.scale ? parseFloat(image.scale) || 1 : 1);
  return (plain.length ? plain : withFile)
    .map((image) => ({ image, scale: scale(image) }))
    .sort((a, b) => idiom(a.image) - idiom(b.image) || b.scale - a.scale
      || (a.image.filename < b.image.filename ? -1 : a.image.filename > b.image.filename ? 1 : 0));
}

/// The spans of pixels an axis keeps once Xcode's slicing has cut out the
/// part between the end of the centre and the far cap, as actool does.
function keep(size, near, far, centre) {
  if (!(centre > 0) || near + centre >= size - far) return [[0, size]];
  return [[0, near + centre], [size - far, size]];
}

/// The caps (points) and the cut (pixel spans each way) an image's
/// `resizing` gives, or null when it is not sliced.
function slicing(resizing, width, height, scale) {
  if (!resizing || !resizing['cap-insets']) return null;
  const mode = resizing.mode ?? '9-part';
  const across = mode !== '3-part-vertical', down = mode !== '3-part-horizontal';
  const inset = resizing['cap-insets'];
  const clampTo = (v, size) => Math.max(0, Math.min(size, Number(v) || 0));
  const top = down ? clampTo(inset.top, height) : 0, bottom = down ? clampTo(inset.bottom, height) : 0;
  const left = across ? clampTo(inset.left, width) : 0, right = across ? clampTo(inset.right, width) : 0;
  if (!top && !bottom && !left && !right) return null;
  const centre = resizing.center ?? {};
  const cols = across ? keep(width, left, right, Number(centre.width)) : [[0, width]];
  const rows = down ? keep(height, top, bottom, Number(centre.height)) : [[0, height]];
  return {
    caps: [top / scale, left / scale, bottom / scale, right / scale],
    cut: cols.length > 1 || rows.length > 1 ? { cols, rows } : null,
    tiles: centre.mode === 'tile',
  };
}

const spanned = (spans) => spans.reduce((sum, [from, to]) => sum + to - from, 0);

/// Every image set in `catalogs`, by asset name, and what was left out.
///
/// Returns `{ assets: [{ name, file, scale, width, height, caps, cut, copy }], skipped: [{ name, reason }],
/// ignored: { kind: [path] }, notes: [string] }`. `width` and `height` are
/// the packed pixels (after any cut); `copy` says the file may be written
/// out byte for byte as a whole page.
function collect(catalogs) {
  const assets = new Map(), skipped = [], ignored = {}, notes = [];
  for (const catalog of catalogs) {
    if (!fs.statSync(catalog).isDirectory()) throw new Error(`${catalog} is not a directory`);
    (function walk(dir, prefix) {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort(byName)) {
        if (!entry.isDirectory()) continue;
        const here = path.join(dir, entry.name);
        const where = path.relative(path.dirname(catalog), here);
        const other = entry.name.match(OTHER_SETS);
        if (other) {
          (ignored[other[1]] ??= []).push(where);
          continue;
        }
        if (!entry.name.endsWith('.imageset')) {
          const namespaced = readContents(here).properties?.['provides-namespace'] === true;
          walk(here, namespaced ? `${prefix}${entry.name}/` : prefix);
          continue;
        }
        const name = prefix + entry.name.slice(0, -'.imageset'.length);
        if (assets.has(name)) {
          throw new Error(`Two image sets are called ${name}: ${assets.get(name).where} and ${where}`);
        }
        const options = renditions(readContents(here).images ?? []);
        const found = options.find(({ image }) => /\.png$/i.test(image.filename) && fs.existsSync(path.join(here, image.filename)));
        if (!found) {
          const kinds = [...new Set(options.map(({ image }) => path.extname(image.filename).slice(1).toLowerCase() || 'no extension'))];
          const missing = options.length && options.every(({ image }) => !fs.existsSync(path.join(here, image.filename)));
          skipped.push({ name, reason: !options.length ? 'no image' : missing ? 'image file missing' : `${kinds.join(', ')}, not PNG` });
          continue;
        }
        const file = path.join(here, found.image.filename);
        const header = readHeader(file);
        if (header.interlace) {
          skipped.push({ name, reason: 'interlaced PNG' });
          continue;
        }
        const slice = slicing(found.image.resizing, header.width, header.height, found.scale);
        if (slice?.tiles) notes.push(`${name}: its centre tiles on Apple; SpriteKit's centerRect stretches it`);
        const width = slice?.cut ? spanned(slice.cut.cols) : header.width;
        const height = slice?.cut ? spanned(slice.cut.rows) : header.height;
        assets.set(name, {
          name, file, where, scale: found.scale, width, height,
          caps: slice?.caps ?? null,
          cut: slice?.cut ?? null,
          copy: !slice?.cut && header.depth === 8 && header.colour === 6,
        });
      }
    })(catalog, '');
  }
  return { assets: [...assets.values()].sort(byName), skipped, ignored, notes };
}

/// An asset's pixels as packed: decoded, with any slicing cut made.
function load(asset) {
  const image = decode(fs.readFileSync(asset.file), asset.file);
  if (!asset.cut) return image;
  const { cols, rows } = asset.cut;
  const out = new Uint8Array(asset.width * asset.height * 4);
  let y = 0;
  for (const [top, bottom] of rows) {
    for (let row = top; row < bottom; row++, y++) {
      let x = 0;
      for (const [left, right] of cols) {
        out.set(image.data.subarray((row * image.width + left) * 4, (row * image.width + right) * 4), (y * asset.width + x) * 4);
        x += right - left;
      }
    }
  }
  return { width: asset.width, height: asset.height, data: out };
}

// ── Packing ──────────────────────────────────────────────────────────────

/// Lays `entries` ({ name, width, height }) out over pages.
///
/// Pure and deterministic: the result depends only on the entries' names and
/// sizes. Images over `standalone` px take a page of their own at 1:1; the
/// rest go into `page`×`page` pages, tallest first, by a bottom-left
/// skyline. Each packed image takes a cell of its own: `gutter` px on every
/// side, rounded up to a multiple of `align` each way. The image sits
/// `gutter` in from its cell's left and bottom, so its left and bottom edges
/// fall on `align` boundaries whichever way up the page is read, and a
/// compressed page can be cut block for block.
///
/// Returns `{ pages: [{ width, height, solo, placed: [{ name, x, y, width, height, cell }] }] }`,
/// `solo` naming the one image a standalone page holds and `cell` being
/// `[x, y, width, height]`.
function pack(entries, { page = PAGE, gutter = GUTTER, standalone = STANDALONE, align = ALIGN } = {}) {
  const alone = [], packed = [];
  for (const entry of entries) {
    if (entry.width <= 0 || entry.height <= 0) throw new Error(`${entry.name}: ${entry.width}×${entry.height}`);
    (Math.max(entry.width, entry.height) > standalone ? alone : packed).push(entry);
  }
  if (page % align) throw new Error(`a ${page} page is not a multiple of the ${align} px alignment`);
  const round = (n) => Math.ceil(n / align) * align;
  for (const entry of packed) {
    if (round(entry.width + gutter * 2) > page || round(entry.height + gutter * 2) > page) {
      throw new Error(`${entry.name}: ${entry.width}×${entry.height} does not fit a ${page} page`);
    }
  }

  // Tallest first, then widest, then by name: a total order.
  packed.sort((a, b) => b.height - a.height || b.width - a.width || byName(a, b));

  const pages = [];
  const skylines = [];
  for (const entry of packed) {
    const width = round(entry.width + gutter * 2), height = round(entry.height + gutter * 2);
    let spot = null, index = -1;
    for (let i = 0; i < pages.length; i++) {
      spot = fit(skylines[i], page, width, height);
      if (spot) { index = i; break; }
    }
    if (!spot) {
      pages.push({ width: page, height: page, solo: null, placed: [] });
      skylines.push([{ x: 0, y: 0, width: page }]);
      index = pages.length - 1;
      spot = fit(skylines[index], page, width, height);
      if (!spot) throw new Error(`${entry.name}: ${entry.width}×${entry.height} found no room on an empty page`);
    }
    skylines[index] = settle(skylines[index], spot.x, spot.y, width, height);
    pages[index].placed.push({
      name: entry.name,
      x: spot.x + gutter,
      y: spot.y + height - gutter - entry.height,
      width: entry.width,
      height: entry.height,
      cell: [spot.x, spot.y, width, height],
    });
  }
  for (const made of pages) made.placed.sort((a, b) => a.y - b.y || a.x - b.x);

  for (const entry of [...alone].sort(byName)) {
    pages.push({
      width: entry.width,
      height: entry.height,
      solo: entry.name,
      placed: [{ name: entry.name, x: 0, y: 0, width: entry.width, height: entry.height }],
    });
  }
  return { pages };
}

/// The lowest, then leftmost, spot a `width`×`height` box fits the skyline.
function fit(skyline, page, width, height) {
  let best = null;
  for (let i = 0; i < skyline.length; i++) {
    const x = skyline[i].x;
    if (x + width > page) break;
    let y = 0, left = width;
    for (let j = i; left > 0; j++) {
      if (j >= skyline.length) { y = -1; break; }
      y = Math.max(y, skyline[j].y);
      left -= skyline[j].width;
    }
    if (y < 0 || y + height > page) continue;
    if (!best || y < best.y || (y === best.y && x < best.x)) best = { x, y };
  }
  return best;
}

/// The skyline with a `width`×`height` box resting at (x, y).
function settle(skyline, x, y, width, height) {
  const cut = [];
  for (const span of skyline) {
    const end = span.x + span.width;
    if (end <= x || span.x >= x + width) { cut.push(span); continue; }
    if (span.x < x) cut.push({ x: span.x, y: span.y, width: x - span.x });
    if (end > x + width) cut.push({ x: x + width, y: span.y, width: end - x - width });
  }
  cut.push({ x, y: y + height, width });
  cut.sort((a, b) => a.x - b.x);
  const merged = [];
  for (const span of cut) {
    const last = merged[merged.length - 1];
    if (last && last.y === span.y && last.x + last.width === span.x) last.width += span.width;
    else merged.push({ ...span });
  }
  return merged;
}

/// Draws `image` into `canvas` at (x, y) and extrudes its edge pixels over
/// the rest of `cell` ([x, y, width, height]), so a sample that strays past
/// the rect's edge finds the image's own colour rather than a neighbour's.
function blit(canvas, image, x, y, gutter, cell) {
  const [cx, cy, cw, ch] = cell;
  if (x - cx < gutter || y - cy < gutter || cx + cw - x - image.width < gutter || cy + ch - y - image.height < gutter
    || cx < 0 || cy < 0 || cx + cw > canvas.width || cy + ch > canvas.height) {
    throw new Error(`a ${image.width}×${image.height} image at ${x},${y} leaves no gutter on a ${canvas.width}×${canvas.height} page`);
  }
  const line = Buffer.alloc(cw * 4);
  for (let row = 0; row < ch; row++) {
    const src = Math.min(image.height - 1, Math.max(0, cy + row - y)) * image.width * 4;
    for (let col = 0; col < cw; col++) {
      const at = src + Math.min(image.width - 1, Math.max(0, cx + col - x)) * 4;
      line[col * 4] = image.data[at];
      line[col * 4 + 1] = image.data[at + 1];
      line[col * 4 + 2] = image.data[at + 2];
      line[col * 4 + 3] = image.data[at + 3];
    }
    canvas.data.set(line, ((cy + row) * canvas.width + cx) * 4);
  }
}

// ── The index ────────────────────────────────────────────────────────────

/// The scale most assets were taken at (the higher on a tie): the index's
/// one `scale`, which `UIImage(named:)` reports. Sizes are per asset, so an
/// asset at another scale still measures right; it also carries its own
/// `scale`, which the loader does not read.
function commonScale(assets) {
  const counts = new Map();
  for (const { scale } of assets) counts.set(scale, (counts.get(scale) ?? 0) + 1);
  return [...counts].sort((a, b) => b[1] - a[1] || b[0] - a[0])[0]?.[0] ?? 1;
}

function buildIndex({ pages, assets }) {
  const scale = commonScale(assets);
  const byAsset = new Map(assets.map((asset) => [asset.name, asset]));
  const entries = {};
  for (const [index, page] of pages.entries()) {
    for (const { name, x, y, width, height } of page.placed) {
      const asset = byAsset.get(name);
      entries[name] = {
        page: index,
        rect: [x, y, width, height],
        size: [width / asset.scale, height / asset.scale],
        ...(asset.caps ? { caps: asset.caps } : {}),
        ...(asset.scale !== scale ? { scale: asset.scale } : {}),
      };
    }
  }
  return {
    version: INDEX_VERSION,
    scale,
    note: 'Generated by Tools/Art/xcassets-art.js from an asset catalog; do not edit. '
      + 'rect is [x, y, width, height] in page pixels, top left origin; size is [width, height] in points; '
      + 'caps is [top, left, bottom, right] in points; an asset taken at another scale than the index\'s carries its own. '
      + 'A page with format astc is a KTX file of ASTC blocks of block [width, height] and its levels mip levels, '
      + 'premultiplied, bottom row first; quality is how its level 0 decodes against the art (PSNR in dB, worst channel error, '
      + 'channel values off by more than 24 in 10,000).',
    pages: pages.map((page, index) => ({
      file: pageFile(page, index),
      width: page.width,
      height: page.height,
      ...(page.solo ? { repeats: true } : {}),
      ...(page.compressed ? {
        format: 'astc',
        block: page.compressed.block,
        levels: page.compressed.levels,
        quality: page.compressed.quality,
      } : {}),
    })),
    assets: Object.fromEntries(Object.keys(entries).sort().map((name) => [name, entries[name]])),
  };
}

const pageFile = (page, index) => {
  const extension = page.compressed || page.astc ? 'ktx' : 'png';
  return page.solo ? `whole/${page.solo}.${extension}` : `atlas-${String(index).padStart(3, '0')}.${extension}`;
};

// ── Writing ──────────────────────────────────────────────────────────────

/// Clears `out` for a fresh pack, refusing anything that is not empty or a
/// previous pack, so a slip in the arguments can't take a catalog with it.
function clear(out, catalogs) {
  const resolved = path.resolve(out);
  for (const catalog of catalogs) {
    const from = path.resolve(catalog);
    if (resolved === from || from.startsWith(resolved + path.sep) || resolved.startsWith(from + path.sep)) {
      throw new Error(`${out} overlaps the catalog ${catalog}`);
    }
  }
  if (fs.existsSync(resolved)) {
    if (!fs.statSync(resolved).isDirectory()) throw new Error(`${out} is not a directory`);
    const inside = fs.readdirSync(resolved);
    if (inside.length && !inside.includes('index.json')) {
      throw new Error(`Won't clear ${out}: it is neither empty nor a previous pack (no index.json)`);
    }
  }
  fs.rmSync(resolved, { recursive: true, force: true });
  fs.mkdirSync(resolved, { recursive: true });
}

/// Packs `catalogs` into `out` and writes its index. `compress` (on unless
/// turned off) writes each page as ASTC with its mip levels; off, every page
/// is a PNG.
function write({ catalogs, out, compress = true, log = console.log }) {
  const { assets, skipped, ignored, notes } = collect(catalogs);
  if (!assets.length) throw new Error(`No PNG image sets under ${catalogs.join(', ')}`);
  if (compress) astc.encoder();
  const byAsset = new Map(assets.map((asset) => [asset.name, asset]));
  const { pages } = pack(assets);

  const files = pages.map((page, index) => pageFile({ ...page, astc: compress }, index).toLowerCase());
  const clash = files.find((file, i) => files.indexOf(file) !== i);
  if (clash) throw new Error(`Two whole pages would both be ${clash} on a case-insensitive disk`);

  clear(out, catalogs);
  const png = { encode, decode };
  let bytes = 0, rgba = 0;
  const started = Date.now();
  for (const [index, made] of pages.entries()) {
    let image = null;
    if (made.solo) {
      const asset = byAsset.get(made.solo);
      if (Math.max(made.width, made.height) > LARGE) log(`warning: ${made.solo} is ${made.width}×${made.height}, over ${LARGE} px`);
      if (!compress && asset.copy) {
        fs.mkdirSync(path.dirname(path.join(out, pageFile(made, index))), { recursive: true });
        fs.copyFileSync(asset.file, path.join(out, pageFile(made, index)));
      } else {
        image = load(asset);
      }
    } else {
      image = { width: made.width, height: made.height, data: new Uint8Array(made.width * made.height * 4) };
      for (const spot of made.placed) {
        const art = load(byAsset.get(spot.name));
        if (art.width !== spot.width || art.height !== spot.height) {
          throw new Error(`${spot.name}: ${art.width}×${art.height} on disk, ${spot.width}×${spot.height} packed`);
        }
        blit(image, art, spot.x, spot.y, GUTTER, spot.cell);
      }
    }
    if (image && compress) {
      const done = astc.compress(image, made.solo
        ? { block: 'auto', floor: MIP_FLOOR, png }
        : { block: '4x4', levels: ATLAS_LEVELS, png });
      made.compressed = { block: done.block, levels: done.levels, quality: done.quality };
      const file = path.join(out, pageFile(made, index));
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, done.file);
      log(`${made.solo ?? pageFile(made, index)}: ${done.block.join('x')} ×${done.levels} levels, ${done.quality.psnr} dB, worst ${done.quality.worst}`);
    } else if (image) {
      const file = path.join(out, pageFile(made, index));
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, encode(image));
    }
    bytes += fs.statSync(path.join(out, pageFile(made, index))).size;
    rgba += made.width * made.height * 4;
  }

  const index = buildIndex({ pages, assets });
  fs.writeFileSync(path.join(out, 'index.json'), `${JSON.stringify(index, null, 1)}\n`);

  for (const { name, reason } of skipped) log(`skipped ${name}: ${reason}`);
  for (const kind of Object.keys(ignored).sort()) log(`ignored ${ignored[kind].length} ${kind}: ${ignored[kind].join(', ')}`);
  for (const note of notes) log(`note: ${note}`);
  const atlases = pages.filter((p) => !p.solo).length;
  log(`${assets.length} assets at ${index.scale}x, ${atlases} atlas page${atlases === 1 ? '' : 's'} + ${pages.length - atlases} whole, `
    + `${(bytes / 1e6).toFixed(1)} MB of ${compress ? 'KTX' : 'PNG'} (${(rgba / 1e6).toFixed(0)} MB as RGBA8) `
    + `in ${Math.round((Date.now() - started) / 1000)} s → ${out}`);
  return { index, skipped, ignored, notes };
}

module.exports = {
  write, collect, pack, buildIndex, decode, encode, chunk, blit, load, readHeader, slicing, renditions,
  PAGE, GUTTER, ALIGN, STANDALONE, INDEX_VERSION, ATLAS_LEVELS, MIP_FLOOR,
};

if (require.main === module) {
  const args = process.argv.slice(2);
  const compress = !args.includes('--png');
  const [out, ...catalogs] = args.filter((arg) => arg !== '--png');
  if (!out || !catalogs.length || args.some((arg) => arg.startsWith('--') && arg !== '--png')) {
    console.error('Usage: node Tools/Art/xcassets-art.js <outDir> <Assets.xcassets> [<more.xcassets> ...] [--png]');
    process.exit(2);
  }
  try {
    write({ catalogs, out, compress });
  } catch (error) {
    console.error(`xcassets-art: ${error.message}`);
    process.exit(1);
  }
}
