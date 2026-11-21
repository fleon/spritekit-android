#!/usr/bin/env node
'use strict';
// Google Play, driven from a game's repository: one tool for every game on
// this runtime. A game's Play directory holds listing.json (the source of
// truth for the listing), play.json (its settings, below) and a two-line
// play.js that runs this one with that directory. A plan is printed, and
// --send makes the changes. The Play API itself is spoken by `gplay`
// (github.com/PollyGlot/google-play-cli); this is the layer on top, with the
// house's flags and guards. README.md beside this file.
//
//   node <game Play dir>/play.js [step] [--send] [options]
//   node Tools/Play/play.js --dir <game Play dir> [step] [--send] [options]
//
// Steps (with none named: listing, images, product, datasafety, release
// when an artifact is given, tracks):
//   listing      the store listing in every language of listing.json
//   images       icon, feature graphic, TV banner and screenshots per
//                language, from Images/<locale>/ (else the default
//                language's), the game's renders (play.json) and
//                --screenshots <dir> (<dir>/<game language>/<n>.png)
//   screenshots  pulls the screenshots live on Play into the default
//                language's Images/, in Play's order (read-only on Play)
//   product      the managed product's localized copy (listing.json's
//                `product`, Monetization/iap/)
//   datasafety   the Data Safety declaration (Compliance/data-safety.csv)
//   release      an AAB (--aab) or APK (--apk) to --track (default
//                internal). A testing track takes only a beta build
//                (-P<game>.beta=true), production only a non-beta one, and
//                production only ever as a draft the user rolls out in the
//                Play Console. Testing tracks only: --rollout releases it
//                completed, --also <track,…> copies it to more testing
//                tracks (alpha is closed testing), and --send-for-review
//                sends the edit for review. --name names the release;
//                notes come from --notes <file> (cut to 500 characters at a
//                line), else --notes-dir, else ReleaseNotes/<track>/, else
//                ReleaseNotes/. --mapping <file> uploads an R8 mapping.
//   tracks       what each track serves, and its testers
//   versions     what Play has given out, read-only: every release on every
//                track, the version codes of every uploaded bundle and APK,
//                and the highest of them all; with --approved <version>,
//                the production release Google approved for that version
//                (one whose name names it: "1.5.0", "1002 (1.5.0)"). --json
//                prints it for scripts (exit 1 when Play can't be read):
//                { package, highest, releases: [{ track, name, status,
//                versionCodes }], uploaded: [codes], approved: { name,
//                status } | null }. The games' version tools and nightly
//                scripts read Play through this.
//   status       the live listing and images, then the tracks
//
//   --send             make the changes (without it, only plan them)
//   --offline          check the files only, without reading Play
//   --send-for-review  on a testing-track release only: with --send, send
//                      the edit for review instead of holding it (without
//                      --send the plan says it would)
//   --help, -h         print this and stop
//
// Nothing here submits for review but the nightly testing build: every
// other write passes --changes-not-sent-for-review, so it waits in the Play
// Console for the user. The nightly's release (--send-for-review) still
// passes --changes-in-review error, so it never cancels a review already
// under way.

const fs = require('fs');

if (process.argv.slice(2).some((a) => a === '--help' || a === '-h')) {
  const lines = fs.readFileSync(__filename, 'utf8').split('\n');
  const end = lines.findIndex((l, i) => i > 2 && !l.startsWith('//'));
  console.log(lines.slice(2, end).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}

const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const lib = require('./lib');

const args = process.argv.slice(2);
const option = (name, fallback = null) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };

