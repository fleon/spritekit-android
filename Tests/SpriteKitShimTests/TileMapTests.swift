import Foundation
import Testing
@testable import SpriteKitShim

// SKTileMapNode, as SpriteKit draws and answers it on a Mac (macOS 27,
// SKView.texture(from:) read back).

@Suite("Tile map")
struct TileMapTests {
    private func texture(_ width: CGFloat = 4, _ height: CGFloat = 4) -> SKTexture {
        SKTexture(color: .red, size: CGSize(width: width, height: height))
    }

    private func sprites(_ list: DrawList) -> [DrawList.Sprite] {
        list.commands.compactMap { if case let .sprite(sprite) = $0 { return sprite } else { return nil } }
    }

    /// The placed quad's corners, in the scene's space.
    private func corners(_ sprite: DrawList.Sprite) -> CGRect {
        let rect = CGRect(x: -sprite.anchorPoint.x * sprite.size.width, y: -sprite.anchorPoint.y * sprite.size.height,
                          width: sprite.size.width, height: sprite.size.height)
        return rect.applying(sprite.transform)
    }

    @Test("Definitions, groups and sets default as on Apple")
    func defaults() {
        let definition = SKTileDefinition(texture: texture(), size: CGSize(width: 10, height: 10))
        #expect(definition.size == CGSize(width: 10, height: 10))
        #expect(definition.rotation == .rotation0)
        #expect(definition.placementWeight == 1)
        #expect(definition.timePerFrame == 0)
        #expect(definition.textures.count == 1)
        #expect(SKTileDefinition(texture: texture(4, 6)).size == CGSize(width: 4, height: 6))

        let group = SKTileGroup(tileDefinition: definition)
        #expect(group.rules.count == 1)
        #expect(group.rules[0].adjacency.rawValue == 255)
        #expect(group.rules[0].tileDefinitions.count == 1)
        #expect(group.name == nil)
        #expect(SKTileGroup.empty().rules.isEmpty)

        let set = SKTileSet(tileGroups: [SKTileGroup(tileDefinition: SKTileDefinition(texture: texture(4, 4))), group],
                            tileSetType: .grid)
        #expect(set.type == .grid)
        #expect(set.defaultTileSize == CGSize(width: 4, height: 4))
        #expect(set.defaultTileGroup == nil)
        #expect(SKTileSet(tileGroups: [group], tileSetType: .isometric).type.rawValue == 1)
    }

    @Test("Size, frame and cells")
    func geometry() {
        let group = SKTileGroup(tileDefinition: SKTileDefinition(texture: texture(), size: CGSize(width: 10, height: 10)))
        let map = SKTileMapNode(tileSet: SKTileSet(tileGroups: [group], tileSetType: .grid),
                                columns: 3, rows: 2, tileSize: CGSize(width: 20, height: 30))
        #expect(map.anchorPoint == CGPoint(x: 0.5, y: 0.5))
        #expect(map.mapSize == CGSize(width: 60, height: 60))
        #expect(map.frame == CGRect(x: -30, y: -30, width: 60, height: 60))
        #expect(map.calculateAccumulatedFrame() == CGRect(x: -30, y: -30, width: 60, height: 60))
        #expect(map.colorBlendFactor == 0)
        #expect(map.blendMode == .alpha)
        #expect(map.enableAutomapping)
        #expect(map.children.isEmpty)
        #expect(map.tileGroup(atColumn: 0, row: 0) == nil)

        map.fill(with: group)
        #expect(map.tileGroup(atColumn: 0, row: 0) === group)
        #expect(map.tileDefinition(atColumn: 2, row: 1) === group.rules[0].tileDefinitions[0])
        #expect(map.children.isEmpty)
        #expect(map.tileGroup(atColumn: 9, row: 9) == nil)

        #expect(map.centerOfTile(atColumn: 0, row: 0) == CGPoint(x: -20, y: -15))
        #expect(map.centerOfTile(atColumn: 2, row: 1) == CGPoint(x: 20, y: 15))

        // Clamped at 0, not at the far edge.
        let cases: [(CGPoint, Int, Int)] = [
            (CGPoint(x: -30, y: -30), 0, 0), (CGPoint(x: -10.1, y: 0), 0, 1),
            (CGPoint(x: 29.9, y: 29.9), 2, 1), (CGPoint(x: 31, y: 31), 3, 2),
            (CGPoint(x: -31, y: -31), 0, 0), (CGPoint(x: 100, y: 100), 6, 4),
            (CGPoint(x: -60, y: -75), 0, 0),
        ]
        for (point, column, row) in cases {
            #expect(map.tileColumnIndex(fromPosition: point) == column)
            #expect(map.tileRowIndex(fromPosition: point) == row)
        }

        map.anchorPoint = .zero
        #expect(map.frame == CGRect(x: 0, y: 0, width: 60, height: 60))
        #expect(map.centerOfTile(atColumn: 0, row: 0) == CGPoint(x: 10, y: 15))
        map.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        map.position = CGPoint(x: 7, y: 9)
        map.xScale = 2
        #expect(map.frame == CGRect(x: -53, y: -21, width: 120, height: 60))

        map.setTileGroup(nil, forColumn: 1, row: 1)
        #expect(map.tileGroup(atColumn: 1, row: 1) == nil)
        #expect(map.tileDefinition(atColumn: 1, row: 1) == nil)

        let filled = SKTileMapNode(tileSet: map.tileSet, columns: 2, rows: 2,
                                   tileSize: CGSize(width: 10, height: 10), fillWith: group)
        #expect(filled.tileGroup(atColumn: 1, row: 1) === group)
    }

