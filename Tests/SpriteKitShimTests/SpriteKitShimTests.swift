import Foundation
import Testing
@testable import SpriteKitShim

// The whole layer is testable with no device, window or GL context, because
// a frame is a value (DrawList) rather than a sequence of draw calls.

@Suite("Scene graph")
struct SceneGraphTests {
    @Test("A child's world transform composes through its parents")
    func worldTransform() {
        let root = SKNode()
        root.position = CGPoint(x: 100, y: 50)
        let child = SKNode()
        child.position = CGPoint(x: 10, y: 10)
        root.addChild(child)

        let placed = CGPoint.zero.applying(child.worldTransform)
        #expect(placed.x == 110)
        #expect(placed.y == 60)
    }

    @Test("Scale compounds down the tree")
    func scaleCompounds() {
        let root = SKNode()
        root.setScale(2)
        let child = SKNode()
        child.setScale(3)
        child.position = CGPoint(x: 1, y: 0)
        root.addChild(child)

        // The child's own offset is scaled by the parent, not by itself.
        let placed = CGPoint.zero.applying(child.worldTransform)
        #expect(abs(placed.x - 2) < 0.0001)
    }

    @Test("convert round-trips between two nodes")
    func convertRoundTrip() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let a = SKNode(); a.position = CGPoint(x: 10, y: 20)
        let b = SKNode(); b.position = CGPoint(x: -5, y: 7); b.zRotation = 0.3
        scene.addChild(a)
        scene.addChild(b)

        let point = CGPoint(x: 3, y: 4)
        let there = a.convert(point, to: b)
        let back = a.convert(there, from: b)
        #expect(abs(back.x - point.x) < 0.0001)
        #expect(abs(back.y - point.y) < 0.0001)
    }

    @Test("Alpha multiplies down the tree")
    func alphaMultiplies() {
        let root = SKNode(); root.alpha = 0.5
        let child = SKNode(); child.alpha = 0.5
        root.addChild(child)
        #expect(child.worldAlpha == 0.25)
    }

    @Test("removeFromParent detaches both ways")
    func removeFromParent() {
        let root = SKNode()
        let child = SKNode()
        root.addChild(child)
        #expect(root.children.count == 1)
        child.removeFromParent()
        #expect(root.children.isEmpty)
        #expect(child.parent == nil)
    }

    @Test("Accumulated frame spans the subtree")
    func accumulatedFrame() {
        let root = SKNode()
        let left = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        left.position = CGPoint(x: -20, y: 0)
        let right = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        right.position = CGPoint(x: 20, y: 0)
        root.addChild(left)
        root.addChild(right)

        let frame = root.calculateAccumulatedFrame()
        #expect(frame.minX == -25)
        #expect(frame.maxX == 25)
    }

    @Test("A hidden child counts in the accumulated frame and in contains(_:), as SpriteKit's")
    func hiddenCounts() {
        let root = SKNode()
        let shown = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        let hidden = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        hidden.position = CGPoint(x: 100, y: 0)
        hidden.isHidden = true
        root.addChild(shown)
        root.addChild(hidden)
        #expect(root.calculateAccumulatedFrame().maxX == 105)
        #expect(root.contains(CGPoint(x: 100, y: 0)))
    }
}

@Suite("Actions")
struct ActionTests {
    /// Drives a node's actions the way the renderer does.
    private func run(_ node: SKNode, seconds: TimeInterval, step: TimeInterval = 1.0 / 60) {
        var played: TimeInterval = 0
        while played < seconds {
            node.tickActions(step)
            played += step
        }
    }

    @Test("move(to:) lands exactly on its target")
    func moveTo() {
        let node = SKNode()
        node.run(.move(to: CGPoint(x: 100, y: 0), duration: 0.5))
        run(node, seconds: 0.6)
        #expect(abs(node.position.x - 100) < 0.0001)
    }

    @Test("A sequence runs its steps in order and finishes")
    func sequence() {
        let node = SKNode()
        var marks: [String] = []
        node.run(.sequence([
            .run { marks.append("one") },
            .wait(forDuration: 0.1),
            .run { marks.append("two") },
        ]))
        run(node, seconds: 0.3)
        #expect(marks == ["one", "two"])
        #expect(!node.hasActions)
    }

