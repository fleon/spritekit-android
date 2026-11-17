# Text

Shaping, metrics, rasterising and a glyph atlas: HarfBuzz and FreeType under
a Swift API, and the `TextProvider` the shim asks for its label layout.

A package of its own, like `Modules` and `Shell`. It has C dependencies of
its own (FreeType and HarfBuzz), and putting them in `../Package.swift` would
make `swift build` there need a cmake run first —
for everyone working on the scene graph, the actions or the renderer, none of
whom need text. So the shim never links FreeType. It calls whatever provider
has been registered with `TextMetrics`, and with none registered a label
reports an empty frame exactly as it did before, which is the same rule the
rest of the layer follows: an obvious nothing rather than a plausible wrong
number.

## Building

Once, to build the libraries (see `../Vendor/README.md`):

```
../Vendor/build.sh host
../Vendor/build.sh android
```

then

```
PKG_CONFIG_PATH=../Vendor/out/host/lib/pkgconfig swift test

PKG_CONFIG_PATH=../Vendor/out/aarch64-linux-android/lib/pkgconfig \
swift build --swift-sdk swift-6.4.2-RELEASE_android \
            --triple aarch64-unknown-linux-android23

PKG_CONFIG_PATH=../Vendor/out/x86_64-linux-android/lib/pkgconfig \
swift build --swift-sdk swift-6.4.2-RELEASE_android \
            --triple x86_64-unknown-linux-android23
```

The tests measure open-licensed fonts kept with them in `Tests/Fixtures/Fonts`
(Montserrat, a variable font with named instances, and KoHo Bold for Thai,
each with its licence), and the Mac's own Hiragino Sans GB and Apple SD Gothic
Neo for Chinese, Japanese and Korean. Run them with `--build-system native`
and `PKG_CONFIG_PATH` set to the absolute path of `Vendor/out/host/lib/pkgconfig`.

`TextProbe` is a small command line over the whole stack:

```
swift run TextProbe Tests/Fixtures/Fonts KoHo-Bold 32 สวัสดี
```

It exists mostly because a library build never links, so without an
executable nothing proves the Android archives resolve. Building it for both
ABIs does.

## The API

```swift
let engine = try TextEngine.install(fontsAt: "…/Fonts")   // once, at start-up

let font = FontKey(name: "SomeFont-Black", size: 32)
engine.fontMetrics(font)                  // ascent, descent, leading, cap and x height
engine.measure("Play", font: font)        // advance and ink box
engine.breakLines(text, font: font, maxWidth: 180)
engine.shape(text, font: font)            // [ShapedRun] of [ShapedGlyph]
engine.placedGlyphs(text, font: font)     // the same, rasterised into the atlas
```

`install` registers the `.ttf` files in that directory (or the ones it is
handed, in order: `files:`) and sets itself as `TextMetrics.provider`, which is what gives `SKLabelNode.contentFrame` and
`UIFont.lineHeight` real answers.

### Faces

A game asks for faces by PostScript name — `SomeFont-Black`, `-ExtraBold`,
`-SemiBold` — and a variable font's are **named instances of one file**, not
separate faces. Registering `SomeFont-Variable.ttf` makes all of them
available: the names come out of the font's own name table (each instance's
PostScript name), and asking for one sets the axis with
`FT_Set_Named_Instance` before the `hb_font_t` is made. A static face is
registered under its own name.

A face is made per size rather than resized, over bytes shared across every
size of a file, because an `FT_Face` carries its size as state — and a large
variable font can be tens of megabytes, so the bytes are worth sharing.
Sizes are kept to FreeType's own 1/64 pt grain, so animating a label's
scale cannot make a face per frame.

A face is also **stateful within one size**: `FT_Load_Glyph` writes into one
glyph slot, so two threads measuring different strings in the same font
overwrite each other's glyph. Everything that touches FreeType or HarfBuzz
goes through `FaceHandle.run`, and no raw `FT_Face` is handed out past it.
(This is not theoretical — it crashed the test run before the lock went in,
and the renderer will shape off the main thread too.)

### Shaping

`ShapedGlyph` is a glyph id, an advance, an offset and a **cluster**: the
UTF-8 byte offset of the character it came from. A string is itemised into
one run per script so HarfBuzz gets the right script tag, with digits, spaces
and punctuation joining whichever run they sit in.