    @Test("A definition draws at its own size from its cell's bottom-left, tinted as a sprite")
    func drawing() {
        let definition = SKTileDefinition(texture: texture(), size: CGSize(width: 10, height: 10))
        let group = SKTileGroup(tileDefinition: definition)
        let map = SKTileMapNode(tileSet: SKTileSet(tileGroups: [group], tileSetType: .grid),
                                columns: 3, rows: 2, tileSize: CGSize(width: 20, height: 30))
        map.fill(with: group)
        map.color = .green
        map.colorBlendFactor = 1
        let scene = SKScene(size: CGSize(width: 60, height: 60))
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        scene.addChild(map)

        let drawn = sprites(DrawList(scene: scene))
        #expect(drawn.count == 6)
        let rects = Set(drawn.map { corners($0) }.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" })
        // In the scene's own space, whose origin its anchor point puts mid-view.
        let origin = CGPoint.zero
        var expected = Set<String>()
        for row in 0 ..< 2 {
            for column in 0 ..< 3 {
                expected.insert("\(Int(origin.x) - 30 + column * 20),\(Int(origin.y) - 30 + row * 30),10,10")
            }
        }
        #expect(rects == expected)
        // Measured: the map's colour tints its tiles as a sprite's tints it.
        #expect(drawn.allSatisfy { $0.colorBlendFactor == 1 && $0.color.green == 1 && $0.color.red == 0 })
    }

    @Test("Rotation turns the picture within the definition's rect")
    func rotation() {
        let definition = SKTileDefinition(texture: texture(), size: CGSize(width: 10, height: 6))
        definition.rotation = .rotation90
        let group = SKTileGroup(tileDefinition: definition)
        let map = SKTileMapNode(tileSet: SKTileSet(tileGroups: [group], tileSetType: .grid),
                                columns: 1, rows: 1, tileSize: CGSize(width: 20, height: 20))
        map.anchorPoint = .zero
        map.fill(with: group)
        let scene = SKScene(size: CGSize(width: 60, height: 20))
        scene.addChild(map)
        let sprite = sprites(DrawList(scene: scene))[0]
        // The quad is the rect turned a quarter, so it covers the same 10×6.
        #expect(sprite.size == CGSize(width: 6, height: 10))
        let rect = corners(sprite)
        #expect(abs(rect.minX) < 1e-9 && abs(rect.minY) < 1e-9)
        #expect(abs(rect.width - 10) < 1e-9 && abs(rect.height - 6) < 1e-9)
        // Counter-clockwise: the texture's x axis now points up.
        #expect(abs(sprite.transform.b - 1) < 1e-9)
    }

    @Test("Every initializer is designated, so a subclass can call any of them")
    func subclassesCallTheInitializersTheyNeed() {
        final class Map: SKTileMapNode {
            init(group: SKTileGroup) {
                super.init(tileSet: SKTileSet(tileGroups: [group]), columns: 2, rows: 1,
                           tileSize: CGSize(width: 4, height: 4), fillWith: group)
            }
        }
        nonisolated final class Group: SKTileGroup {
            init(definition: SKTileDefinition) { super.init(tileDefinition: definition) }
        }
        nonisolated final class Definition: SKTileDefinition {
            init(side: CGFloat) { super.init(texture: SKTexture(color: .red, size: CGSize(width: side, height: side)), size: CGSize(width: side, height: side)) }
        }
        let group = Group(definition: Definition(side: 4))
        let map = Map(group: group)
        #expect(map.tileGroup(atColumn: 1, row: 0) === group)
        #expect(map.tileDefinition(atColumn: 0, row: 0)?.size == CGSize(width: 4, height: 4))
    }

    @Test("SKTileMapNode() is an empty map, as SpriteKit's is")
    func anEmptyMap() {
        let map = SKTileMapNode()
        #expect(map.numberOfColumns == 0 && map.numberOfRows == 0)
        #expect(map.tileSize == .zero)
        #expect(map.tileSet.tileGroups.isEmpty)
        #expect(map.tileGroup(atColumn: 0, row: 0) == nil)
    }

    @Test("Adjacency constants carry SpriteKit's values")
    func adjacencyConstants() {
        let measured: [(SKTileAdjacencyMask, UInt)] = [
            (.adjacencyUpEdge, 124), (.adjacencyUpperRightEdge, 112), (.adjacencyRightEdge, 241),
            (.adjacencyLowerRightEdge, 193), (.adjacencyDownEdge, 199), (.adjacencyLowerLeftEdge, 7),
            (.adjacencyLeftEdge, 31), (.adjacencyUpperLeftEdge, 28),
            (.adjacencyUpperRightCorner, 223), (.adjacencyLowerRightCorner, 127),
            (.adjacencyLowerLeftCorner, 253), (.adjacencyUpperLeftCorner, 247),
            (.hexFlatAdjacencyUp, 1), (.hexFlatAdjacencyUpperLeft, 32), (.hexFlatAdjacencyAll, 63),
            (.hexPointyAdjacencyUpperLeft, 1), (.hexPointyAdjacencyLeft, 32), (.hexPointyAdjacencyAdd, 63),
        ]
        for (mask, value) in measured {
            #expect(mask.rawValue == value)
        }
    }
}