    @Test("customAction is handed elapsed seconds, not progress")
    func customActionElapsed() {
        let node = SKNode()
        var last: CGFloat = -1
        node.run(.customAction(withDuration: 1.0) { _, elapsed in last = elapsed })
        run(node, seconds: 0.5)
        // Halfway through a one-second action, SpriteKit reports ~0.5s.
        #expect(last > 0.4 && last < 0.6)
    }

    @Test("repeatForever keeps running and never reports done")
    func repeatForever() {
        let node = SKNode()
        var ticks = 0
        node.run(.repeatForever(.sequence([
            .run { ticks += 1 },
            .wait(forDuration: 0.1),
        ])))
        run(node, seconds: 0.55)
        #expect(ticks >= 4)
        #expect(node.hasActions)
    }

    @Test("A keyed action replaces the one already under that key")
    func keyedReplacement() {
        let node = SKNode()
        node.run(.fadeAlpha(to: 0, duration: 10), withKey: "fade")
        node.run(.fadeAlpha(to: 1, duration: 10), withKey: "fade")
        #expect(node.action(forKey: "fade") != nil)
        node.removeAction(forKey: "fade")
        #expect(node.action(forKey: "fade") == nil)
        #expect(!node.hasActions)
    }

    @Test("A group finishes only when its longest member does")
    func group() {
        let node = SKNode()
        node.run(.group([
            .fadeAlpha(to: 0, duration: 0.1),
            .move(to: CGPoint(x: 10, y: 0), duration: 0.4),
        ]))
        run(node, seconds: 0.2)
        #expect(node.hasActions)
        run(node, seconds: 0.4)
        #expect(!node.hasActions)
        #expect(abs(node.position.x - 10) < 0.0001)
    }

    @Test("Paused nodes do not advance")
    func paused() {
        let node = SKNode()
        node.isPaused = true
        node.run(.move(to: CGPoint(x: 100, y: 0), duration: 0.1))
        run(node, seconds: 0.3)
        #expect(node.position.x == 0)
    }

    @Test("A node's speed scales its own actions")
    func speed() {
        let fast = SKNode(); fast.speed = 2
        let slow = SKNode(); slow.speed = 1
        for node in [fast, slow] {
            node.run(.move(to: CGPoint(x: 100, y: 0), duration: 1.0))
        }
        run(fast, seconds: 0.5)
        run(slow, seconds: 0.5)
        #expect(fast.position.x > slow.position.x)
    }

    @Test("removeFromParent as an action detaches the node")
    func removeAction() {
        let root = SKNode()
        let child = SKNode()
        root.addChild(child)
        child.run(.sequence([.wait(forDuration: 0.05), .removeFromParent()]))
        run(root, seconds: 0.2)
        #expect(root.children.isEmpty)
    }
}

