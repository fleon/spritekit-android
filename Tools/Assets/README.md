# Assets

`assets.js` checks a game's asset names: every image and sound name its
Swift passes is looked for in its asset catalogs and sound folders, and
what's there that nothing names is listed. A macro can't read an
`.xcassets` folder, so this runs as a script. Node only, no dependencies;
it reads and never writes.

`node Tools/Assets/assets.js --help` lists the command and flags.

## A game's assets directory

Each game keeps `Tools/Assets/` with:

| File | What it holds |
|---|---|
| `assets.js` | Two lines that run this tool on this directory (below). |
| `assets.json` | The game's settings (below). Every key is optional. |

```js
#!/usr/bin/env node
// The game's asset names: the runtime's Tools/Assets/assets.js on this directory.
process.env.ASSETS_DIR = __dirname;
require('../../Android/spritekit-android/Tools/Assets/assets.js');
```

| Key | What it says |
|---|---|
| `root` | The repository root, relative to the assets directory (default `../..`). Every other path is relative to it. |
| `sources` | The Swift folders to read (default `Source`). |
| `catalogs` | The asset catalogs (`.xcassets`) images come from. |
| `sounds` | The folders sound files (`.wav`, `.caf`, `.m4a`, `.mp3`, `.aac`, `.aiff`, `.ogg`) come from. |
| `calls` | A game's own functions that take a name first: `{ "images": ["badge"], "sounds": ["kick"] }`. |
| `enums` | The `String` enums whose cases name assets (default every one in the sources). |
| `ignore` | Names neither checked nor listed as unused. |

## What it reads

Images: the first argument of `txtr`, `sprite`, `tinted`, `sliced`,
`SKTexture(imageNamed:)`, `SKSpriteNode(imageNamed:)` and `UIImage(named:)`.
An asset catalog's names are its `.imageset` folders, under a folder's name
where the folder provides a namespace.

Sounds: the first argument of `playSound`, `playMusic`,
`AudioManager.shared.play`, `playMusic` and `playEffect`,
`AudioConfiguration.Sound` and `playSoundFileNamed`, and every case of an
enum passed to `AudioConfiguration.sounds(T.self)`. A name with variants
(`Name 1`, `Name 2`, as `AudioConfiguration.variantName` makes them) is
found by its variants.

An argument that is a `String` enum's case (`.tap`, `Sound.tap`) reads as
its raw value. A name built at run time (an interpolated string, a
variable, a computed property) can't be checked: it is listed as
unchecked, and an asset whose name starts with an interpolated string's
literal start is listed as maybe used rather than unused.

## The command

**`check`** prints the counts, then each missing name with where it's asked
for, each unused and maybe-used asset, and each unchecked name. It exits 1
when anything is missing. `--quiet` prints the counts alone, `--json` the
whole report.

## Tests

```bash
node Tools/guard.js 12 -- node --test Tools/Assets/assets.test.js
```
