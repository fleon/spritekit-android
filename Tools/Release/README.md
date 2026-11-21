# Releases: the nightly and the build number

Every game on this runtime ships its nightly testing build the same way and
numbers its builds by the same rule, through two tools here:

- `nightly.js` is the nightly release: when PRs were merged since the last
  build, one build of the game's default branch with one build number on
  every platform, to TestFlight (internal and external testers) and Google
  Play's internal and closed testing, sent for review.
- `version.js` works out the build number iOS and Android share, and the
  version.

Each game runs them through small shims, with its settings in
`Tools/Release/release.json`. `--help` on either lists its options.

## A game's files

| File | What it holds |
|---|---|
| `Tools/Release/release.json` | The game's settings (below). |
| `Tools/Release/nightly.sh` | The shim the nightly task runs (below). |
| its version tool, where callers expect it | Two lines that run `version.js` with the settings (below). |

`Tools/Release/nightly.sh`:

```bash
#!/bin/bash
# This game's nightly release: the runtime's Tools/Release/nightly.js with release.json.
HERE="$(cd "$(dirname "$0")" && pwd)"; TOOL="$HERE/../../Android/spritekit-android/Tools/Release/nightly.js"
[ -f "$TOOL" ] || git -C "$HERE/../.." submodule update -q --init Android/spritekit-android || exit 1
RELEASE_CONFIG="$HERE/release.json" exec node "$TOOL" "$@"
```

It initialises the runtime submodule when it's missing, as in a fresh
worktree the nightly task launches it from.

The version tool (`Tools/Play/version.js`, `Scripts/version.cjs`, …; adjust
the paths to where it sits):

```js
#!/usr/bin/env node
// This game's build number: the runtime's Tools/Release/version.js with Tools/Release/release.json.
process.env.RELEASE_CONFIG = require('path').join(__dirname, '../../Tools/Release/release.json');
require('../../Android/spritekit-android/Tools/Release/version.js');
```

## Settings

