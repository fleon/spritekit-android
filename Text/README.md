# Text

Shaping, metrics, rasterising and a glyph atlas: HarfBuzz and FreeType under
a Swift API, and the `TextProvider` the shim asks for its label layout.

A package of its own, like `Compat`, and for the same kind of reason. It is
the only part of the port with C dependencies, and putting them in
`../Package.swift` would make `swift build` there need a cmake run first —
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

`TextProbe` is a small command line over the whole stack:

```
swift run TextProbe ../../Assets/Fonts KoHo-Bold 32 สวัสดี
```

It exists mostly because a library build never links, so without an
executable nothing proves the Android archives resolve. Building it for both
ABIs does.

## The API

```swift
let engine = try TextEngine.install(fontsAt: "…/Assets/Fonts")   // once, at start-up

let font = FontKey(name: "ChironGoRoundTC-Black", size: 32)
engine.fontMetrics(font)                  // ascent, descent, leading, cap and x height
engine.measure("Play", font: font)        // advance and ink box
engine.breakLines(text, font: font, maxWidth: 180)
engine.shape(text, font: font)            // [ShapedRun] of [ShapedGlyph]
engine.placedGlyphs(text, font: font)     // the same, rasterised into the atlas
```

`install` registers the three files in `Assets/Fonts` and sets itself as
`TextMetrics.provider`, which is what gives `SKLabelNode.contentFrame` and
`UIFont.lineHeight` real answers.

### Faces

The game asks for faces by the names in `GeometryHelpers.swift` —
`ChironGoRoundTC-Black`, `-ExtraBold`, `-SemiBold` — and those are **named
instances of one variable file**, not three faces. Registering
`ChironGoRoundTC-Variable.ttf` makes all of them available: the names come
out of the font's own name table (each instance's PostScript name), and
asking for one sets the axis with `FT_Set_Named_Instance` before the
`hb_font_t` is made. `KoHo-Bold` is an ordinary static face.

A face is made per size rather than resized, over bytes shared across every
size of a file, because an `FT_Face` carries its size as state — and Chiron
is 50 MB, so the bytes are worth sharing. Sizes are kept to FreeType's own
1/64 pt grain, so animating a label's scale cannot make a face per frame.

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

Hinting is off everywhere (`FT_LOAD_NO_HINTING`), both for shaping and for
rasterising. HarfBuzz takes its advances from FreeType, so the two must load
glyphs the same way or a line would be measured with numbers it is not drawn
with. It also keeps measurement proportional across sizes, which hinting is
not.

### Thai, which is the point of all this

Thai is the acceptance test, because it is where "rasterise each codepoint
with FreeType" is not merely imprecise but wrong — in four separate ways,
each with a test of its own against what `FT_Get_Char_Index` alone gives:

| | what the shaper does | naive |
|---|---|---|
| ลำ | SARA AM splits into NIKHAHIT + SARA AA, **reordered** so the mark comes first: 2 characters, **3 glyphs**, clusters `0, 3, 3` | 2 glyphs, neither of them the right one |
| ที่ | the tone mark takes its shifted form over a consonant with an ascender | the plain mark, colliding |
| ญุ | the consonant swaps for its **tail-less** form so the below-vowel fits | the tailed form, overlapping |
| สวิตช์ลิง | marks carry no advance and are nudged into place by GPOS | marks drawn at the pen |

### Line breaking

`LineBreak` is not UAX #14 and not ICU — the game ships no ICU and the Swift
SDK for Android carries no line-break tables. It covers the three cases the
19 languages need: after spaces and hyphens; between almost any two Chinese
or Japanese characters, held off by a small kinsoku set; and, for Thai, at
each grapheme-cluster boundary **except** straight after a leading vowel
(เ แ โ ใ ไ), which is written before the consonant it sounds after and must
never be stranded at a line end.

Thai is properly broken with a dictionary, and there isn't one here. The
fallback breaks mid-word, which is wrong and visible; it never breaks a
cluster, which would be wrong and unreadable. If the Thai copy starts looking
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

`SKLabelNode` breaks its text, places each line and reports the ink box.
`DrawList.Label` carries that `TextLayout`, so the renderer draws what was
measured and the two cannot drift apart.

The renderer's end of it is `CoverageGeometry` (the quads, pure and
host-tested) and `GlyphPages` (the `R8` uploads, which honour a page's
dirty rect and generation). One thing it does that this package does not:
it shapes at the label's own point size and rasterises at the **screen's
density**, asking the atlas for a face at `size x scale` and dividing the
bitmaps back into points. Shaping and measuring stay at the size the node
measured itself at; only the pixels are denser.

The alignment modes follow SpriteKit, which is not the obvious reading of
them. **Vertical alignment works on the ink box, not the typographic one**,
so `.center` centres the glyphs drawn and a descender lifts the whole label.
The game relies on exactly that: `TextHelpers.capitalsOffset` exists only to
undo it for buttons, so matching it matters more than being tidy. Horizontal
alignment works on the pen's advance, so a centred line is centred on its
advance and its ink box may sit a fraction off centre, as on Apple.

## CoreText, and `TextHelpers.swift`

`Source/Utils/TextHelpers.swift` compiles on Android **unchanged** and runs
there. It is pure CoreText — `wrappedLines` runs a `CTTypesetter`,
`capitalsOffset` reads a `CTLine`'s glyph-path bounds, `TextBlockNode`
measures each line with `NSString.size(withAttributes:)` — and all of that
now resolves:

- `SpriteKitShim/Typesetting.swift` does the work, over
  `TextMetrics.provider`, so it carries **no C dependency** and is
  host-testable.
- `SpriteKitShim/CoreTextCompat.swift` is the rename: `CTTypesetter`,
  `CTLine`, the four functions, `CTLineBoundsOptions`,
  `NSAttributedString.Key.font` and `NSString.size(withAttributes:)`. It is
  Android-only, because on Apple the real ones are right there.

That the file *compiles* a build proves. That it *works* it cannot: on
Android its `NSAttributedString` is corelibs Foundation's holding a Swift
`UIFont`, and its typesetter is the shim reading that back out. `../Probe`
runs the real `wrappedLines`, `capitalsOffset` and `TextBlockNode` on a
device and checks what they produce.

## Next

- **`Compat/Sources/GameCompat/Stubs.swift`** still stubs `FontRegistry` and
  `Localization.scriptFontName` / `lineHeightRatio`. All three become one
  call to `TextEngine.install` plus the language pick, and land with the
  localisation ring.
- **Colour and bitmap strikes** are rejected rather than drawn. The game has
  no emoji in its own text, but a player-typed level name might.
- **Sub-pixel positioning.** Glyphs are rasterised on the pixel grid and the
  shaper's fractional offsets ride on top. At the sizes the game uses that is
  what SpriteKit does too; if small text looks uneven on a device, the fix is
  a few horizontal sub-pixel variants per glyph in the atlas.
