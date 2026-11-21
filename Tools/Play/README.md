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
  (`--changes-not-sent-for-review`): only the user submits.
- `--send-for-review` takes a rolled-out testing-track release, and still
  passes `--changes-in-review error`, so it never cancels a review under way.
- Production takes only a non-beta build, only ever as a draft the user rolls
  out; `--rollout`, `--also` and `--send-for-review` refuse it.
- A testing track takes only a beta build (`build.json`'s `beta`, which the
  app template writes from `-P<betaProperty>`).
- An app Play has never published refuses the hold; the tool then sends
  nothing rather than every pending change.

## Tests

```bash
node --test Tools/Play/play.test.js
```
