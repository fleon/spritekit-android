# Google Play

`play.js` drives the Google Play Console for every game on this runtime, so
each game's listing, images and releases (the nightly testing build too) go
through one tool with the same guards. It speaks to Play through
[`gplay`](https://github.com/PollyGlot/google-play-cli) (`brew install --cask
PollyGlot/tap/gplay`, signed in with the game's service account).

`node Tools/Play/play.js --help` lists the steps and flags.

## A game's Play directory

Each game keeps its own (`Android/Play/` or `Tools/Play/`):

| File | What it holds |
|---|---|
| `play.js` | Two lines that run this tool on this directory (below). Callers run it as before. |
| `listing.json` | `package`; optionally `defaultLanguage` (default `en-US`), `locales` (game language → Play locale), `listings` (per Play locale: `title`, `shortDescription`, `fullDescription`, optional `video`) and `product` (`productId`, `listings`). With no `listings`, the listing and images stay in the Play Console. |
| `play.json` | Optional settings: `betaProperty` (the Gradle property a beta build takes, default `game.beta`), `readme` (the game's Play notes, default `README.md`) and `renders` (`{ "dir": "…", "slots": { "phoneScreenshots": "<set>" }, "jpeg": true }`: screenshots rendered as `<dir>/<set>/<game language>/*.png`, sent as JPEGs). |
| `Images/<locale>/` | `icon.png`, `featureGraphic.png`, `tvBanner.png` and gallery folders (`phoneScreenshots/`, `sevenInchScreenshots/`, …). A locale without its own takes the default language's. |
| `ReleaseNotes/[<track>/]` | `<locale>.txt` notes for a release, when none are passed. |
| `Monetization/iap/`, `Compliance/data-safety.csv` | The managed product as `gplay iap pull` wrote it, and the Data Safety CSV exported from the Console. Steps without them are skipped. |
| `Metadata/`, `Pulled/` | Built or pulled each run; not committed. |

The game's `play.js`:

```js
#!/usr/bin/env node
// Google Play for this game: the runtime's Tools/Play/play.js on this directory.
process.env.PLAY_DIR = __dirname;
require('../../Android/spritekit-android/Tools/Play/play.js');
```

## Versions

`play.js versions --json [--approved <version>]` reads what Play has given
out, without changing anything: every release on every track, the codes of
every uploaded bundle and APK, the highest of them (the next build's code is
one past it, or past the App Store's), and with `--approved` the production
release Google approved for that version (its name naming it, `1.5.0` or
`1002 (1.5.0)`). The games' version tools and nightly scripts read Play
through it; it exits 1 when Play can't be read.

## Play Games

`games.js` brings a game's Game Center achievements and leaderboards to Play
Games Services as drafts (`--help` has it all). The game runs it through its
own two-line `games.js`, with a `games` section in `play.json`:

| Key | What it says |
|---|---|
| `source` | Where the achievements come from: `{ "appStoreConnect": "<app id>" }` (Game Center live, with its leaderboards), `{ "gameCenterFile": "<file>" }` (a Game Center definitions file) or `{ "snapshot": "<file>" }` (everything written out, steps and leaderboard ranges too). |
| `applicationId` | The Play Games project ID, when the mapping file doesn't hold it yet. |
| `locales` | `"listing"` to name locales through `listing.json`'s map; otherwise App Store Connect's are translated by its table. |
| `idPrefix` | The prefix taken off IDs for steps rules and icon names (else the ID's last part). |
| `steps`, `stepsRequired`, `stepsModule` | Steps for incremental achievements: rules (`[{ "match": "<regex>", "steps": <n or "$1">, "max": <cap> }]`), whether an ID none match is an error, or a game file exporting `stepsFor(id, { root })` for anything rules can't say. |
| `mapping`, `out`, `root` | The mapping file the Android app packs (default `PlayGames/PlayGamesAchievements.json`), where icons and request bodies go (default `PlayGames/Out`), and the repository root (default `../..`), each relative to the Play directory. |

The game's `games.js`:

```js
#!/usr/bin/env node
// Play Games for this game: the runtime's Tools/Play/games.js on this directory.
process.env.PLAY_DIR = __dirname;
require('../../Android/spritekit-android/Tools/Play/games.js');
```

## The nightly testing build

```bash
node <Play dir>/play.js release --aab <bundle> --track internal --also alpha --rollout --send-for-review --name <name> --notes <file> --send
```

It uploads the beta bundle to internal testing, copies the same release
(version code and notes) to closed testing (`alpha`), rolls both out and
sends the edit for review. Internal goes first: its release isn't held for
review, so the copy to closed testing is what goes to review. The other way
round, the second commit would meet a review already under way. Without
`--send` it checks the bundle offline and uploads nothing.

## Rules it keeps

- Every write but that release waits in the Play Console
  (`--changes-not-sent-for-review`): only the user submits. The one way round
  it is `--without-hold`, on a draft release only, for an app whose changes
  Play won't hold (below).
- `--send-for-review` takes a rolled-out testing-track release, and still
  passes `--changes-in-review error`, so it never cancels a review under way.
- Production takes only a non-beta build, only ever as a draft the user rolls
  out; `--rollout`, `--also` and `--send-for-review` refuse it.
- A testing track takes only a beta build (`build.json`'s `beta`, which the
  app template writes from `-P<betaProperty>`).
- Play holds an app's changes back from review only after a rejected update,
  and never for an app it hasn't published; otherwise it refuses
  `--changes-not-sent-for-review`. The tool then sends nothing rather than
  every pending change. A draft release (production, or a testing track
  without `--rollout`) can go up with `--without-hold`: it serves nobody, but
  anything else waiting in the Play Console goes for review with it, so check
  Publishing overview first. A review already under way still makes it fail
  (`--changes-in-review error`), never cancelled.

## Tests

```bash
node --test Tools/Play/play.test.js Tools/Play/games.test.js
```
