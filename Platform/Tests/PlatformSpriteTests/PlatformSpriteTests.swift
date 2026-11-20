import CoreText
import Foundation
import Testing
#if SPRITEKIT_SHIM
import SpriteKitShim
#else
import SpriteKit
#endif
@testable import PlatformSprite

@Suite(.serialized)
struct TextureCacheTests {
    @Test func cachesForgetsAndRunsHooks() {
        clearTextureCache()
        let first = txtr("Missing")
        #expect(txtr("Missing") === first)
        #expect(isTextureCached("Missing"))
        _ = txtr("Other")

        var asked: [String] = []
        SpriteArt.whenForgetting { pick in
            for name in ["Missing", "Other"] where pick(name) { asked.append(name) }
        }
        forgetTextures { $0 == "Missing" }
        #expect(!isTextureCached("Missing"))
        #expect(isTextureCached("Other"))
        #expect(asked == ["Missing"])
        #expect(txtr("Missing") !== first)
        clearTextureCache()
        #expect(!isTextureCached("Other"))
    }

    @Test func slicesByTheInjectedCaps() {
        let saved = SpriteArt.capInsets
        defer { SpriteArt.capInsets = saved }
        SpriteArt.capInsets = { name, _ in name == "Panel" ? UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10) : nil }
        let node = SKSpriteNode(texture: SKTexture(cgImage: RasterImage(width: 40, height: 20, pixels: [UInt8](repeating: 255, count: 40 * 20 * 4))))
        node.slice("Panel")
        #expect(node.centerRect == rect(0.25, 0.25, 0.5, 0.5))
        let plain = SKSpriteNode(texture: node.texture)
        plain.slice("Other")
        #expect(plain.centerRect == rect(0, 0, 1, 1))
    }

    @Test func gathersEachTextureOnce() {
        let texture = SKTexture(cgImage: RasterImage(width: 2, height: 2, pixels: [UInt8](repeating: 0, count: 16)))
        let root = SKNode()
        root.addChild(SKSpriteNode(texture: texture))
        let child = SKNode()
        child.addChild(SKSpriteNode(texture: texture))
        root.addChild(child)
        #expect(textures(in: root).count == 1)
    }
}

struct ColorTests {
    private func components(_ color: UIColor) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Int(($0 * 255).rounded()) }
    }

    @Test func readsHexNumbersAndStrings() {
        #expect(components(hex(0x336699)) == [0x33, 0x66, 0x99, 255])
        #expect(components(hex(0x336699, 0.5)) == [0x33, 0x66, 0x99, 128])
        #expect(UIColor(hex: "#336699").map(components) == [0x33, 0x66, 0x99, 255])
        #expect(UIColor(hex: " 0x336699 ").map(components) == [0x33, 0x66, 0x99, 255])
        #expect(UIColor(hex: "3366zz").map(components) == [0, 0x33, 0x66, 255])
        #expect(UIColor(hex: "zz") == nil)
        // As `Scanner.scanHexInt64`: a bare `0x` is the 0, and only ASCII digits count.
        #expect(UIColor(hex: "0x").map(components) == [0, 0, 0, 255])
        #expect(UIColor(hex: "\u{FF11}\u{FF12}") == nil)
        #expect(components(rgb(1, 2, 3)) == [1, 2, 3, 255])
    }

    @Test func blendsAndBrightens() {
        #expect(components(UIColor.white.blended(on: .black, alpha: 0.5)) == [128, 128, 128, 255])
        #expect(components(hex(0x804020).brightness(2)) == [255, 128, 64, 255])
        #expect(hex(0x336699, 0.5).cacheKey == "3366997f")
        #expect(hex(0x336699).toVec3().x == Float(0x33) / 255)
    }
}

struct SVGPathTests {
    @Test func drawsLinesAndClosesShapes() {
        let path = SVGPath.path("M2 3h10v5H2z")
        #expect(path.boundingBoxOfPath == rect(2, 3, 10, 5))
        #expect(path.pathElements.first == .move(pt(2, 3)))
        #expect(path.pathElements.last == .close)
    }

    @Test func readsImplicitAndRelativeCommands() {
        // Pairs after a move are line-tos; relative ones from the pen.
        let path = SVGPath.path("m1 1 4 0 0 4l-4,0z")
        #expect(path.pathElements == [.move(pt(1, 1)), .line(pt(5, 1)), .line(pt(5, 5)), .line(pt(1, 5)), .close])
    }

    @Test func readsPackedNumbersAndFlags() {
        // "1.5.5" is 1.5 then .5; arc flags run together.
        let packed = SVGPath.path("M1.5.5L3-1e1")
        #expect(packed.pathElements == [.move(pt(1.5, 0.5)), .line(pt(3, -10))])
        let arc = SVGPath.path("M0 0a5 5 0 105 5")
        if case let .curve(to, _, _)? = arc.pathElements.last {
            #expect(abs(to.x - 5) < 1e-9 && abs(to.y - 5) < 1e-9)
        } else {
            Issue.record("no arc")
        }
    }