// The game's Play directory: --dir, else the one its play.js names.
const HERE = path.resolve(option('--dir', process.env.PLAY_DIR ?? ''));
if (!process.env.PLAY_DIR && !option('--dir')) {
  console.error('Which game? Run its own play.js (Android/Play/play.js or Tools/Play/play.js), or pass --dir <its Play directory>.');
  process.exit(2);
}
if (!fs.existsSync(path.join(HERE, 'listing.json'))) {
  console.error(`No listing.json in ${HERE}.`);
  process.exit(2);
}
const SOURCE = JSON.parse(fs.readFileSync(path.join(HERE, 'listing.json'), 'utf8'));
const SETTINGS = fs.existsSync(path.join(HERE, 'play.json')) ? JSON.parse(fs.readFileSync(path.join(HERE, 'play.json'), 'utf8')) : {};
const PACKAGE = SOURCE.package;
const LISTINGS = SOURCE.listings ?? {};
const DEFAULT_LANGUAGE = SOURCE.defaultLanguage ?? 'en-US';
// The Gradle property a beta build takes, for the messages that say how to rebuild.
const BETA = SETTINGS.betaProperty ?? 'game.beta';
const README = path.relative(process.cwd(), path.resolve(HERE, SETTINGS.readme ?? 'README.md'));

// gplay's metadata tree, built from listing.json each run (not committed).
const TREE = path.join(HERE, 'Metadata');
const IMAGES = path.join(HERE, 'Images');
const DATA_SAFETY = path.join(HERE, 'Compliance/data-safety.csv');
const PRODUCTS = path.join(HERE, 'Monetization/iap');

const send = args.includes('--send');
const offline = args.includes('--offline');
const forReview = args.includes('--send-for-review');
const usage = (why) => { console.error(why); process.exit(2); };
if (offline && send) usage('--offline reads nothing from Play, so it can send nothing: drop one.');
const STEPS = ['listing', 'images', 'screenshots', 'product', 'datasafety', 'release', 'tracks', 'versions', 'status'];
const step = args.find((a) => STEPS.includes(a));
const TRACK = option('--track', 'internal');
const ARTIFACT = option('--aab') ?? option('--apk');
const SHOTS = option('--screenshots') ? path.resolve(option('--screenshots')) : null;

// Every write waits in the Play Console: only the user submits, but for the
// nightly's release.
const HOLD = ['--changes-not-sent-for-review', '--changes-in-review', 'error'];
// Play's answer when an app was never published: it won't hold changes, and
// a commit without the hold would send every pending change for review.
const REFUSES_HOLD = /changesNotSentForReview must not be set/i;

let changes = 0;
let failed = 0;
let sentForReview = false;
let unread = 0;
let readOnly = false;

// gplay's exit codes, so a failed read says what went wrong.
function why(status, text) {
  const first = text.split('\n')[0].replace(/^gplay: /, '');
  if (status === 10) return `no credentials yet (${README})`;
  if (status === 11) return `the service account isn't granted access to ${PACKAGE} yet`;
  if (status === 40 || status === 50) return `Google is unreachable right now (${first})`;
  return first;
}

// Commands that talk to Play name the package and ride out Google's
// transient 5xx and 429; the offline validators take neither.
const online = (...argv) => [...argv, '--package', PACKAGE, '--retry', '3'];

