import Foundation
import SpriteKitShim

// Stand-ins for the two game helpers this slice reaches outside itself for.
// Everything else in this target is the real, unmodified source file,
// symlinked from Source/ — the point of the target is that those compile
// against the shim without being touched.
//
// Both of these are text infrastructure. The engine behind them is real
// (Android/Text: HarfBuzz and FreeType, with the glyph atlas) and so is the
// CoreText surface above them, which is why TextHelpers.swift compiles here
// unchanged. These two stay stubs because they need the language pick, which
// belongs to the localisation ring, and because wiring them would make this
// package need Text — and with it a cmake run — for everyone building the
// game's sources. Android/Probe is where the two meet.

enum FontRegistry {
    /// Real one registers the bundled Chiron GoRound TC faces with CoreText.
    /// On Android it becomes `TextEngine.install(fontsAt:)`, which registers
    /// the same files from Assets/Fonts — including the variable font's
    /// named instances, which is how "ChironGoRoundTC-Black" resolves.
    static func registerChiron() {}
    /// The same for KoHo, Thai's face (`AppLanguage.scriptFontName`); the
    /// shell registers it with the rest.
    static func registerKoHo() {}
}

// `Localization` stood in here until the share film ring: the real
// `Localization.swift` and `LocalizedString.swift` are compiled now. With no
// `.lproj` in the APK yet, `Bundle.main` answers every string with its
// English fallback, which is the localisation ring's to change.

// `sprite`, `tinted` and `sliced` used to stand in here. The real
// SpriteHelpers.swift is compiled now (the gameplay ring); what it reaches
// for beyond itself is in BoardStubs.swift.
