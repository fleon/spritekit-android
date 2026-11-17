'use strict';
// Checks xcassets-art.js against the fixture catalogs in Fixtures/: that
// packing them again gives Fixtures/Packed byte for byte (the index
// Tests/SpriteKitShimTests/PackedArtTests.swift reads through AssetIndex),
// and what Xcode would make of them — names, scales, slicing, the cut.
//
//   node Tools/Art/check-xcassets-art.js            # check
//   node Tools/Art/check-xcassets-art.js --update   # rewrite Fixtures/Packed
//
// Pages are PNGs here (`--png`), so it needs no ASTC encoder.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const art = require('./xcassets-art');

const FIXTURES = path.join(__dirname, 'Fixtures');
const CATALOGS = ['Fixture.xcassets', 'Symbols.xcassets'].map((name) => path.join(FIXTURES, name));
const PACKED = path.join(FIXTURES, 'Packed');
const quiet = () => {};

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'xcassets-art-check-'));
let checks = 0;
const check = (label, body) => {
  body();
  checks++;
  console.log(`ok ${label}`);
};

try {
  const out = path.join(work, 'packed');
  const { index, skipped, ignored } = art.write({ catalogs: CATALOGS, out, compress: false, log: quiet });

  const files = (dir) => fs.readdirSync(dir, { recursive: true }).filter((f) => fs.statSync(path.join(dir, f)).isFile()).sort();
  if (process.argv.includes('--update')) {
    fs.rmSync(PACKED, { recursive: true, force: true });
    fs.cpSync(out, PACKED, { recursive: true });
    console.log(`updated ${PACKED}`);
  }
  check('the fixtures pack to Fixtures/Packed byte for byte', () => {
    assert.deepStrictEqual(files(out), files(PACKED));
    for (const file of files(out)) {
      assert.ok(fs.readFileSync(path.join(out, file)).equals(fs.readFileSync(path.join(PACKED, file))), `${file} differs`);
    }
  });

  check('names: namespaces prefix, dots stay, catalogs merge', () => {
    assert.deepStrictEqual(Object.keys(index.assets), ['Button', 'Icons/Star', 'Plain', 'SystemSymbols/clock.fill', 'Wide']);
  });

  check('skipped and ignored sets are reported', () => {
    assert.deepStrictEqual(skipped, [{ name: 'Logo', reason: 'pdf, not PNG' }]);
    assert.deepStrictEqual(ignored, { colorset: ['Fixture.xcassets/Accent.colorset'] });
  });

  const page = art.decode(fs.readFileSync(path.join(out, 'atlas-000.png')));
  const pixel = (x, y) => Array.from(page.data.subarray((y * page.width + x) * 4, (y * page.width + x) * 4 + 4));

  check('the highest scale is taken, dark mode left out, size in points', () => {
    const plain = index.assets.Plain;
    assert.deepStrictEqual(plain.size, [4, 3]);
    assert.deepStrictEqual(plain.rect.slice(2), [12, 9]);
    // Fixture pixels are [column, row, tag, 255]; @3x is tagged 30, its dark variant 40.
    assert.deepStrictEqual(pixel(plain.rect[0] + 5, plain.rect[1] + 2), [5, 2, 30, 255]);
    assert.strictEqual(index.scale, 3);
    assert.strictEqual(plain.scale, undefined);
    assert.deepStrictEqual(index.assets['Icons/Star'].size, [10, 10]);
    assert.strictEqual(index.assets['Icons/Star'].scale, 1);
  });

  check('slicing: cap insets become points and the cut matches actool', () => {
    // 30×20 @2x, caps top 4 left 6 bottom 6 right 8 px, a 2×2 centre: actool
    // keeps columns 0–7 and 22–29, rows 0–5 and 14–19.
    const button = index.assets.Button;
    assert.deepStrictEqual(button.caps, [2, 3, 3, 4]);
    assert.deepStrictEqual(button.size, [8, 6]);
    const [x, y, width, height] = button.rect;
    assert.deepStrictEqual([width, height], [16, 12]);
    const cols = [0, 1, 2, 3, 4, 5, 6, 7, 22, 23, 24, 25, 26, 27, 28, 29];
    const rows = [0, 1, 2, 3, 4, 5, 14, 15, 16, 17, 18, 19];
    for (const [j, row] of rows.entries()) {
      for (const [i, col] of cols.entries()) assert.deepStrictEqual(pixel(x + i, y + j), [col, row, 50, 255]);
    }
    // The gutter extrudes the edge.
    assert.deepStrictEqual(pixel(x - 1, y - 1), [0, 0, 50, 255]);
    assert.deepStrictEqual(pixel(x + width, y + height), [29, 19, 50, 255]);
  });

  check('a long image takes a whole page, written as the catalog has it', () => {
    const wide = index.assets.Wide;
    assert.deepStrictEqual(index.pages[wide.page], { file: 'whole/Wide.png', width: 600, height: 4, repeats: true });
    assert.deepStrictEqual(wide.size, [300, 2]);
    assert.ok(fs.readFileSync(path.join(out, 'whole/Wide.png'))
      .equals(fs.readFileSync(path.join(FIXTURES, 'Fixture.xcassets/Wide.imageset/wide@2x.png'))));
  });

  check('a name two catalogs share is an error naming both', () => {
    const symbols = CATALOGS[1];
    const copy = path.join(work, 'Again.xcassets');
    fs.cpSync(symbols, copy, { recursive: true });
    assert.throws(() => art.collect([symbols, copy]),
      /SystemSymbols\/clock\.fill: Symbols\.xcassets\/SystemSymbols\/clock\.fill\.imageset and Again\.xcassets\/SystemSymbols\/clock\.fill\.imageset/);
  });

  check('a directory that is neither empty nor a pack is not cleared', () => {
    const precious = path.join(work, 'precious');
    fs.mkdirSync(precious);
    fs.writeFileSync(path.join(precious, 'keep.txt'), 'keep');
    assert.throws(() => art.write({ catalogs: CATALOGS, out: precious, compress: false, log: quiet }), /Won't clear/);
    assert.ok(fs.existsSync(path.join(precious, 'keep.txt')));
  });

  check('palette, low-bit, 16-bit and tRNS PNGs decode to 8-bit RGBA', () => {
    const png = (width, height, depth, colour, rows, extra = []) => {
      const ihdr = Buffer.alloc(13);
      ihdr.writeUInt32BE(width, 0);
      ihdr.writeUInt32BE(height, 4);
      ihdr[8] = depth;
      ihdr[9] = colour;
      const raw = Buffer.concat(rows.map((row) => Buffer.from([0, ...row])));
      return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), art.chunk('IHDR', ihdr),
        ...extra, art.chunk('IDAT', zlib.deflateSync(raw)), art.chunk('IEND', Buffer.alloc(0))]);
    };
    // 2-bit palette, indices 0 1 2 3, index 1 half transparent.
    const palette = art.decode(png(4, 1, 2, 3, [[0b00011011]], [
      art.chunk('PLTE', Buffer.from([255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9])),
      art.chunk('tRNS', Buffer.from([255, 128])),
    ]));
    assert.deepStrictEqual(Array.from(palette.data), [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 9, 9, 9, 255]);
    // 16-bit grey and alpha.
    const grey = art.decode(png(1, 1, 16, 4, [[0x80, 0x01, 0xff, 0xfe]]));
    assert.deepStrictEqual(Array.from(grey.data), [128, 128, 128, 255]);
    // 8-bit RGB with a transparent colour key.
    const keyed = art.decode(png(2, 1, 8, 2, [[1, 2, 3, 4, 5, 6]], [art.chunk('tRNS', Buffer.from([0, 1, 0, 2, 0, 3]))]));
    assert.deepStrictEqual(Array.from(keyed.data), [1, 2, 3, 0, 4, 5, 6, 255]);
  });

  check('packing is a total order: shuffled input, same pages', () => {
    const entries = Array.from({ length: 40 }, (_, i) => ({ name: `E${i}`, width: 20 + ((i * 37) % 90), height: 10 + ((i * 53) % 70) }));
    const once = art.pack(entries);
    const again = art.pack([...entries].reverse());
    assert.deepStrictEqual(once, again);
  });

  console.log(`${checks} checks passed`);
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
