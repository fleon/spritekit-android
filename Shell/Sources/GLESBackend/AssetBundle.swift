import CAndroidShell
import Foundation
import GLESRenderer
import SpriteKitShim
import ShellCore
import TextShaping

/// Reads the packed art out of the APK.
///
/// On Android a file inside the APK is not a path on disk, so this goes
/// through SDL, whose `SDL_LoadFile` falls back to the asset manager. The
/// art is staged into the APK's `assets/art/` by the Gradle project, which
/// points a source set at `Android/Assets` — the gitignored output of
/// `npm run art -- --android`.
public enum AssetBundle {
    /// Where the art sits inside the APK. The Gradle project points its
    /// asset source set straight at `Android/Assets`, so the pages and the
    /// index are at the root of `assets/`.
    public static let root = ""

    private static func path(_ name: String) -> String {
        root.isEmpty ? name : "\(root)/\(name)"
    }

    /// Loads `index.json` and installs it as `AssetIndex.shared`.
    ///
    /// Returns nil, having logged why, if the art is not packaged: the app
    /// then runs with every texture resolving to the white placeholder,
    /// which draws tinted rectangles instead of art — visibly wrong rather
    /// than a blank screen.
    @discardableResult
    public static func installIndex() -> AssetIndex? {
        guard let data = load(path(AssetIndex.fileName)) else {
            Log.error("no \(AssetIndex.fileName) in the APK — run npm run art -- --android and rebuild")
            return nil
        }
        do {
            let index = try AssetIndex(json: data)
            AssetIndex.shared = index
            Log.info("asset index: \(index.count) assets on \(index.pages.count) pages at \(index.scale)x")
            return index
        } catch {
            Log.error("asset index would not load: \(error)")
            return nil
        }
    }

    /// Where the fonts are staged inside the APK, by the Gradle project's
    /// `stageFonts` task.
    public static let fontsRoot = "fonts"

    /// Registers the game's faces with the text stack and makes it the
    /// layer's text provider.
    ///
    /// Until this runs every label reports a zero frame, on purpose — the
    /// shim's rule is an obvious nothing rather than a plausible wrong
    /// number — so nothing draws any text before it.
    ///
    /// The fonts are read out of the APK rather than extracted: an asset is
    /// a member of a zip, not a path, and Chiron is 50 MB, so extracting
    /// would put a second copy on disk for no gain. `ttf` is in the Gradle
    /// project's `noCompress` list, so this is a read out of the mapped APK
    /// rather than an inflate.
    @discardableResult
    public static func installFonts() -> Bool {
        var loaded: [(name: String, data: Data)] = []
        for name in TextEngine.fontFileNames {
            guard let data = load(path("\(fontsRoot)/\(name).ttf")) else {
                Log.error("no \(name).ttf in the APK — text will not draw")
                continue
            }
            loaded.append((name, data))
        }
        guard !loaded.isEmpty else { return false }

        do {
            let engine = try TextEngine.install(fonts: loaded)
            Log.info("fonts: \(loaded.map(\.name).joined(separator: ", "))")
            Log.info("faces: \(engine.library.registeredNames.joined(separator: ", "))")
            return true
        } catch {
            Log.error("the fonts would not register: \(error)")
            return false
        }
    }

    /// Pixels for one packed page, decoded to RGBA8.
    public static func page(_ number: Int) -> (width: Int, height: Int, pixels: Data)? {
        guard let index = AssetIndex.shared, index.pages.indices.contains(number) else { return nil }
        let page = index.pages[number]
        guard let data = load(path(page.file)) else {
            Log.error("page \(page.file) is not in the APK")
            return nil
        }
        do {
            let image = try PNGDecoder.decode(data)
            Log.info("uploading page \(number) (\(page.file)) \(image.width)x\(image.height)")
            return (image.width, image.height, image.pixels)
        } catch {
            Log.error("page \(page.file) would not decode: \(error)")
            return nil
        }
    }

    /// Reads a whole file from the APK's assets.
    public static func load(_ path: String) -> Data? {
        var size = 0
        guard let raw = SDL_LoadFile(path, &size), size > 0 else { return nil }
        defer { SDL_free(raw) }
        return Data(bytes: raw, count: size)
    }
}
