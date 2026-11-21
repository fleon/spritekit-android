# Game Center

`gamecenter.js` keeps a game's Game Center achievements and leaderboards in
App Store Connect in step with a definitions file in the game's repository:
names, descriptions and images in every language, points, score formats. It
speaks to App Store Connect through the `asc` CLI, signed in for the game's
team. `generate-art.js` paints the achievement images with the Codex CLI's
image generation.

`node Tools/GameCenter/gamecenter.js --help` and `generate-art.js --help`
have every flag and setting.

A game that keeps its achievements only in App Store Connect needs none of
this; Play Games can read them from there (`Tools/Play`, "Play Games").

## A game's Game Center directory

Each game that keeps its definitions keeps them in its own directory
(`Tools/GameCenter/`, say):

| File | What it holds |
|---|---|
| `upload-achievements.js` | Two lines that run `gamecenter.js` on this directory (below). Callers run it as before. |
| `achievements.json` | `app` (the App Store Connect app ID), `achievements` in the order Game Center lists them and, optionally, `leaderboards` (schema in `gamecenter.js --help`). |
| `Images/` | The images the definitions name, relative to the file. |
| `generate-art.js` | Two lines that run this `generate-art.js` on this directory, when the game paints its images. |
| `Art/` | `brief.md`, the shared art direction, and one `<name>.txt` prompt per image, its first line naming the references to attach. |
| `gamecenter.json` | Optional art settings under `art`: the game's `references` module (which renders reference sheets and resolves its own kinds of reference), the asset catalog, the Codex model and effort. |

The game's `upload-achievements.js`:

```js
#!/usr/bin/env node
// Game Center for this game: the runtime's Tools/GameCenter/gamecenter.js on this directory.
process.env.GAME_CENTER_DIR = __dirname;
require('../../Android/spritekit-android/Tools/GameCenter/gamecenter.js');
```

and its `generate-art.js` the same, requiring `generate-art.js`.

## Rules it keeps

- Without `--send` it only reads App Store Connect and prints the plan.
- `--send` creates and corrects; it never deletes an achievement, a
  leaderboard or a localization, and never submits anything for review: a
  new achievement or leaderboard goes live with an app version the user
  submits.
- What a definition leaves out (whether an achievement is hidden, a
  leaderboard's suffixes) is left as App Store Connect has it.
- A definitions file with a problem (a missing field, a duplicate vendor ID,
  more than Game Center's 1000 points, a missing image) stops it before it
  reads anything.

## Tests

```bash
node --test Tools/GameCenter/gamecenter.test.js
```
