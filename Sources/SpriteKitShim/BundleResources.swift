#if SPRITEKIT_SHIM
import Foundation

/// Where `Bundle.main.url(forResource:withExtension:)` finds a file on
/// Android.
///
/// The game asks the main bundle for eight resources: the rigs
/// (`RigGardenA.json`, `RigGardenA.png`, `RigFaces.*`), the music, and a
/// level's JSON. On Apple those sit in the app bundle. On Android there is
/// no app bundle: an asset lives inside the APK, which is a zip, so it has
/// no path on disk and `Data(contentsOf:)` cannot read it. corelibs
/// Foundation's `Bundle.main` looks beside the executable instead, which for
/// an SDL app is the system's `app_process`, so it finds nothing.
///
/// No file in `Source/` may change, so the call has to keep working as
/// written. It does, through an overload: Foundation's takes `String?` for
/// both arguments and every call site in the game passes a plain `String`,
/// so this one — which takes `String` — needs no optional promotion and is
/// the better match. Swift picks it. (`BundleResourcesTests` is there to
/// catch it if that ever stops being true; it would fail loudly rather than
/// quietly reading the wrong file.)
///
/// `provider` is installed by the app once, at start. With none installed,
/// or when it answers nil, the call falls through to Foundation's own,
/// so the shim behaves exactly as before on the host.
public enum BundleResources {
    /// Answers with a readable `file:` URL for a resource, or nil if it has
    /// none. Android's materialises the file out of the APK the first time
    /// it is asked for it.
    public nonisolated(unsafe) static var provider: ((_ name: String, _ extension: String) -> URL?)?

    public static func url(forResource name: String, withExtension ext: String) -> URL? {
        provider?(name, ext)
    }
}

public extension Bundle {
    /// Resolves through `BundleResources` first, then as Foundation would.
    func url(forResource name: String, withExtension ext: String) -> URL? {
        if let url = BundleResources.url(forResource: name, withExtension: ext) { return url }
        // Spelled with optionals so this picks Foundation's own overload
        // rather than calling itself.
        let name: String? = name, ext: String? = ext
        return url(forResource: name, withExtension: ext)
    }
}
#endif
