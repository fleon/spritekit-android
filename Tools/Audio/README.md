# Audio

`music.js` is every game's soundtrack tool. It finds where each track loops
musically, cuts and encodes the files the game bundles so they loop without a
seam, and checks the result. `PlatformAudio` then plays each track's intro
once and repeats its loop section, on Apple's engine and Android's mixer alike,
picking up where it was after a scene change, an interruption or the app's
time in the background.

macOS only (`afconvert`, AVFoundation through `xcrun swift`); nothing leaves
the machine. `node Tools/Audio/music.js --help` lists the commands and flags.

## A game's audio directory

Each game keeps `Tools/Audio/` with:

| File | What it holds |
|---|---|
| `music.js` | Two lines that run this tool on this directory (below). |
| `music.json` | The game's settings (below). |
| `loops.json` | The loop points `music.js loops` found, with what it measured: commit it. |
| `Masters/` | The soundtrack's masters, one file a track. Never bundled. |

```js
#!/usr/bin/env node
// The game's soundtrack: the runtime's Tools/Audio/music.js on this directory.
process.env.MUSIC_DIR = __dirname;
require('../../Android/spritekit-android/Tools/Audio/music.js');
```

| Key | What it says |
|---|---|
| `root` | The repository root, relative to the audio directory (default `../..`). Every other path is relative to it. |
| `tracks` | Each master's name (its file name without the extension) and the resource the game plays it by, in order: `{ "Title Theme": "MusicTitle" }`, or `{ "Title Theme": { "resource": "MusicTitle", "minLoopSeconds": 90 } }`. |
| `masters` | The masters' folder (default `Tools/Audio/Masters`). A master may be WAV, AIFF, CAF, FLAC, M4A or MP3; lossless is best, as the export encodes it again. |
| `output` | Where the encoded `.m4a` files go (default `Assets/Music`). |
| `loops` | The loops file (default `Tools/Audio/loops.json`). |
| `swift` | The generated Swift file of loop points (default `Source/Utils/MusicLoops.swift`). |
| `bitrate` | The AAC bitrate (default `128000`). |

A track's `minLoopSeconds` keeps shorter loops out of the search: for a song
whose only close repeats are a few bars long, which would leave most of it
heard once and the same half minute after that. The longer loop it picks
matches less closely (`loops.json` notes a weak match); listen to its seam
(`check --seams`). Its `maxIntroSeconds` keeps loops starting later out:
where the loop could start anywhere (a medley's exact repeat), an early start
keeps the intro, and so the file, short.

### Medleys

A track can instead play several masters in turn, for a soundtrack made of
pieces that share a tempo: the first piece's intro once, then each piece's
chosen bars, round and round, each handing over to the next with a blend
centred on a bar line. Give the track a `medley` in place of a master of its
own (its name in `tracks` is then just a key):

```json
"BackgroundMusic": {
  "resource": "BackgroundMusic",
  "minLoopSeconds": 200,
  "medley": {
    "bpm": 120,
    "blendBeats": 4,
    "parts": [
      { "master": "Theme A", "firstDownbeat": 0.05, "from": 8, "to": 90 },
      { "master": "Theme B", "firstDownbeat": 2.4, "from": 20, "to": 56 }
    ]
  }
}
```

Each part names a master, the time of its first downbeat in seconds, and the
bars it plays (`from` to `to`, counted from that downbeat; `beatsPerBar`
defaults to 4, `blendBeats` to 4). Every command builds the medley first, in
a scratch folder: the first part from its first frame to its bar `to`, each
other part from `from` to `to`, then the first part again from its bar
`from` to its own end. That second pass repeats the first exactly, so
`loops` finds the whole round as the loop, as it would any other song's,
and `export` and `check` treat the medley as the track's master. Set
`minLoopSeconds` near the round's length so the search can't settle on a
shorter repeat inside one piece, and `maxIntroSeconds` to a few bars so the
seam lands early in the first part. The beat grid of each part (`bpm`,
`firstDownbeat`) comes from `loops --debug` run on the parts as tracks of
their own; pieces blended on the beat must share the tempo, as a blend
between two grids that drift apart flams.

Pieces in tempos or keys of their own don't blend on the beat: play each
whole and hand over in its fade-out. Give each part its own `bpm` (it counts
its bars on its own grid), the blend in seconds (`blendSeconds`, in place of
`blendBeats`, the medley then needing no common `bpm`), and `"from": "start"`,
so the part comes in from its first frame (the blend beginning there) rather
than across a bar line; its `to` is a bar in its fade, where the next piece
takes over:

```json
"medley": {
  "blendSeconds": 0.05,
  "parts": [
    { "master": "Theme A", "bpm": 120, "firstDownbeat": 0.08, "from": "start", "to": 91 },
    { "master": "Theme B", "bpm": 87, "firstDownbeat": 1.18, "from": "start", "to": 64 }
  ]
}
```

Keep the blend shorter than the time before the piece's first attack, or the
fade-in softens it.

The game hands the loop points to the audio manager and plays the `.m4a`
files:

```swift
AudioManager.configure(AudioConfiguration(
    // ...
    musicLoops: MusicLoops.all,
    musicExtensions: ["m4a"]
))
```

## Commands

```sh
node Tools/Audio/music.js loops [--only <master>] [--debug <dir>]
node Tools/Audio/music.js export
node Tools/Audio/music.js check [--seams <dir>]
```

- `loops` analyses each master (`find-loops.swift`): its tempo and beats,
  bars and downbeats, the intro and ending (quieter, sparser or slowing bars
  at either end), then a loop on two downbeats whose music matches (the bars
  before, after or either side), longer loops and 4- and 8-bar phrases
  preferred, and the seam placed on the waveform just before the downbeat's
  attack. It writes `loops.json`; `--debug` adds each track's similarity map
  and its best candidates.
- `export` cuts each master: everything up to the loop's end, its last
  40 ms crossfaded into the audio just before the loop's start, then a little
  of the loop's start, so the encoder codes the seam as it's heard. It encodes
  that to AAC in an MPEG-4 file (which records the encoder delay, so frame N
  of the file is frame N of the master), writes the Swift file and runs
  `check`. A master that changed since its loop was found stops it.
- `check` decodes each exported file and renders its seam through
  `AVAudioPlayerNode` as the game schedules it, and prints the encoder
  offset, whether the player's join is exact, and the seam's level step, dips
  and bumps and beat grid against the master's own transitions; `--seams`
  writes 4 s either side of each seam as a WAV to listen to.

Run `loops` when a master changes, then `export`, and commit `loops.json`,
the `.m4a` files and the Swift file together.
