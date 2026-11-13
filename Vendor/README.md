# Vendor

FreeType and HarfBuzz, built from source for the host and for both Android
ABIs. Nothing binary is committed: `build.sh` fetches the pinned tarballs,
checks their hashes and builds into `out/`, which is gitignored along with
`src/`.

| | version | from |
|---|---|---|
| FreeType | **2.15.0** | `download.savannah.gnu.org/releases/freetype` |
| HarfBuzz | **15.1.0** | `github.com/harfbuzz/harfbuzz/releases` |

The versions and their SHA-256 hashes are in `versions.sh`, which is the one
place to change to move either of them.

## Building

```
./build.sh host        # the Mac — what `swift test` in ../Text needs
./build.sh android     # arm64-v8a and x86_64, API 23
./build.sh all         # both (the default)
```

Android needs `ANDROID_NDK_HOME`, or the NDK at
`~/Library/Android/android-ndk-r30`. Each target lands in
`out/<target>/{include,lib}` with a `lib/pkgconfig/switchlings-text.pc` that
SwiftPM's `CTextShaping` system-library target resolves:

```
out/host/
out/aarch64-linux-android/
out/x86_64-linux-android/
```

## What is built, and what is left out

Both are static, position-independent, release.

FreeType comes first and **without** HarfBuzz — its optional HarfBuzz
dependency only improves autohinting, and taking it would make the two
circular. Then HarfBuzz is built against that FreeType with
`HB_HAVE_FREETYPE=ON`, so `hb-ft.h` can hang a `hb_font_t` off an `FT_Face`.
That is what keeps shaping and rasterising honest: one face, one set of
advances, so a line cannot be measured with numbers it is not drawn with.

Everything optional is off:

- FreeType: zlib, bzip2, PNG, Brotli. The game ships plain TrueType, and each
  would be another library to cross-compile. Variable fonts — Chiron GoRound
  TC is one — need none of them.
- FreeType: **HVF**. 2.15 picks up Apple's Hierarchical Variable Font library
  when it finds the SDK and then needs `-lhvf` to link. Android has no such
  thing, so it is off everywhere and the Mac builds the same FreeType the
  device gets.
- HarfBuzz: subsetting, the utilities, GLib, ICU, GObject, Graphite2, and
  **CoreText**. CoreText is forced off so a test passing on the Mac cannot
  have gone through a shaper the device never runs.

The host build is pinned to `CMAKE_OSX_DEPLOYMENT_TARGET=14.0`, which is what
SwiftPM links test bundles against.

## Linking

The Android archives pull in the NDK's static libc++, so a binary linking
them needs no `libc++_shared.so` in the APK — `../Text`'s `TextProbe`
executable links for both ABIs and asks only for the Swift runtime, libm,
libdl and libc.