| Key | What it says |
|---|---|
| `project` | The Xcode project (`Game.xcodeproj`): its `CURRENT_PROJECT_VERSION` is the build number on both platforms, its `MARKETING_VERSION` the version. |
| `playDir` | The game's Play directory (`Android/Play`), whose `play.js` reads Play (`versions --json`) and makes the release. |
| `version` | Optional: `exportPrefix` (default `GAME`: the tool prints `export GAME_VERSION_CODE=…` and `…_VERSION_NAME=…`) and `patchNames` (`true`: the version name counts further Play uploads at one version, `1.1`, `1.1.1`, `1.1.2`, …). |
| `appStore` | `app` (the App Store Connect app ID; without it the version tool reads only Play), and for the nightly `externalGroup` (TestFlight's External group), `team`, `scheme` and `platforms` (default `["IOS"]`; also `TV_OS`, `MAC_OS`). |
| `name`, `repo`, `branch` | For the nightly: the game's name in its report and logs, its GitHub repository, and its default branch (default `main`). |
| `android` | `gradleProperties` (for `bundleRelease`, the beta switch at least: `["-Pgame.beta=true"]`), `releaseName` (Play's release name, default `{version}`) and `art` (steps that make the Android art, after SDL and before the store shell). |
| `art` | Steps that make art both platforms need, before either builds; when one fails, neither builds. |
| `notes` | For notes drafted without `--notes`: `tooling` (a regex of paths players never see; PRs touching only those are left out), `fallback` (the line when nothing's left, default `• Fixes and improvements.`), `draft: false` (the fallback alone). |
| `root`, `submodule` | Rarely: the repository root from the settings file (default `../..`) and the runtime submodule (default `Android/spritekit-android`). |

A step is `{ "name": "<log name>", "run": ["<command>", "<arg>", …] }`, run
in the release worktree. Arguments may name `{runtime}` (the worktree's
runtime submodule), `{guard}` (its `Tools/guard.js`), `{worktree}`,
`{build}` and `{version}`; the same are in the environment as
`RELEASE_RUNTIME`, `RELEASE_GUARD`, `RELEASE_WORKTREE`, `RELEASE_BUILD` and
`RELEASE_VERSION`, with `RELEASE_LOGS` and `RELEASE_DRY_RUN`. A game's own
logic, such as art cached by its inputs, goes in a script of its own that a
step runs.

## The build number

One number for both platforms: the Xcode project's
`CURRENT_PROJECT_VERSION`, which the Android build reads as its versionCode
(or takes as a Gradle property). A new build, on either platform, takes one
past the highest any of them has taken:

- the project's;
- App Store Connect's: every build in any state, and every upload that went
  up or failed (`asc builds list`, `asc builds uploads list`). An export for
  App Store Connect, a dry run's included, leaves an upload awaiting its file
  that never comes; it takes no number;
- Play's: every release on every track and every uploaded bundle or APK,
  read through the game's own `play.js versions --json`, never `gplay`.

```bash
node <tool>                 # where each stands, and the next build
node <tool> --next          # write the next to the project, for both platforms
node <tool> --offline       # read neither store
node <tool> --set <n>       # write n, never below what it can see
eval "$(node <tool> --next)"   # and take the exports
```

The exports' code is the build now: the project's number, or one past the
stores when one of them has taken it. Both stores are only read.

## The nightly

```bash
Tools/Release/nightly.sh --dry-run                       # everything but uploads and the push
Tools/Release/nightly.sh --dry-run --ref <commit>        # the same, built from a branch
Tools/Release/nightly.sh --notes notes.txt               # the release (the nightly task runs it)
```

1. **Decide.** The last build is the newest `Build <N>` commit on
   `origin/<branch>` (before the first, the commit that last set
   `CURRENT_PROJECT_VERSION`). What's new: the merged PRs whose merge commit
   is on the branch but not in that build, and the `Runtime to <sha>` commits
   the nightly task pushes. With neither, it prints "nothing merged since
   Build <N>" and stops.
2. **Worktree.** Everything happens in a throwaway worktree of the branch,
   with the runtime submodule, removed at the end; the checkout it's run from
   is only fetched.
3. **Version.** The minor goes up (1.7 → 1.8, 1.4.1 → 1.5.0) once the
   version has an approved release on either store: an App Store version
   Apple approved (waiting for release, live, or later replaced or removed),
   or a production release on Play that names the version and that Google
   approved (`play.js versions --approved`). Then the next build number. Both
   go into a `Build <N>` commit (`Build <N> (version <v>)` when the version
   moved), pushed only after an upload.
4. **Notes.** This build's changes, `• ` lines in plain words for players:
   `--notes`, else drafted from the PR titles (the `notes` settings).
5. **Art.** The game's `art` steps.
6. **Apple.** For each platform, archive and export through `asc`
   (`manageAppVersionAndBuildNumber` off, so the number stays), upload to
   TestFlight, set the notes as What to Test (en-US), and add the External
   group with `--submit`, which starts beta review; the Internal group gets
   every build on its own.
7. **Android.** FreeType and HarfBuzz, SDL, the game's `android.art`, the
   store shell (`build-shell.sh --store`) and `bundleRelease` with its
   Gradle properties, signed through 1Password's service account. Then
   `play.js release --track internal --also alpha --rollout
   --send-for-review` with the notes: checked offline first, sent only on a
   real run. Never production.
8. **Push and report.** The version and build, each platform's result, the
   push, the logs (`~/Library/Logs/<Name>Nightly/`) and the notes. It exits
   1 when a platform failed.

`--dry-run` does it all but the uploads and the push. A failure on one
platform doesn't stop the other; when nothing uploads, the build number
isn't pushed and the next night tries again.

## Tests

```bash
node --test Tools/Release/release.test.js
```