@Suite("Draw list")
struct DrawListTests {
    @Test("Sprites come out ordered by accumulated zPosition")
    func zOrder() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let back = SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1))
        back.zPosition = 1
        back.name = "back"
        let front = SKSpriteNode(color: .blue, size: CGSize(width: 1, height: 1))
        front.zPosition = 10
        front.name = "front"
        scene.addChild(front)
        scene.addChild(back)

        let list = DrawList(scene: scene)
        #expect(list.commands.count == 2)
        // Added front-first, but z decides: back must be drawn first.
        if case let .sprite(first) = list.commands[0] {
            #expect(first.color.red == 1)  // the red one
        } else {
            Issue.record("expected a sprite")
        }
    }

    /// The board's shape, and the bug the user saw: kerbs in one layer and
    /// tiles in another, both at z 0, each piece carrying its own row-based
    /// z. With `ignoresSiblingOrder` they interleave across the two layers;
    /// sorting each layer as a block drew every kerb under every tile.
    @Test("Descendants of sibling layers interleave by their own z")
    func siblingLayersInterleave() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let frame = SKNode()        // BoardFrameNode: the kerbs
        let grid = SKNode()         // the grid layer: the tiles
        scene.addChild(frame)
        scene.addChild(grid)

        // Each piece is told apart in the draw list by its red channel.
        func piece(_ id: CGFloat, z: CGFloat, in layer: SKNode) {
            let node = SKSpriteNode(
                color: SKColor(red: id / 10, green: 0, blue: 0, alpha: 1),
                size: CGSize(width: 1, height: 1)
            )
            node.zPosition = z
            layer.addChild(node)
        }
        // Row 0 at the back, row 1 nearer: z = row * 10 + depth, with
        // tile = 1 and frontKerb = 7, as BoardMetrics.z(row:_:) gives.
        piece(1, z: 7, in: frame)     // kerb, row 0
        piece(2, z: 17, in: frame)    // kerb, row 1
        piece(3, z: 1, in: grid)      // tile, row 0
        piece(4, z: 11, in: grid)     // tile, row 1

        let drawn = DrawList(scene: scene).commands.compactMap { command -> Int? in
            guard case let .sprite(s) = command else { return nil }
            return Int((s.color.red * 10).rounded())
        }
        // tile0, kerb0, tile1, kerb1 — not both kerbs then both tiles.
        #expect(drawn == [3, 1, 4, 2])
    }

    @Test("A front kerb draws over the tile of the row behind it")
    func frontKerbOverTileBehind() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let frame = SKNode(), grid = SKNode()
        scene.addChild(frame)
        scene.addChild(grid)
        let kerb = SKSpriteNode(color: .blue, size: CGSize(width: 1, height: 1))
        kerb.zPosition = 17          // row 1, frontKerb
        frame.addChild(kerb)         // added FIRST, in the layer drawn first
        let tile = SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1))
        tile.zPosition = 11          // row 1, tile
        grid.addChild(tile)

        let colours = DrawList(scene: scene).commands.compactMap { command -> CGFloat? in
            guard case let .sprite(s) = command else { return nil }
            return s.color.blue
        }
        // Tile (red, blue 0) first, kerb (blue 1) over it — although the
        // kerb's layer comes first in the tree.
        #expect(colours == [0, 1])
    }

    @Test("A parent's zPosition accumulates into its children's")
    func zAccumulates() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let low = SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1))
        low.zPosition = 100

        let group = SKNode()
        group.zPosition = 1000
        let high = SKSpriteNode(color: .blue, size: CGSize(width: 1, height: 1))
        high.zPosition = 1
        group.addChild(high)

        scene.addChild(group)
        scene.addChild(low)

        let list = DrawList(scene: scene)
        // The grouped sprite sits at 1001, above the loose one at 100.
        if case let .sprite(first) = list.commands[0] {
            #expect(first.color.red == 1)
        } else {
            Issue.record("expected a sprite")
        }
    }

    @Test("Hidden and fully transparent subtrees are skipped")
    func skipsInvisible() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let hidden = SKNode(); hidden.isHidden = true
        hidden.addChild(SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1)))
        let transparent = SKNode(); transparent.alpha = 0
        transparent.addChild(SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1)))
        scene.addChild(hidden)
        scene.addChild(transparent)
        #expect(DrawList(scene: scene).commands.isEmpty)
    }

    @Test("An effect node collapses its subtree into one command")
    func effectNesting() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let effect = SKEffectNode()
        effect.shader = SKShader(source: "void main() {}")
        for _ in 0 ..< 3 {
            effect.addChild(SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1)))
        }
        scene.addChild(effect)

        let list = DrawList(scene: scene)
        #expect(list.commands.count == 1)
        guard case let .effect(e) = list.commands[0] else {
            Issue.record("expected an effect")
            return
        }
        #expect(e.contents.commands.count == 3)
        #expect(e.shader != nil)
        #expect(list.spriteCount == 3)
    }

    @Test("A crop node carries its mask separately")
    func cropMask() {
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let crop = SKCropNode()
        crop.maskNode = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))
        crop.addChild(SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1)))
        scene.addChild(crop)

        guard case let .crop(c) = DrawList(scene: scene).commands[0] else {
            Issue.record("expected a crop")
            return
        }
        #expect(c.mask.commands.count == 1)
        #expect(c.contents.commands.count == 1)
    }

    @Test("Sprite anchor points place the quad")
    func anchorPoint() {
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        #expect(sprite.contentFrame.minX == -5)
        sprite.anchorPoint = .zero
        #expect(sprite.contentFrame.minX == 0)
    }

    @Test("A frame carries the node's shader and attributes through")
    func shaderPassthrough() {
        let scene = SKScene(size: CGSize(width: 10, height: 10))
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 1, height: 1))
        sprite.shader = SKShader(source: "x", uniforms: [SKUniform(name: "u_tint", float: 0.5)])
        sprite.setValue(SKAttributeValue(float: 2), forAttribute: "a_run")
        scene.addChild(sprite)

        guard case let .sprite(drawn) = DrawList(scene: scene).commands[0] else {
            Issue.record("expected a sprite")
            return
        }
        #expect(drawn.shader?.uniforms.first?.name == "u_tint")
        #expect(drawn.attributeValues["a_run"]?.floatValue == 2)
    }
}