function gplay(argv) {
  const run = spawnSync('gplay', argv, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  if (run.error?.code === 'ENOENT') throw new Error('gplay is not installed: `brew install --cask PollyGlot/tap/gplay`.');
  return { status: run.status, out: (run.stdout ?? '').trim(), err: (run.stderr ?? '').trim() };
}

// A read that may come back empty (no credentials yet, nothing there).
function maybe(argv) {
  if (offline) return null;
  try {
    const { status, out } = gplay(argv);
    return status === 0 && out ? JSON.parse(out) : null;
  } catch {
    return null;
  }
}

const heading = (text) => console.log(`\n${text}\n${'-'.repeat(text.length)}`);
const shown = (file) => path.relative(process.cwd(), file);

// A step's offline lint, then its plan, then (with --send) its held write.
function stage(name, { lint, plan, apply }) {
  if (lint) {
    const linted = gplay(lint);
    if (linted.status !== 0 && plan && lib.onlyTallScreenshots(linted.err || linted.out)) {
      // gplay holds phone screenshots to 2:1; Play takes taller ones, so its commit decides.
      console.log(`${name}: some phone screenshots are taller than gplay's 2:1; Play's commit decides on those.`);
      plan = [...plan, '--skip-preflight'];
      apply = apply && [...apply, '--skip-preflight'];
    } else if (linted.status !== 0) {
      failed += 1;
      console.log(`${name}: the files are wrong, nothing was sent.\n${linted.err || linted.out}`);
      return false;
    } else {
      console.log(`${name}: the files check out.`);
    }
  }
  if (!plan || offline) return true;
  const { status, out, err } = gplay(plan);
  if (status !== 0) {
    unread += 1;
    console.log(`${name}: can't read Play: ${why(status, err || out)}.`);
    return false;
  }
  const summary = (out ? JSON.parse(out) : null)?.summary ?? {};
  const total = lib.counted(summary);
  console.log(`${name}: ${total === 0 ? 'Play is up to date' : lib.describe(summary)}.`);
  if (total === 0) return true;
  changes += total;
  if (!send) return true;
  const wrote = gplay(apply);
  if (wrote.status !== 0 && REFUSES_HOLD.test(wrote.err || wrote.out)) {
    // Never send without the hold: on a never-published app that sends every
    // pending change for review, and an approval can publish the app.
    failed += 1;
    console.log(`${name}: this app has never been published, so Play refuses to hold changes back and would send`);
    console.log('         every pending change for review. Nothing was sent; make this change in the Play Console.');
    return false;
  }
  if (wrote.status !== 0) {
    failed += 1;
    console.log(`${name}: failed to send.\n${wrote.err || wrote.out}`);
    return false;
  }
  console.log(`${name}: sent. It waits in the Play Console, not in review.`);
  return true;
}

// --- listing -------------------------------------------------------------

// listing.json as the tree gplay reads: <locale>/title.txt, both
// descriptions and the promo video.
function buildTree() {
  const over = lib.overLimits(LISTINGS);
  if (over.length) throw new Error(over.join('\n'));
  fs.rmSync(TREE, { recursive: true, force: true });
  for (const [locale, text] of Object.entries(LISTINGS)) {
    const dir = path.join(TREE, locale);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'title.txt'), text.title);
    fs.writeFileSync(path.join(dir, 'short_description.txt'), text.shortDescription);
    fs.writeFileSync(path.join(dir, 'full_description.txt'), text.fullDescription);
    if (text.video) fs.writeFileSync(path.join(dir, 'video.txt'), text.video);
  }
  return Object.keys(LISTINGS).length;
}

function listingStep() {
  heading('Store listing');
  if (!Object.keys(LISTINGS).length) {
    console.log('listing.json has no listings: the listing is kept in the Play Console.');
    return;
  }
  console.log(`${buildTree()} languages built from listing.json into ${shown(TREE)}.`);
  stage('Listing', {
    lint: ['metadata', 'validate', '--dir', TREE, '--output', 'json'],
    plan: online('metadata', 'apply', '--dir', TREE, '--dry-run', '--output', 'json'),
    apply: online('metadata', 'apply', '--dir', TREE, '--confirm', ...HOLD, '--output', 'json'),
  });
}

// --- images --------------------------------------------------------------

// The slots Play knows; anything else in Images/ never reaches one.
const SLOTS = {
  single: ['icon', 'featureGraphic', 'tvBanner'],
  gallery: ['phoneScreenshots', 'sevenInchScreenshots', 'tenInchScreenshots', 'tvScreenshots', 'wearScreenshots'],
};

// The game language listing.json's `locales` maps to `locale`.
const languageOf = (locale) => Object.keys(SOURCE.locales ?? {}).find((l) => SOURCE.locales[l] === locale);

