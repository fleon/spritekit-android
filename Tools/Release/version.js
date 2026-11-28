#!/usr/bin/env node
'use strict';
// One build number for a game on iOS and Android, and its version.
//
//   node <game>/version.js              where the project and the stores stand, and
//                                       the next build; the exports for a build now
//   node <game>/version.js --next       write the next build number to the project
//                                       (--bump says the same)
//   node <game>/version.js --set <n>    write n, never below what it can see
//   node <game>/version.js --offline    read neither store (--print-only says the same)
//   node <game>/version.js --json       the same, as JSON, for scripts
//   node <game>/version.js --release    the nightly's step: the minor goes up once the
//                                       version is in production on the iOS App
//                                       Store, then --next; JSON on stdout
//
// The Xcode project's CURRENT_PROJECT_VERSION is the build number on both
// platforms (the Android build reads it as its versionCode), and its
// MARKETING_VERSION the version (on Android without a patch of 0: 1.5.0
// is named 1.5). A new build, on either platform, takes
// one past the highest any of them has taken: the project's, App Store
// Connect's (every build and upload, through `asc`) and Play's (every release
// on every track and every uploaded bundle, through the game's own
// `play.js versions`). Both stores are only read.
//
// The last lines on stdout are shell exports for a build to take, the rest
// goes to stderr:
//   eval "$(node <game>/version.js --next)"
//   export <PREFIX>_VERSION_CODE=…    the build now: the project's number unless a
//   export <PREFIX>_VERSION_NAME=…    store took it, then one past the stores
//
// A game runs it through a two-line shim that names its release.json
// (RELEASE_CONFIG); Tools/Release/README.md has the settings.

const fs = require('fs');
const { loadSettings, survey, release, nameFor, writeBuild } = require('./stores');

if (process.argv.slice(2).some((a) => a === '--help' || a === '-h')) {
  const lines = fs.readFileSync(__filename, 'utf8').split('\n');
  const end = lines.findIndex((l, i) => i > 2 && !l.startsWith('//'));
  console.log(lines.slice(2, end).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}

function main(args) {
  const { settings, root } = loadSettings();
  const has = (...flags) => flags.some((f) => args.includes(f));
  const known = ['--next', '--bump', '--set', '--offline', '--print-only', '--json', '--release', '--highest'];
  const unknown = args.filter((a, i) => a.startsWith('--') && !known.includes(a) && args[i - 1] !== '--set');
  if (unknown.length) throw new Error(`unknown option ${unknown[0]} (--help lists them)`);
  if (has('--release')) {
    process.stdout.write(JSON.stringify(release({ root, settings }), null, 2) + '\n');
    return;
  }
  const offline = has('--offline', '--print-only');
  const s = survey({ root, settings, offline });
  let code = s.now;
  let wrote = null;
  if (has('--next', '--bump')) {
    code = s.next;
    wrote = writeBuild(root, settings, s.text, code);
  } else if (has('--set')) {
    const set = Number(args[args.indexOf('--set') + 1]);
    if (!Number.isInteger(set) || set < s.highest) throw new Error(`--set needs a whole number of at least ${s.highest}`);
    code = set;
    wrote = writeBuild(root, settings, s.text, code);
  }
  const name = nameFor(settings, s.marketing, code, s.play);
  if (has('--json')) {
    process.stdout.write(JSON.stringify({
      project: s.project, version: s.marketing, appStore: s.readsAppStore ? Math.max(0, ...s.appStore) : null,
      play: s.play ? s.play.highest : null, highest: s.highest, next: s.next, code, name, wrote,
    }, null, 2) + '\n');
    return;
  }
  const notRead = (read, value) => (read ? value || 'none' : 'not read');
  console.error(`Xcode project: build ${s.project}, version ${s.marketing}`);
  console.error(`App Store Connect: highest build ${notRead(s.readsAppStore, Math.max(0, ...s.appStore))}`);
  console.error(`Play: highest version code ${notRead(Boolean(s.play), s.play?.highest)}`);
  console.error(`Next build: ${s.next}`);
  if (wrote !== null) console.error(wrote ? `Wrote CURRENT_PROJECT_VERSION = ${code} (iOS, and Android's versionCode).` : `The project is already at ${code}.`);
  const prefix = settings.version.exportPrefix;
  console.log(`export ${prefix}_VERSION_CODE=${code}`);
  console.log(`export ${prefix}_VERSION_NAME=${name}`);
}

try {
  main(process.argv.slice(2));
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