    @Test func drawsArcsAsTheirCircles() {
        let circle = SVGPath.path(SVGPath.circle(12, 12, 10)).boundingBoxOfPath
        #expect(abs(circle.minX - 2) < 1e-6 && abs(circle.maxX - 22) < 1e-6)
        #expect(abs(circle.minY - 2) < 1e-6 && abs(circle.maxY - 22) < 1e-6)
        let rounded = SVGPath.path(SVGPath.rect(4, 10, 16, 10, rx: 3)).boundingBoxOfPath
        #expect(abs(rounded.minX - 4) < 1e-6 && abs(rounded.maxY - 20) < 1e-6)
    }

    @Test func reflectsSmoothControls() {
        let path = SVGPath.path("M0 0C0 10 10 10 10 0S20 -10 20 0")
        guard case let .curve(_, control1, _)? = path.pathElements.last else {
            Issue.record("no curve")
            return
        }
        #expect(control1 == pt(10, -10))
    }

    @Test func iconPartsCoverTheirStroke() {
        #expect(IconPart.fill("M2 2h20v20H2z").bounds == rect(2, 2, 20, 20))
        let stroke = IconPart.stroke("M4 12h16", width: 4).bounds
        #expect(abs(stroke.minX - 2) < 1e-6 && abs(stroke.maxX - 22) < 1e-6 && abs(stroke.height - 4) < 1e-6)
    }
}

struct TextTests {
    private let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 20, nil),
    ]

    @Test func wrapsAtSpacesAndTrims() {
        let lines = wrappedLines("one two three four five six", maxWidth: 100, attributes: attributes)
        #expect(lines.count > 1)
        #expect(lines.joined(separator: " ") == "one two three four five six")
        #expect(lines.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
    }

    @Test func wrapsTextWithoutSpaces() {
        let lines = wrappedLines("これは日本語の文章です。スペースがありません。", maxWidth: 80, attributes: attributes)
        #expect(lines.count > 1)
        #expect(lines.joined() == "これは日本語の文章です。スペースがありません。")
    }

    @Test func keepsShortTextOnOneLineAndDropsEmptyOnes() {
        #expect(wrappedLines("short", maxWidth: 500, attributes: attributes) == ["short"])
        #expect(wrappedLines("", maxWidth: 500, attributes: attributes).isEmpty)
        #expect(wrappedLines("a\n\nb", maxWidth: 500, attributes: attributes) == ["a", "b"])
    }

    @Test func registersAMissingFontOnceAsNotRegistered() {
        #expect(!FontRegistry.register("NoSuchFont"))
        #expect(!FontRegistry.register("NoSuchFont"))
        #expect(FontRegistry.postScriptNames(inFile: "NoSuchFont").isEmpty)
    }
}

struct DisplayCornerTests {
    @Test func looksUpScreensEitherWayRound() {
        #expect(DisplayCorners.pixelRadii(forScreen: sz(1206, 2622))! == (186, 186))
        #expect(DisplayCorners.pixelRadii(forScreen: sz(2622, 1206))! == (186, 186))
        #expect(DisplayCorners.pixelRadii(forScreen: sz(2622, 1206), eitherWay: false) == nil)
        #expect(DisplayCorners.pixelRadii(forScreen: sz(100, 200)) == nil)
    }

    @Test func turnsTheCornersWithTheScreen() {
        let duo = sz(1398, 2034)
        let upright = DisplayCorners.radii(forScreen: duo, nativeScale: 3, turn: .upright, hasHomeIndicator: true)
        #expect(upright == DisplayCorners.Radii(topLeft: 8, topRight: 59, bottomLeft: 8, bottomRight: 59))
        let homeRight = DisplayCorners.radii(forScreen: duo, nativeScale: 3, turn: .homeRight, hasHomeIndicator: true)
        #expect(homeRight == DisplayCorners.Radii(topLeft: 8, topRight: 8, bottomLeft: 59, bottomRight: 59))
        let homeLeft = DisplayCorners.radii(forScreen: duo, nativeScale: 3, turn: .homeLeft, hasHomeIndicator: true)
        #expect(homeLeft == DisplayCorners.Radii(topLeft: 59, topRight: 59, bottomLeft: 8, bottomRight: 8))
        #expect(homeLeft.at(side: -1, end: -1) == 8)
    }

    @Test func fallsBackForUnlistedPhones() {
        #expect(DisplayCorners.radii(forScreen: sz(1, 2), nativeScale: 3, turn: .upright, hasHomeIndicator: true) == DisplayCorners.Radii(all: 62))
        #expect(DisplayCorners.radii(forScreen: sz(1, 2), nativeScale: 3, turn: .upright, hasHomeIndicator: false) == DisplayCorners.Radii())
    }
}

@Suite(.serialized)
struct LocalizationTests {
    enum Language: String, LocalizationLanguage {
        case english = "en"
        case german = "de"
        case portugueseBrazil = "pt-BR"
    }