// Fills `target` with the PNGs in `from`, as high-quality JPEGs when asked
// (Play takes them as it takes PNGs, at a fifth of the upload).
function copyShots(from, target, { jpeg = false, only = /\.(png|jpe?g)$/i } = {}) {
  fs.rmSync(target, { recursive: true, force: true });
  fs.mkdirSync(target, { recursive: true });
  const files = fs.readdirSync(from).filter((f) => only.test(f)).sort();
  for (const file of files) {
    if (jpeg && file.endsWith('.png')) {
      execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '92', path.join(from, file), '--out', path.join(target, file.replace(/\.png$/, '.jpg'))], { stdio: 'ignore' });
    } else {
      fs.copyFileSync(path.join(from, file), path.join(target, file));
    }
  }
  return files.length;
}

// Each locale's images: its own Images/<locale>/, else the default
// language's; a gallery it doesn't hold comes from the game's renders
// (play.json `renders`: { dir, slots: { <slot>: <set> } }, read as
// <dir>/<set>/<game language>/*.png) or from --screenshots.
function buildImages() {
  const fallback = path.join(IMAGES, DEFAULT_LANGUAGE);
  const renders = SETTINGS.renders;
  let slots = 0;
  for (const locale of Object.keys(LISTINGS)) {
    const from = fs.existsSync(path.join(IMAGES, locale)) ? path.join(IMAGES, locale) : fallback;
    const to = path.join(TREE, locale, 'images');
    const language = languageOf(locale);
    if (renders && language) {
      for (const [slot, set] of Object.entries(renders.slots ?? {})) {
        const rendered = path.resolve(HERE, renders.dir, set, language);
        if (!fs.existsSync(rendered) || fs.existsSync(path.join(from, slot))) continue;
        copyShots(rendered, path.join(to, slot), { jpeg: renders.jpeg !== false, only: /\.png$/ });
        slots += 1;
      }
    }
    if (SHOTS && language) {
      const shots = path.join(SHOTS, language);
      if (!fs.existsSync(shots) || !fs.readdirSync(shots).some((f) => /^\d+\.png$/.test(f))) {
        throw new Error(`No screenshots for ${language} in ${shots}.`);
      }
      copyShots(shots, path.join(to, 'phoneScreenshots'), { only: /^\d+\.png$/ });
      slots += 1;
    }
    if (!fs.existsSync(from)) continue;
    fs.mkdirSync(to, { recursive: true });
    for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
      const name = entry.name.replace(/\.(png|jpe?g)$/i, '');
      if (entry.isDirectory() ? !SLOTS.gallery.includes(entry.name) : !SLOTS.single.includes(name)) continue;
      if (entry.isDirectory() && SHOTS && entry.name === 'phoneScreenshots') continue;
      if (entry.isDirectory()) copyShots(path.join(from, entry.name), path.join(to, entry.name));
      else fs.copyFileSync(path.join(from, entry.name), path.join(to, entry.name));
      slots += 1;
    }
  }
  return slots;
}

function imagesStep() {
  heading('Store images');
  if (!Object.keys(LISTINGS).length) {
    console.log('listing.json has no listings: the images are kept in the Play Console.');
    return;
  }
  buildTree();
  const slots = buildImages();
  if (slots === 0) {
    console.log(`No images in ${shown(IMAGES)} yet (${README} has the sizes).`);
    return;
  }
  console.log(`${slots} image slots gathered into the tree.`);
  stage('Images', {
    lint: ['metadata', 'images', 'validate', '--dir', TREE, '--output', 'json'],
    plan: online('metadata', 'images', 'apply', '--dir', TREE, '--dry-run', '--output', 'json'),
    apply: online('metadata', 'images', 'apply', '--dir', TREE, '--confirm', ...HOLD, '--output', 'json'),
  });
}

