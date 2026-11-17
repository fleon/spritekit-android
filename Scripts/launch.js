#!/usr/bin/env node
'use strict';
// Starts the game on an Android device with the game's launch arguments,
// as `xcrun simctl launch <udid> <bundle> -StartLevel level-1 …` does on a
// simulator, whatever the arguments hold (spaces, commas, quotes, plist
// syntax): they go as `args64`, base64 of a JSON array, which no shell on
// the way splits (MainActivity.getArguments).
//
//   node Scripts/launch.js [--package com.example.game.debug] -- \
//       -StartLevel level-1 -Note "a;b@0.05" -settings.musicEnabled "<false/>"
//
// Stops the app first, so it starts afresh. Targets $ANDROID_SERIAL
// (Scripts/emulators.sh acquire sets it). Debuggable builds only:
// a release build ignores the extra.
const { execFileSync } = require('child_process');

// The game's wrapper sets these; --package overrides the first.
const DEFAULT_PACKAGE = process.env.SKA_APP_PACKAGE || '';
const ACTIVITY = process.env.SKA_APP_ACTIVITY || '';

// The `am start` arguments that hand `args` to the game.
function startArguments(pkg, args) {
  const encoded = Buffer.from(JSON.stringify(args), 'utf8').toString('base64');
  return ['shell', 'am', 'start', '-S', '-W', '-n', `${pkg}/${ACTIVITY || `${DEFAULT_PACKAGE || pkg}.MainActivity`}`, '--es', 'args64', encoded];
}

function launch(pkg, args, { adb = 'adb', serial } = {}) {
  return execFileSync(adb, [...(serial ? ['-s', serial] : []), ...startArguments(pkg, args)], { encoding: 'utf8' });
}

module.exports = { DEFAULT_PACKAGE, startArguments, launch };

if (require.main === module) {
  const argv = process.argv.slice(2);
  let pkg = DEFAULT_PACKAGE;
  const split = argv.indexOf('--');
  const options = split < 0 ? [] : argv.slice(0, split);
  const args = split < 0 ? argv : argv.slice(split + 1);
  for (let i = 0; i < options.length; i++) {
    if (options[i] === '--package') pkg = options[++i];
  }
  process.stdout.write(launch(pkg, args));
}