    private static let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalizationTests-\(UUID().uuidString)")
        let tables: [String: [String: String]] = [
            "Base.lproj/Localizable.strings": ["greeting": "Hello"],
            "Base.lproj/Content.strings": ["River": "River"],
            "de.lproj/Localizable.strings": ["greeting": "Hallo"],
            "de.lproj/Content.strings": ["River": "Fluss"],
            "pt-BR.lproj/Localizable.strings": ["greeting": "Olá"],
        ]
        for (path, strings) in tables {
            let url = folder.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = strings.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
            try? text.data(using: .utf8)?.write(to: url)
        }
        return folder
    }()

    private func localizer(saved: String? = nil, device: [String], onSave: @escaping (String) -> Void = { _ in }) -> Localizer<Language> {
        Localizer(
            development: .english,
            settingKey: "settings.language",
            didChange: Notification.Name("LocalizationTests.didChange"),
            bundle: Bundle(url: Self.folder)!,
            read: { saved },
            save: onSave,
            preferredLanguages: { device }
        )
    }

    @Test("Left to itself, it speaks the language the shell set (AppleLanguages)")
    func speaksTheShellsLanguages() {
        let saved = UserDefaults.standard.object(forKey: "AppleLanguages")
        defer { UserDefaults.standard.set(saved, forKey: "AppleLanguages") }
        UserDefaults.standard.set(["de-AT", "en"], forKey: "AppleLanguages")
        let localizer = Localizer<Language>(
            development: .english,
            settingKey: "settings.language",
            didChange: Notification.Name("LocalizationTests.didChange"),
            bundle: Bundle(url: Self.folder)!,
            read: { nil },
            save: { _ in }
        )
        #expect(localizer.current == .german)
    }

    @Test func speaksTheDevicesLanguageItShipsIn() {
        #expect(localizer(device: ["de-AT", "en"]).current == .german)
        #expect(localizer(device: ["pt-BR"]).current == .portugueseBrazil)
        #expect(localizer(device: ["fr-FR"]).current == .english)
        #expect(localizer(device: ["fr-FR"]).string("greeting", fallback: "?") == "Hello")
    }

    @Test func thePlayersPickWins() {
        let german = localizer(saved: "de", device: ["en-US"])
        #expect(german.current == .german)
        #expect(german.string("greeting", fallback: "?") == "Hallo")
        #expect(german.string("missing", fallback: "Fallback") == "Fallback")
        #expect(german.content("River") == "Fluss")
        #expect(localizer(saved: "pt-BR", device: []).content("Missing tip") == "Missing tip")
    }

    @Test func pickingSavesPostsAndRereads() {
        var saved: String?
        let localizer = Localizer<Language>(
            development: .english, settingKey: "language", didChange: Notification.Name("LocalizationTests.picked"),
            bundle: Bundle(url: Self.folder)!, read: { saved }, save: { saved = $0 }, preferredLanguages: { ["en"] }
        )
        #expect(localizer.current == .english)
        var posted = false
        let observer = NotificationCenter.default.addObserver(forName: localizer.didChange, object: nil, queue: nil) { _ in posted = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        localizer.select(.german)
        #expect(saved == "de")
        #expect(posted)
        #expect(localizer.string("greeting", fallback: "?") == "Hallo")
        saved = "pt-BR"
        #expect(localizer.current == .german)
        localizer.savedDataDidSync(["language"])
        #expect(localizer.current == .portugueseBrazil)
    }
}

struct MarkerAndGateTests {
    @Test func parsesStills() {
        let stills = Markers.parseStills("move 3@0.05;celebrate@0.7;win")
        #expect(stills.map(\.marker) == ["move 3", "celebrate", "win"])
        #expect(stills.map(\.delay) == [0.05, 0.7, 0])
    }

    @Test func holdsStillsAfterTheirMarkers() {
        let saved = (Markers.prints, Markers.holdStill)
        defer { (Markers.prints, Markers.holdStill) = saved; Markers.stills = [] }
        Markers.prints = true
        Markers.stills = Markers.parseStills("board@0.5;win@1")
        var held: [(Int, TimeInterval)] = []
        Markers.holdStill = { index, delay, _ in held.append((index, delay)) }
        Markers.note("win")
        Markers.note("win")
        #expect(held.count == 1 && held[0] == (2, 1))
    }

    @Test func defersUpdatesWhileABuildHoldsTheGate() async {
        var ran: [String] = []
        let built = offMainActor { () -> Int in
            BuildGate.unlessBuilding("light") { ran.append("first") }
            BuildGate.unlessBuilding("light") { ran.append("latest") }
            return 3
        }
        #expect(built == 3)
        #expect(ran.isEmpty)
        // The deferred update runs on the main queue once the build ends.
        for _ in 0..<50 where ran.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(ran == ["latest"])
        BuildGate.unlessBuilding("now") { ran.append("now") }
        #expect(ran == ["latest", "now"])
    }
}