// The screenshots on Play now, from the default language's listing (else
// the first that has any), into Images/<default language>/ in Play's order.
function screenshotsStep() {
  readOnly = true;
  heading('Screenshots on Play');
  if (offline) { console.log('Offline: nothing read.'); return; }
  const pulled = path.join(HERE, 'Pulled');
  fs.rmSync(pulled, { recursive: true, force: true });
  const run = gplay(online('metadata', 'images', 'pull', '--dir', pulled, '--output', 'json'));
  if (run.status !== 0) {
    unread += 1;
    console.log(`Can't read Play: ${why(run.status, run.err || run.out)}.`);
    return;
  }
  const locales = fs.existsSync(pulled) ? fs.readdirSync(pulled).sort() : [];
  const order = [DEFAULT_LANGUAGE, ...locales.filter((l) => l !== DEFAULT_LANGUAGE)];
  for (const slot of SLOTS.gallery) {
    const from = order.map((l) => path.join(pulled, l, 'images', slot)).find((d) => fs.existsSync(d) && fs.readdirSync(d).length);
    if (!from) { console.log(`${slot}: none on Play.`); continue; }
    const to = path.join(IMAGES, DEFAULT_LANGUAGE, slot);
    fs.rmSync(to, { recursive: true, force: true });
    fs.mkdirSync(to, { recursive: true });
    const files = fs.readdirSync(from).filter((f) => /\.(png|jpe?g)$/i.test(f)).sort((a, b) => parseInt(a, 10) - parseInt(b, 10));
    files.forEach((file, i) => fs.copyFileSync(path.join(from, file), path.join(to, `${String(i + 1).padStart(2, '0')}${path.extname(file)}`)));
    console.log(`${slot}: ${files.length} from ${path.relative(pulled, from)} into ${shown(to)}.`);
  }
  fs.rmSync(pulled, { recursive: true, force: true });
}

// --- the managed product -------------------------------------------------

// Its prices and availability live in the Play Console; its localized copy
// in listing.json's `product`, written into the pulled file so the plan
// shows a diff of the text alone.
function productStep() {
  if (!SOURCE.product) return;
  heading('Managed product');
  const file = path.join(PRODUCTS, `${SOURCE.product.productId}.json`);
  if (!fs.existsSync(file)) {
    console.log('No product file yet. Create the product in the Play Console, then seed it with:');
    console.log(`  gplay iap pull --dir ${shown(PRODUCTS)} --package ${PACKAGE}`);
    return;
  }
  const product = JSON.parse(fs.readFileSync(file, 'utf8'));
  const wanted = Object.entries(SOURCE.product.listings ?? {})
    .map(([languageCode, t]) => ({ languageCode, title: t.title, description: t.description }));
  if (JSON.stringify(product.listings ?? []) !== JSON.stringify(wanted)) {
    product.listings = wanted;
    fs.writeFileSync(file, JSON.stringify(product, null, 2) + '\n');
    console.log(`${wanted.length} languages of product copy written into ${path.basename(file)}.`);
  }
  stage('Product', {
    plan: online('iap', 'apply', '--dir', PRODUCTS, '--dry-run', '--output', 'json'),
    apply: online('iap', 'apply', '--dir', PRODUCTS, '--confirm', '--output', 'json'),
  });
}

// --- data safety ---------------------------------------------------------

// Write-only on Play: the CSV exported from the Play Console is kept here,
// so the plan can only say what would be written.
function dataSafetyStep() {
  if (!fs.existsSync(DATA_SAFETY)) {
    if (step === 'datasafety') console.log(`No ${shown(DATA_SAFETY)}: export it from the Play Console and commit it.`);
    return;
  }
  heading('Data Safety');
  const checked = gplay(['compliance', 'datasafety', 'validate', '--file', DATA_SAFETY, '--output', 'json']);
  if (checked.status !== 0) {
    failed += 1;
    console.log(`Data Safety: the CSV is wrong, nothing was sent.\n${checked.err || checked.out}`);
    return;
  }
  const rows = fs.readFileSync(DATA_SAFETY, 'utf8').trim().split('\n').length - 1;
  console.log(`Data Safety: the CSV checks out (${rows} rows). Play can't be read back, so this is a blind write.`);
  if (offline) return;
  changes += 1;
  if (!send) return;
  const wrote = gplay(online('compliance', 'datasafety', 'set', '--file', DATA_SAFETY, '--confirm', '--output', 'json'));
  if (wrote.status !== 0) failed += 1;
  console.log(wrote.status === 0 ? 'Data Safety: sent.' : `Data Safety: failed.\n${wrote.err || wrote.out}`);
}