Lines are shaped and measured as Core Text measures them on Apple, which
a game is laid out by: HarfBuzz shapes with its own OpenType functions
over the face at 64 units to the font unit (`FaceHandle.exactFont`, with the
named instance's variations), so advances come out in floating point rather
than FreeType's 1/64 point a glyph, and a glyph's ink is the box round its
outline's points, on the curve and off, rounded out to whole font units, as
Core Text bounds glyphs in a line (its image bounds and its glyph-path
bounds alike). `CoreTextParityTests` holds both to Core Text's on the same
files; what's left is a variable instance's advance deltas, which Core Text
keeps fractional and HarfBuzz rounds to whole font units (a hundredth of a
point a glyph). FreeType still rasterises, with hinting off
(`FT_LOAD_NO_HINTING`), which also keeps it proportional across sizes.

### Thai, which is the point of all this

Thai is the acceptance test, because it is where "rasterise each codepoint
with FreeType" is not merely imprecise but wrong — in four separate ways,
each with a test of its own against what `FT_Get_Char_Index` alone gives:

| | what the shaper does | naive |
|---|---|---|
| ลำ | SARA AM splits into NIKHAHIT + SARA AA, **reordered** so the mark comes first: 2 characters, **3 glyphs**, clusters `0, 3, 3` | 2 glyphs, neither of them the right one |
| ที่ | the tone mark takes its shifted form over a consonant with an ascender | the plain mark, colliding |
| ญุ | the consonant swaps for its **tail-less** form so the below-vowel fits | the tailed form, overlapping |
| สิทธิ์ | marks carry no advance and are nudged into place by GPOS | marks drawn at the pen |

### Line breaking

`LineBreak` is not UAX #14 and not ICU — an app need not ship ICU and the
Swift SDK for Android carries no line-break tables. It covers the three
cases the supported scripts need: after spaces and hyphens; between almost any two Chinese
or Japanese characters, held off by a small kinsoku set; and, for Thai, at
each grapheme-cluster boundary **except** straight after a leading vowel
(เ แ โ ใ ไ), which is written before the consonant it sounds after and must
never be stranded at a line end.

Thai is properly broken with a dictionary, and there isn't one here. The
fallback breaks mid-word, which is wrong and visible; it never breaks a
cluster, which would be wrong and unreadable. If Thai text starts looking
bad, a dictionary is the fix, and it goes behind this one function.

### The atlas

`GlyphAtlas` rasterises into pages of 8-bit coverage and hands back a rect
per glyph, keyed by face name, size and **glyph id** — the glyph id, not the
character, because that is what shaping produces and what a reordered Thai
form or a ligature actually is. Nothing here touches GL: a page is
`[UInt8]` plus a `dirty` rect, so the renderer uploads a sub-rectangle rather
than a whole page, and a `generation` it can check an upload against. Glyphs
are shelf-packed with a one-pixel transparent ring, so bilinear sampling at
an edge cannot pull a neighbour in.

`PlacedGlyph.frame` is the rectangle to draw in, in points, y up from the
baseline — the renderer should need nothing else.

## What the shim does with it

`SKLabelNode` breaks its text, places each line and reports its frame.
`DrawList.Label` carries that `TextLayout`, so the renderer draws what was
measured and the two cannot drift apart.

The renderer's end of it is `CoverageGeometry` (the quads, pure and
host-tested) and `GlyphPages` (the `R8` uploads, which honour a page's
dirty rect and generation). One thing it does that this package does not:
it shapes at the label's own point size and rasterises at the **screen's
density**, asking the atlas for a face at `size x scale` and dividing the
bitmaps back into points. Shaping and measuring stay at the size the node
measured itself at; only the pixels are denser.

A line is laid out as Apple's `SKLabelNode` lays it out, measured against
it on the Mac with the same font files (`SpriteKitLabelParityTests`):
SpriteKit draws the line into a box of whole points, the ink box rounded
out and padded by a point on every side, and that box is the frame and what
the alignment modes place, on both axes: `.left` puts its left edge on the
origin, `.center` its middle (rounded down), `.right` its right edge;
`.baseline` puts its bottom at the ink's rounded-down bottom, `.center` its
middle, `.top` and `.bottom` its edges. So a descender lifts a centred label
(a game undoes it with a line's glyph-path bounds to centre capitals), and
every frame is a point or two wider and taller than the ink, which a game's
pills and buttons are sized by. Every Black frame matches SpriteKit's to the
point; in the lighter instances 2% come out a point narrower, where a long
line's fractional advance deltas (above) tip its ink over a whole point.
Several lines (`numberOfLines` other than 1) keep a simpler layout.

## CoreText

A game's own text helpers may be pure CoreText — a `CTTypesetter` to wrap
lines, a `CTLine`'s glyph-path bounds to centre capitals,
`NSString.size(withAttributes:)` to measure — and all of that resolves on
Android unchanged:

- `SpriteKitShim/Typesetting.swift` does the work, over
  `TextMetrics.provider`, so it carries **no C dependency** and is
  host-testable.
- `SpriteKitShim/CoreTextCompat.swift` is the rename: `CTTypesetter`,
  `CTLine`, the four functions, `CTLineBoundsOptions`,
  `NSAttributedString.Key.font` and `NSString.size(withAttributes:)`. It is
  Android-only, because on Apple the real ones are right there.

That such a file *compiles* a build proves. That it *works* only a device
can: on Android its `NSAttributedString` is corelibs Foundation's holding a
Swift `UIFont`, and its typesetter is the shim reading that back out.
`CoreTextBreakParityTests` holds the typesetter to Core Text's on the Mac.

## Next

- **Colour and bitmap strikes** are rejected rather than drawn. Emoji in
  player-typed text would need them.
- **Sub-pixel positioning.** Glyphs are rasterised on the pixel grid and the
  shaper's fractional offsets ride on top. At usual UI sizes that is what
  SpriteKit does too; if small text looks uneven on a device, the fix is a
  few horizontal sub-pixel variants per glyph in the atlas.