@Suite("A frame of a scene")
struct FrameTests {
    /// A scene subclass, the way the game writes them.
    final class DemoScene: SKScene {
        private(set) var moved = false
        private(set) var updates = 0
        override func didMove(to view: SKView) { moved = true }
        override func update(_ currentTime: TimeInterval) { updates += 1 }
    }

    @Test("Presenting a scene calls didMove, and a tick drives update and actions")
    func sceneLifecycle() {
        let view = SKView(bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
        let scene = DemoScene(size: CGSize(width: 200, height: 100))
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        sprite.run(.move(to: CGPoint(x: 50, y: 0), duration: 0.5))
        scene.addChild(sprite)

        view.presentScene(scene)
        #expect(scene.moved)

        var list = DrawList()
        var time: TimeInterval = 0
        for _ in 0 ..< 40 {
            time += 1.0 / 60
            list = view.tick(currentTime: time, delta: 1.0 / 60)
        }
        #expect(scene.updates == 40)
        #expect(abs(sprite.position.x - 50) < 0.0001)
        // The scene's background over the view, then the sprite.
        #expect(list.commands.count == 2)
    }
}

// MARK: - Assets

@Suite("Asset index")
struct AssetIndexTests {
    /// A small index with the shapes that matter: a 9-sliced brick, a kerb
    /// with an anchor, a panel with content insets, a plain image and a
    /// whole page. The numbers are the real exporter's, from the staged
    /// index for Sunny Garden.
    static let json = """
    {
     "version": 2,
     "scale": 3,
     "pages": [
      { "file": "atlas-000.png", "width": 2048, "height": 2048 },
      { "file": "whole/BackdropReefSeabedSand.png", "width": 1254, "height": 1254, "repeats": true }
     ],
     "assets": {
      "BrickGarden1": { "page": 0, "rect": [1822, 246, 192, 240], "size": [64, 80], "caps": [67.2, 0, 4.48, 0] },
      "KerbGardenHorizontal": { "page": 0, "rect": [960, 1106, 217, 116], "size": [72.33333333333333, 38.666666666666664],
                                "caps": [0, 8.4939, 0, 8.4939], "anchor": [0.125, 0, 0.2283, 0] },
      "PanelWell": { "page": 0, "rect": [0, 0, 60, 60], "size": [20, 20], "caps": [4, 4, 4, 4], "content": [6, 6, 6, 6] },
      "ArrowTile": { "page": 0, "rect": [850, 1166, 360, 360], "size": [120, 120] },
      "BackdropReefSeabedSand": { "page": 1, "rect": [0, 0, 1254, 1254], "size": [418, 418] }
     }
    }
    """

    static func index() throws -> AssetIndex {
        try AssetIndex(json: Data(json.utf8), directory: URL(fileURLWithPath: "/art"))
    }

    @Test("Every asset resolves to its page, rect and size in points")
    func resolves() throws {
        let index = try Self.index()
        #expect(index.count == 5)
        #expect(index.scale == 3)

        let brick = try #require(index.entry("BrickGarden1"))
        #expect(brick.page == 0)
        #expect(brick.rect == CGRect(x: 1822, y: 246, width: 192, height: 240))
        #expect(brick.size == CGSize(width: 64, height: 80))

        #expect(index["Nothing"] == nil)
        #expect(index.names.first == "ArrowTile")
    }

    @Test("Cap insets, content insets and anchors come through as points")
    func insets() throws {
        let index = try Self.index()
        let brick = try #require(index.entry("BrickGarden1"))
        #expect(brick.capInsets == UIEdgeInsets(top: 67.2, left: 0, bottom: 4.48, right: 0))
        #expect(brick.contentInsets == nil)
        #expect(brick.anchor == nil)

        let kerb = try #require(index.entry("KerbGardenHorizontal"))
        #expect(kerb.capInsets == UIEdgeInsets(top: 0, left: 8.4939, bottom: 0, right: 8.4939))
        #expect(kerb.anchor == UIEdgeInsets(top: 0.125, left: 0, bottom: 0.2283, right: 0))

        let panel = try #require(index.entry("PanelWell"))
        #expect(panel.contentInsets == UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))

        #expect(try #require(index.entry("ArrowTile")).capInsets == nil)
    }