// --- release -------------------------------------------------------------

// The beta switch an artifact was built with (build.json in its assets).
function betaOf(artifact) {
  const entry = artifact.endsWith('.aab') ? 'base/assets/build.json' : 'assets/build.json';
  const run = spawnSync('unzip', ['-p', artifact, entry], { encoding: 'utf8' });
  return run.status === 0 ? lib.betaIn(run.stdout) : null;
}

function nativeSymbolsOf(artifact) {
  if (!artifact.endsWith('.aab')) return null;
  const run = spawnSync('unzip', ['-Z1', artifact], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return run.status === 0 ? lib.nativeSymbols(run.stdout.split('\n')) : null;
}

// The release notes directory: --notes <file> (cut to Play's 500
// characters, in the default language), else --notes-dir, else
// ReleaseNotes/<track>/, else ReleaseNotes/. Null when there are none.
function notesDir() {
  const file = option('--notes');
  if (file) {
    if (!fs.existsSync(file)) throw new Error(`No notes at ${file}.`);
    const notes = lib.cutNotes(fs.readFileSync(file, 'utf8'));
    if (notes === null) throw new Error(`A line of ${file} is over Play's 500 characters on its own.`);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'play-notes-'));
    fs.writeFileSync(path.join(dir, `${DEFAULT_LANGUAGE}.txt`), notes + '\n');
    return dir;
  }
  return [option('--notes-dir'), path.join(HERE, 'ReleaseNotes', TRACK), path.join(HERE, 'ReleaseNotes')]
    .filter(Boolean)
    .find((dir) => fs.existsSync(dir) && fs.readdirSync(dir).some((f) => f.endsWith('.txt'))) ?? null;
}

