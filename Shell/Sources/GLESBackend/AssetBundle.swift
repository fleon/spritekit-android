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
/// art is staged into the APK's assets by the game's Gradle project, which
/// points a source set at the game's packed art (`AssetIndex`).
public enum AssetBundle {
    /// Where the art sits inside the APK. A Gradle project that points its
    /// asset source set straight at the packed art puts the pages and the
    /// index at the root of `assets/`.
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
            Log.error("no \(AssetIndex.fileName) in the APK — pack the game's art and rebuild")
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

    /// The font files `installFonts` reads from `fontsRoot`, without their
    /// `.ttf`, in the order to register them: the first is what a label with
    /// no `fontName` falls back to. The game names them
    /// (`Shell.start(fonts:)`); with none, no text draws.
    nonisolated(unsafe) public static var fontFiles: [String] = []

    /// Registers the game's faces with the text stack and makes it the
    /// layer's text provider.
    ///
    /// Until this runs every label reports a zero frame, on purpose — the
    /// shim's rule is an obvious nothing rather than a plausible wrong
    /// number — so nothing draws any text before it.
    ///
    /// The fonts are read out of the APK rather than extracted: an asset is
    /// a member of a zip, not a path, and a large variable font can be tens
    /// of megabytes, so extracting would put a second copy on disk for no
    /// gain. `ttf` is in the Gradle
    /// project's `noCompress` list, so this is a read out of the mapped APK
    /// rather than an inflate.
    @discardableResult
    public static func installFonts() -> Bool {
        var loaded: [(name: String, data: Data)] = []
        for file in stagedFontFiles() {
            guard let data = load(path("\(fontsRoot)/\(file)")) else {
                Log.error("no \(file) in the APK — its text will not draw")
                continue
            }
            loaded.append(((file as NSString).deletingPathExtension, data))
        }

        do {
            let engine = try TextEngine.install(fonts: loaded)
            // The device's own face, for `UIFont.systemFont`.
            let system = engine.registerSystemFonts()
            Log.info("fonts: \(loaded.map(\.name).joined(separator: ", ")); system: \(system.count) faces")
            Log.info("faces: \(engine.library.registeredNames.joined(separator: ", "))")
            return !loaded.isEmpty || !system.isEmpty
        } catch {
            Log.error("the fonts would not register: \(error)")
            return false
        }
    }

    /// Every font file the game staged in the APK's `fonts/`, as an iOS app
    /// lists its own in `UIAppFonts`. The ones the game named (`fontFiles`)
    /// come first, in its order, since the first face registered is what a
    /// label with no font name draws in; the rest follow by name.
    static func stagedFontFiles() -> [String] {
        final class Listing { var files: [String] = [] }
        let listing = Listing()
        let found = SDL_EnumerateDirectory(path(fontsRoot), { userdata, _, name in
            guard let userdata, let name else { return SDL_ENUM_CONTINUE }
            let file = String(cString: name)
            let ext = (file as NSString).pathExtension.lowercased()
            if ext == "ttf" || ext == "otf" {
                Unmanaged<Listing>.fromOpaque(userdata).takeUnretainedValue().files.append(file)
            }
            return SDL_ENUM_CONTINUE
        }, Unmanaged.passUnretained(listing).toOpaque())
        guard found else {
            Log.error("could not list \(fontsRoot)/ in the APK: \(String(cString: SDL_GetError()))")
            return fontFiles.map { "\($0).ttf" }
        }
        let first = fontFiles.compactMap { name in
            listing.files.first { ($0 as NSString).deletingPathExtension == name }
        }
        return first + listing.files.filter { !first.contains($0) }.sorted()
    }

    /// One packed page: its ASTC levels as they ship (a `.ktx`, read as it
    /// is), or a PNG's pixels decoded to RGBA8, straight, top row first.
    public static func page(_ number: Int) -> PageImage? {
        guard let index = AssetIndex.shared, index.pages.indices.contains(number) else { return nil }
        let page = index.pages[number]
        guard let data = load(path(page.file)) else {
            Log.error("page \(page.file) is not in the APK")
            return nil
        }
        do {
            if page.compressed {
                let compressed = try CompressedPage(ktx: data)
                Log.info("read page \(number) (\(page.file)) \(compressed.width)x\(compressed.height) ASTC \(compressed.blockWidth)x\(compressed.blockHeight), \(compressed.levels.count) levels")
                return PageImage(compressed)
            }
            let image = try PNGDecoder.decode(data)
            Log.info("uploading page \(number) (\(page.file)) \(image.width)x\(image.height)")
            return PageImage(width: image.width, height: image.height, pixels: image.pixels)
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