    @Test("The texture rect is the page slice, counted up from the bottom")
    func textureRect() throws {
        let index = try Self.index()
        let brick = try #require(index.entry("BrickGarden1"))
        #expect(abs(brick.textureRect.minX - 1822.0 / 2048) < 1e-12)
        // The index counts y down from the top: 2048 - (246 + 240).
        #expect(abs(brick.textureRect.minY - (2048.0 - 486) / 2048) < 1e-12)
        #expect(abs(brick.textureRect.width - 192.0 / 2048) < 1e-12)
        #expect(abs(brick.textureRect.height - 240.0 / 2048) < 1e-12)

        // A whole page's one image covers all of it.
        let sand = try #require(index.entry("BackdropReefSeabedSand"))
        #expect(sand.textureRect == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(index.pages[sand.page].repeats)
        #expect(index.pages[0].repeats == false)
    }

    @Test("A page's file sits beside the index")
    func pageURLs() throws {
        let index = try Self.index()
        #expect(index.url(ofPage: 0)?.path == "/art/atlas-000.png")
        #expect(index.url(ofPage: 1)?.path == "/art/whole/BackdropReefSeabedSand.png")
        #expect(index.url(ofPage: 2) == nil)
    }

    @Test("A newer index format, or a rect off its page, is refused")
    func refusals() throws {
        let newer = Self.json.replacingOccurrences(of: "\"version\": 2", with: "\"version\": 3")
        #expect(throws: AssetIndex.Failure.version(found: 3, expected: 2)) {
            try AssetIndex(json: Data(newer.utf8))
        }
        let off = Self.json.replacingOccurrences(of: "[1822, 246, 192, 240]", with: "[1900, 246, 192, 240]")
        #expect(throws: AssetIndex.Failure.self) { try AssetIndex(json: Data(off.utf8)) }
        let noPage = Self.json.replacingOccurrences(of: "\"page\": 1,", with: "\"page\": 9,")
        #expect(throws: AssetIndex.Failure.self) { try AssetIndex(json: Data(noPage.utf8)) }
    }
}

@Suite("Textures from the asset index", .serialized)
struct TextureAssetTests {
    /// `AssetIndex.shared` is process-wide, so each case puts it back.
    private func withIndex<T>(_ body: () throws -> T) throws -> T {
        let before = AssetIndex.shared
        AssetIndex.shared = try AssetIndexTests.index()
        defer { AssetIndex.shared = before }
        return try body()
    }

    @Test("A named texture reports the art's size in points")
    func namedSize() throws {
        try withIndex {
            #expect(SKTexture(imageNamed: "BrickGarden1").size() == CGSize(width: 64, height: 80))
            #expect(SKTexture(imageNamed: "ArrowTile").size() == CGSize(width: 120, height: 120))
            // SpriteKit reports zero for an image it cannot find; so does this.
            #expect(SKTexture(imageNamed: "NotThere").size() == .zero)
        }
    }

    @Test("A sprite built from a named texture takes that size")
    func spriteSize() throws {
        try withIndex {
            let node = SKSpriteNode(imageNamed: "BrickGarden1")
            #expect(node.size == CGSize(width: 64, height: 80))
            #expect(node.contentFrame == CGRect(x: -32, y: -40, width: 64, height: 80))
        }
    }

    @Test("A named texture carries its page and rect for the renderer")
    func pageAndRect() throws {
        try withIndex {
            let texture = SKTexture(imageNamed: "BrickGarden1")
            #expect(texture.page == 0)
            #expect(texture.asset?.rect == CGRect(x: 1822, y: 246, width: 192, height: 240))
            #expect(texture.textureRect == texture.asset?.textureRect)
            #expect(texture.root === texture)
        }
    }