function releaseStep() {
  heading(`Release to ${TRACK}`);
  const refuse = (why) => { failed += 1; console.log(`Release: ${why} Nothing was uploaded.`); };
  if (!ARTIFACT) {
    console.log('Pass --aab <path> (or --apk <path>) to plan a release.');
    return;
  }
  const production = TRACK === 'production';
  if (!production && !lib.TESTING.includes(TRACK)) return refuse(`${TRACK} isn't a track (${lib.TESTING.join(', ')} or production).`);
  const rollout = args.includes('--rollout');
  const also = lib.tracksIn(option('--also'));
  if (production && (rollout || forReview || also.length)) {
    return refuse('--rollout, --also and --send-for-review are for testing tracks only. Production is only ever a draft, rolled out and sent from the Play Console.');
  }
  const alsoWrong = lib.alsoProblem(TRACK, also);
  if (alsoWrong) return refuse(`${alsoWrong}.`);
  if (forReview && !rollout) return refuse('--send-for-review sends a rolled-out release; pass --rollout with it.');
  if (!fs.existsSync(ARTIFACT)) return refuse(`${ARTIFACT} is not there.`);
  // A testing track takes a beta build, production a build of its own.
  const beta = betaOf(ARTIFACT);
  if (beta !== !production) {
    const name = path.basename(ARTIFACT);
    return refuse(`${beta === null ? `${name} carries no build.json, so it isn't known to be a ${production ? 'production' : 'beta'} build`
      : production ? `${name} is a beta build; production takes a build of its own`
        : `${name} isn't a beta build; a testing track takes one`}: rebuild it with -P${BETA}=${!production}.`);
  }
  // Play vitals reads native stacks against the symbols the bundle carries.
  const symbols = nativeSymbolsOf(ARTIFACT);
  if (symbols?.missing.length) {
    console.log(`Release: no native debug symbols for ${symbols.missing.length} of ${symbols.libraries.length} libraries`);
    console.log(`         (${symbols.missing.slice(0, 4).join(', ')}${symbols.missing.length > 4 ? ', …' : ''}), so Play vitals can't read their stacks.`);
    console.log('         Build the shell with `Android/Scripts/build-shell.sh --store`.');
  } else if (symbols) {
    console.log(`Release: native debug symbols for all ${symbols.libraries.length} libraries.`);
  }
  const mapping = option('--mapping');
  if (mapping && !fs.existsSync(mapping)) return refuse(`the mapping file ${mapping} is not there.`);
  const argv = ['releases', 'upload', ARTIFACT, '--track', TRACK, rollout ? '--complete' : '--draft', '--output', 'json'];
  const notes = notesDir();
  if (notes) argv.push('--release-notes-dir', notes);
  const name = option('--name');
  if (name) argv.push('--release-name', name);
  if (mapping) argv.push('--mapping', mapping);
  // Offline: the container and package name, without opening an edit.
  const checked = gplay([...argv, '--dry-run', '--package', PACKAGE]);
  if (checked.status !== 0) return refuse(`the artifact is wrong.\n${checked.err || checked.out}`);
  console.log(`Release: ${path.basename(ARTIFACT)} checks out for ${PACKAGE}, ready for ${TRACK}`
    + `${also.length ? ` and ${also.join(', ')}` : ''}${rollout ? ', rolled out' : ', as a draft'}${forReview ? ', sent for review' : ''}.`);
  if (offline) return;
  changes += 1;
  if (!send) return;
  const published = lib.everPublished(maybe(online('tracks', 'list', '--output', 'json'))?.tracks);
  // Sent for review: no hold, and a review already under way makes the
  // commit fail rather than be cancelled and resubmitted.
  const commit = forReview ? ['--changes-in-review', 'error'] : HOLD;
  const wrote = gplay(online(...argv, ...commit));
  if (wrote.status !== 0 && REFUSES_HOLD.test(wrote.err || wrote.out)) {
    return refuse('this app has never been published, so Play refuses to hold the release back and would send every pending change for review. Upload it in the Play Console instead.');
  }
  if (wrote.status !== 0) { failed += 1; console.log(`Release: failed.\n${wrote.err || wrote.out}`); return; }
  if (forReview) sentForReview = true;
  console.log(production
    ? 'Release: uploaded as a draft on production. It reaches nobody until it is rolled out in the Play Console.'
    : rollout
      ? `Release: rolled out on ${TRACK}${forReview ? ' and sent for review' : ', waiting in the Play Console to be sent for review'}.`
      : `Release: uploaded as a draft on ${TRACK}. Roll it out from the Play Console.`);
  if (forReview && !published) {
    console.log('Release: the app had never been published on Play, so every pending change (the listing, pricing and');
    console.log('         the rest) went for review with it.');
  }
  // The same release, version code and notes on each further testing track.
  for (const to of also) {
    const promote = ['releases', 'promote', '--from', TRACK, '--to', to, rollout ? '--complete' : '--draft', '--output', 'json'];
    if (name) promote.push('--release-name', name);
    const copied = gplay(online(...promote, ...commit));
    if (copied.status !== 0) { failed += 1; console.log(`Release: copying it to ${to} failed.\n${copied.err || copied.out}`); continue; }
    console.log(`Release: copied to ${to}${rollout ? ', rolled out' : ' as a draft'}${forReview ? ' and sent for review' : ''}.`);
  }
}

// --- reading the state back ---------------------------------------------

function tracksStep() {
  readOnly = true;
  heading('Tracks');
  if (offline) { console.log('Offline: nothing read.'); return; }
  const tracks = maybe(online('tracks', 'list', '--output', 'json'));
  if (!tracks) {
    unread += 1;
    console.log(`Can't read Play (${README} has the setup).`);
    return;
  }
  const list = tracks.tracks ?? [];
  if (!list.length) console.log('  no tracks yet');
  for (const track of list) {
    const releases = (track.releases ?? []).map((r) => `${r.name ?? '?'} (${r.status})`).join(', ');
    console.log(`  ${String(track.track).padEnd(12)} ${releases || 'nothing'}`);
    const testers = maybe(online('testers', 'list', '--track', track.track, '--output', 'json'));
    const groups = testers?.googleGroups ?? testers?.groups ?? [];
    if (groups.length) console.log(`               testers: ${groups.join(', ')}`);
  }
}

