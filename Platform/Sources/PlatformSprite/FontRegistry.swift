import Foundation
#if canImport(Darwin)
import CoreText
#endif
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
#endif

/// Registers a game's own font files with CoreText, each once a process
/// (registering a file twice fails, and logs on Apple). The file names are
/// the game's; on Android `Bundle.main` finds them in the APK.
public nonisolated enum FontRegistry {
    private static let state = Locked<(registered: [String: Bool], faces: [String: [String]])>(([:], [:]))

    /// Registers the bundle's `name.ext`, the first time it's asked for:
    /// whether it registered.
    @discardableResult
    public static func register(_ name: String, withExtension ext: String = "ttf") -> Bool {
        let key = "\(name).\(ext)"
        return state.withLock { state in
            if let done = state.registered[key] { return done }
            var done = false
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                var error: Unmanaged<CFError>?
                done = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            }
            state.registered[key] = done
            return done
        }
    }

    /// Registers each of the bundle's `fontFiles`, `ext` files by name.
    public static func register(fontFiles: [String], withExtension ext: String = "ttf") {
        for name in fontFiles { register(name, withExtension: ext) }
    }

    /// The PostScript names of the faces in the bundle's `name.ext`,
    /// registering it first: what `UIFont(name:size:)` takes for each.
    public static func postScriptNames(inFile name: String, withExtension ext: String = "ttf") -> [String] {
        register(name, withExtension: ext)
        let key = "\(name).\(ext)"
        return state.withLock { state in
            if let cached = state.faces[key] { return cached }
            var names: [String] = []
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                names = descriptors.map { CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor($0, 0, nil)) as String }
            }
            state.faces[key] = names
            return names
        }
    }
}