    @Test("A slice of a packed texture lands inside its parent's rect")
    func sliceComposes() throws {
        try withIndex {
            let whole = SKTexture(imageNamed: "ArrowTile")
            let half = SKTexture(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), in: whole)
            #expect(half.size() == CGSize(width: 60, height: 120))
            #expect(half.root === whole)
            #expect(half.page == 0)
            let outer = whole.textureRect
            #expect(abs(half.textureRect.minX - (outer.minX + outer.width / 2)) < 1e-12)
            #expect(abs(half.textureRect.width - outer.width / 2) < 1e-12)
            #expect(half.textureRect.minY == outer.minY)
            #expect(half.textureRect.height == outer.height)
        }
    }

    @Test("With no index, a named texture behaves as it did before one existed")
    func withoutIndex() {
        let before = AssetIndex.shared
        AssetIndex.shared = nil
        defer { AssetIndex.shared = before }
        let texture = SKTexture(imageNamed: "BrickGarden1")
        #expect(texture.size() == .zero)
        #expect(texture.asset == nil)
        #expect(texture.page == nil)
        #expect(texture.textureRect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

@Suite("The staged export")
struct StagedAssetsTests {
    /// Android/Assets, written by `npm run art -- --android`. It is 101 MB
    /// and never committed, so this suite does nothing until it is there.
    static let staged = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SpriteKitShimTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Android
        .appendingPathComponent("Assets")

    static var exported: Bool {
        FileManager.default.fileExists(atPath: staged.appendingPathComponent(AssetIndex.fileName).path)
    }

    @Test("The real index loads, and every asset names a page file that is there",
          .enabled(if: StagedAssetsTests.exported, "run npm run art -- --android first"))
    func loadsTheRealThing() throws {
        let index = try AssetIndex(directory: Self.staged)
        #expect(index.scale == 3)
        #expect(index.count > 1_000)
        for page in index.pages.indices {
            let url = try #require(index.url(ofPage: page))
            #expect(FileManager.default.fileExists(atPath: url.path), "\(index.pages[page].file) is missing")
        }
        // A board brick, 9-sliced, and a kerb with its footprint anchor: the
        // two shapes the board's layout reads out of ArtSlices.
        let brick = try #require(index.entry("BrickGarden1"))
        #expect(brick.size == CGSize(width: 64, height: 80))
        #expect(brick.capInsets?.top == 67.2)
        #expect(try #require(index.entry("KerbGardenHorizontal")).anchor != nil)
        // Every tiling backdrop ground has a whole page it can repeat on.
        #expect(index.pages[try #require(index.entry("BackdropReefSeabedSand")).page].repeats)
    }

    @Test("Named textures resolve against it",
          .enabled(if: StagedAssetsTests.exported, "run npm run art -- --android first"))
    func texturesResolve() throws {
        let before = AssetIndex.shared
        AssetIndex.shared = try AssetIndex(directory: Self.staged)
        defer { AssetIndex.shared = before }
        for name in ["BrickGarden1", "ArrowTile", "CharacterGardenAOpen", "Spring", "Key"] {
            let size = SKTexture(imageNamed: name).size()
            #expect(size.width > 0 && size.height > 0, "\(name) resolved to \(size)")
        }
    }
}

// MARK: Raw pixels and encoded images are different sources

@Test("SKTexture(data:size:) is raw pixels, as SpriteKit defines it")
func dataInitIsRawPixels() {
    // `Starlight.noise` builds RGBA bytes and hands them over this way. If it
    // were taken for a PNG it would fail to decode, upload as one white pixel,
    // and the sky would draw flat with no nebula — which happened once.
    let texture = SKTexture(data: Data(repeating: 255, count: 4 * 4 * 4), size: CGSize(width: 4, height: 4))
    guard case .data = texture.source else {
        Issue.record("raw pixel data must stay `.data`"); return
    }
}

@Test("SKTexture(image:) carries the file's bytes as an encoded image")
func imageInitIsEncoded() throws {
    // The smallest thing UIImage accepts: a PNG signature and an IHDR saying
    // 3x2. It never decodes it; the renderer does, on upload.
    var png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13]
    png += Array("IHDR".utf8)
    png += [0, 0, 0, 3, 0, 0, 0, 2]
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("encoded-\(UUID().uuidString).png")
    try Data(png).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let image = try #require(UIImage(contentsOfFile: url.path))
    let texture = SKTexture(image: image)
    guard case .encoded = texture.source else {
        // Sharing `.data` with raw pixels means one of the two is always
        // misread: the rig pages as RGBA, or the sky's noise as a PNG.
        Issue.record("an image's bytes must be `.encoded`, not raw `.data`"); return
    }
    #expect(texture.size() == CGSize(width: 3, height: 2))
}