// What Play has given out, for the version tools and nightlies: read-only.
function versionsStep() {
  readOnly = true;
  const json = args.includes('--json');
  const version = option('--approved');
  const read = (argv) => {
    const run = gplay(online(...argv, '--output', 'json'));
    if (run.status !== 0) throw new Error(`gplay ${argv.slice(0, 3).join(' ')}: ${why(run.status, run.err || run.out)}`);
    return run.out ? JSON.parse(run.out) : {};
  };
  if (offline) throw new Error('versions reads Play; it has nothing to show offline.');
  const releases = lib.releasesIn(read(['tracks', 'list']).tracks);
  const uploaded = lib.uploadedIn(read(['releases', 'artifacts', 'list']));
  const highest = Math.max(0, ...releases.flatMap((r) => r.versionCodes), ...uploaded);
  const found = version ? lib.approvedRelease(releases, version) : null;
  const approved = found && { name: found.name, status: found.status };
  if (json) {
    process.stdout.write(JSON.stringify({ package: PACKAGE, highest, releases, uploaded, ...(version ? { approved } : {}) }, null, 2) + '\n');
    process.exit(0);
  }
  heading('Versions on Play');
  console.log(`  highest version code: ${highest}`);
  for (const r of releases) console.log(`  ${String(r.track).padEnd(12)} ${r.name ?? '?'} (${r.status}) ${r.versionCodes.join(', ')}`);
  if (version) console.log(approved ? `  ${version} is approved: production ${approved.name} (${approved.status})` : `  ${version} has no approved production release`);
}

function statusStep() {
  readOnly = true;
  heading('Live on Play');
  if (offline) { console.log('Offline: nothing read.'); return; }
  const live = maybe(online('metadata', 'list', '--output', 'json'));
  if (!live) {
    unread += 1;
    console.log(`Can't read Play (${README} has the setup).`);
    return;
  }
  console.log(`  ${(live.listings ?? live.locales ?? []).length} listings live.`);
  const images = maybe(online('metadata', 'images', 'list', '--output', 'json'));
  if (images) console.log(`  ${(images.slots ?? []).length} image slots live.`);
  tracksStep();
}

// --- run -----------------------------------------------------------------

const RUN = {
  listing: listingStep, images: imagesStep, screenshots: screenshotsStep, product: productStep,
  datasafety: dataSafetyStep, release: releaseStep, tracks: tracksStep, versions: versionsStep, status: statusStep,
};

try {
  if (step) {
    RUN[step]();
  } else {
    listingStep();
    imagesStep();
    productStep();
    dataSafetyStep();
    if (ARTIFACT) releaseStep();
    tracksStep();
  }
} catch (error) {
  console.error(`\n${error.message}`);
  process.exit(1);
}

console.log('');
if (failed) console.log(`${failed} step${failed === 1 ? '' : 's'} failed.`);
else if (offline) console.log('The files check out. Nothing was read from Play or sent.');
else if (unread) console.log(`The files check out, but ${unread} step${unread === 1 ? '' : 's'} couldn't read Play, so this is no diff of what is live.`);
else if (changes === 0 && readOnly) console.log(step ? 'Nothing was sent.' : 'Nothing to send.');
else if (changes === 0) console.log('Google Play is up to date.');
else if (send && sentForReview) console.log(`Sent ${changes} changes, the release sent for review (testing tracks only).`);
else if (send) console.log(`Sent ${changes} changes. They wait in the Play Console: nothing was submitted for review.`);
else console.log(`${changes} changes. Run with --send to make them.`);
process.exit(failed ? 1 : 0);
