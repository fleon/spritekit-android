'use strict';
// Contact sheets for reviewing a set of screenshots: a row a language, its
// screenshots side by side as the store shows them, every one as tall, so
// a set of mixed sizes lines up. Drawn with ffmpeg.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const SHEET_HEIGHT = 600;
const pngs = (dir) => fs.readdirSync(dir).filter((f) => f.endsWith('.png')).sort().map((f) => path.join(dir, f));

// One sheet of `rows` (each a list of PNGs) into `file` (a JPEG).
function sheet(rows, file, { height = SHEET_HEIGHT } = {}) {
  rows = rows.filter((files) => files.length);
  if (!rows.length) throw new Error(`nothing to put on ${file}`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const strips = rows.map((files, row) => {
    const strip = path.join(path.dirname(file), `.${path.basename(file, path.extname(file))}-${row}.png`);
    const inputs = files.flatMap((f) => ['-i', f]);
    const scaled = files.map((_, i) => `[${i}]scale=-2:${height},pad=iw+12:ih:0:0:white[s${i}]`).join(';');
    execFileSync('ffmpeg', ['-v', 'error', '-y', ...inputs, '-filter_complex', `${scaled};${files.map((_, i) => `[s${i}]`).join('')}hstack=inputs=${files.length}[o]`, '-map', '[o]', '-frames:v', '1', strip]);
    return strip;
  });
  const inputs = strips.flatMap((s) => ['-i', s]);
  const filter = strips.length > 1 ? `${strips.map((_, i) => `[${i}]pad=iw:ih+12:0:0:white[r${i}]`).join(';')};${strips.map((_, i) => `[r${i}]`).join('')}vstack=inputs=${strips.length}[o]` : '[0]copy[o]';
  execFileSync('ffmpeg', ['-v', 'error', '-y', ...inputs, '-filter_complex', filter, '-map', '[o]', '-frames:v', '1', '-q:v', '3', file]);
  for (const s of strips) fs.rmSync(s);
  return file;
}

// A sheet a set, for screenshots laid out as `<out>/<set>/<language>/*.png`:
// `<out>/review/<set>.jpg`, a row for each of `languages` the set has.
function contactSheets(out, sets, languages, options) {
  const written = [];
  for (const set of sets) {
    const rows = languages.filter((l) => fs.existsSync(path.join(out, set, l))).map((l) => pngs(path.join(out, set, l)));
    if (!rows.some((r) => r.length)) continue;
    written.push(sheet(rows, path.join(out, 'review', `${set}.jpg`), options));
  }
  return written;
}

// The rows of a folder of screenshots: its own PNGs as one row, or a row
// for each language folder in it (`<dir>/<language>/*.png`).
function rowsOf(dir) {
  const own = pngs(dir);
  if (own.length) return [own];
  return fs.readdirSync(dir).sort().map((d) => path.join(dir, d)).filter((d) => fs.statSync(d).isDirectory()).map(pngs).filter((r) => r.length);
}

module.exports = { SHEET_HEIGHT, sheet, contactSheets, rowsOf, pngs };
