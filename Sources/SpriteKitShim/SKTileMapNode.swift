#if SPRITEKIT_SHIM
import Foundation

// SKTileMapNode and its set, groups and definitions, drawn as one sprite per
// filled cell (`tileCommands`, collected like an emitter's particles: the map
// has no child nodes, as on Apple).
//
// Measured against SpriteKit on a Mac (TileMapTests pins each):
//   - a definition draws at its own size from its cell's bottom-left corner,
//     not stretched to the map's tile size;
//   - its rotation turns the picture within that rect (counter-clockwise),
//     its flips mirror it there;
//   - the map's `color` and `colorBlendFactor` tint its tiles as a sprite's
//     tint the sprite;
//   - `frame` is the map's whole size placed by its anchor point, filled or not;
//   - `tileColumnIndex`/`tileRowIndex` clamp at 0 but not at the far edge.
//
// Not drawn: animated definitions show their first texture, normal textures
// and lighting are ignored, and automapping keeps a group's centre rule
// (`.adjacencyAll`, else its first) rather than matching neighbours.

public enum SKTileSetType: UInt, Sendable {
    case grid = 0
    case isometric = 1
    case hexagonalFlat = 2
    case hexagonalPointy = 3
}

public enum SKTileDefinitionRotation: UInt, Sendable {
    case rotation0 = 0
    case rotation90 = 1
    case rotation180 = 2
    case rotation270 = 3
}

public struct SKTileAdjacencyMask: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let adjacencyUp = SKTileAdjacencyMask(rawValue: 1 << 0)
    public static let adjacencyUpperRight = SKTileAdjacencyMask(rawValue: 1 << 1)
    public static let adjacencyRight = SKTileAdjacencyMask(rawValue: 1 << 2)
    public static let adjacencyLowerRight = SKTileAdjacencyMask(rawValue: 1 << 3)
    public static let adjacencyDown = SKTileAdjacencyMask(rawValue: 1 << 4)
    public static let adjacencyLowerLeft = SKTileAdjacencyMask(rawValue: 1 << 5)
    public static let adjacencyLeft = SKTileAdjacencyMask(rawValue: 1 << 6)
    public static let adjacencyUpperLeft = SKTileAdjacencyMask(rawValue: 1 << 7)
    public static let adjacencyAll = SKTileAdjacencyMask(rawValue: 0xFF)
}

open class SKTileDefinition {
    open var textures: [SKTexture]
    open var normalTextures: [SKTexture]
    open var userData: NSMutableDictionary?
    open var name: String?
    open var size: CGSize
    open var timePerFrame: CGFloat
    open var placementWeight: Int = 1
    open var rotation: SKTileDefinitionRotation = .rotation0
    open var flipVertically = false
    open var flipHorizontally = false

    public init() {
        textures = []
        normalTextures = []
        size = .zero
        timePerFrame = 0
    }

    /// Sized as the texture is, as on Apple.
    public convenience init(texture: SKTexture) {
        self.init(textures: [texture], normalTextures: [], size: texture.size(), timePerFrame: 0)
    }

    public convenience init(texture: SKTexture, size: CGSize) {
        self.init(textures: [texture], normalTextures: [], size: size, timePerFrame: 0)
    }

    public convenience init(texture: SKTexture, normalTexture: SKTexture, size: CGSize) {
        self.init(textures: [texture], normalTextures: [normalTexture], size: size, timePerFrame: 0)
    }

    public convenience init(textures: [SKTexture], size: CGSize, timePerFrame: CGFloat) {
        self.init(textures: textures, normalTextures: [], size: size, timePerFrame: timePerFrame)
    }

    public init(textures: [SKTexture], normalTextures: [SKTexture], size: CGSize, timePerFrame: CGFloat) {
        self.textures = textures
        self.normalTextures = normalTextures
        self.size = size
        self.timePerFrame = timePerFrame
    }
}

open class SKTileGroupRule {
    open var adjacency: SKTileAdjacencyMask
    open var tileDefinitions: [SKTileDefinition]
    open var name: String?

    public init(adjacency: SKTileAdjacencyMask, tileDefinitions: [SKTileDefinition]) {
        self.adjacency = adjacency
        self.tileDefinitions = tileDefinitions
    }
}

open class SKTileGroup {
    open var rules: [SKTileGroupRule]
    open var name: String?

    /// One rule that applies wherever it's placed (`.adjacencyAll`), as on Apple.
    public convenience init(tileDefinition: SKTileDefinition) {
        self.init(rules: [SKTileGroupRule(adjacency: .adjacencyAll, tileDefinitions: [tileDefinition])])
    }

    public required init(rules: [SKTileGroupRule]) {
        self.rules = rules
    }

    open class func empty() -> Self {
        Self(rules: [])
    }

    /// What a cell filled with this group draws (see the file's header):
    /// the centre rule's definitions, picked by placement weight, steadily
    /// per cell rather than at random.
    func definition(column: Int, row: Int) -> SKTileDefinition? {
        let rule = rules.first { $0.adjacency == .adjacencyAll } ?? rules.first
        guard let definitions = rule?.tileDefinitions, !definitions.isEmpty else { return nil }
        guard definitions.count > 1 else { return definitions[0] }
        let total = definitions.reduce(0) { $0 + max(0, $1.placementWeight) }
        guard total > 0 else { return definitions[0] }
        var hash = UInt64(bitPattern: Int64(column)) &* 0x9E37_79B9_7F4A_7C15
        hash ^= UInt64(bitPattern: Int64(row)) &* 0xC2B2_AE3D_27D4_EB4F
        hash ^= hash >> 29
        var pick = Int(hash % UInt64(total))
        for definition in definitions {
            pick -= max(0, definition.placementWeight)
            if pick < 0 { return definition }
        }
        return definitions[0]
    }
}

open class SKTileSet {
    open var tileGroups: [SKTileGroup]
    open var name: String?
    open var type: SKTileSetType
    open var defaultTileGroup: SKTileGroup?
    /// Unless set, the first group's first definition's size, as on Apple.
    open var defaultTileSize: CGSize {
        get {
            if let explicitTileSize { return explicitTileSize }
            return tileGroups.first?.rules.first?.tileDefinitions.first?.size ?? .zero
        }
        set { explicitTileSize = newValue }
    }

    private var explicitTileSize: CGSize?

    public convenience init(tileGroups: [SKTileGroup]) {
        self.init(tileGroups: tileGroups, tileSetType: .grid)
    }

    public init(tileGroups: [SKTileGroup], tileSetType: SKTileSetType) {
        self.tileGroups = tileGroups
        self.type = tileSetType
    }
}

open class SKTileMapNode: SKNode {
    open var tileSet: SKTileSet
    open var tileSize: CGSize
    open var anchorPoint = CGPoint(x: 0.5, y: 0.5)
    open var color: SKColor = .white
    open var colorBlendFactor: CGFloat = 0
    open var blendMode: SKBlendMode = .alpha
    open var shader: SKShader?
    open var attributeValues: [String: SKAttributeValue] = [:]
    open var enableAutomapping = true
    open var lightingBitMask: UInt32 = 0

    open var numberOfColumns: Int {
        didSet { resize(columns: oldValue, rows: numberOfRows) }
    }

    open var numberOfRows: Int {
        didSet { resize(columns: numberOfColumns, rows: oldValue) }
    }

    open var mapSize: CGSize {
        CGSize(width: tileSize.width * CGFloat(numberOfColumns), height: tileSize.height * CGFloat(numberOfRows))
    }

    /// Row by row from the bottom, as `tileGroupLayout` is.
    private var groups: [SKTileGroup?]
    private var definitions: [SKTileDefinition?]

    public init(tileSet: SKTileSet, columns: Int, rows: Int, tileSize: CGSize) {
        self.tileSet = tileSet
        self.numberOfColumns = max(0, columns)
        self.numberOfRows = max(0, rows)
        self.tileSize = tileSize
        let count = max(0, columns) * max(0, rows)
        groups = Array(repeating: nil, count: count)
        definitions = Array(repeating: nil, count: count)
        super.init()
    }

    public convenience init(tileSet: SKTileSet, columns: Int, rows: Int, tileSize: CGSize, fillWith tileGroup: SKTileGroup) {
        self.init(tileSet: tileSet, columns: columns, rows: rows, tileSize: tileSize)
        fill(with: tileGroup)
    }

    public convenience init(
        tileSet: SKTileSet, columns: Int, rows: Int, tileSize: CGSize, tileGroupLayout: [SKTileGroup]
    ) {
        self.init(tileSet: tileSet, columns: columns, rows: rows, tileSize: tileSize)
        for (index, group) in tileGroupLayout.prefix(groups.count).enumerated() {
            setTileGroup(group, forColumn: index % numberOfColumns, row: index / numberOfColumns)
        }
    }

    open override var contentFrame: CGRect {
        let size = mapSize
        return CGRect(x: -anchorPoint.x * size.width, y: -anchorPoint.y * size.height,
                      width: size.width, height: size.height)
    }

    open func fill(with tileGroup: SKTileGroup?) {
        for row in 0 ..< numberOfRows {
            for column in 0 ..< numberOfColumns {
                setTileGroup(tileGroup, forColumn: column, row: row)
            }
        }
    }

    open func tileGroup(atColumn column: Int, row: Int) -> SKTileGroup? {
        index(column, row).flatMap { groups[$0] }
    }

    open func tileDefinition(atColumn column: Int, row: Int) -> SKTileDefinition? {
        index(column, row).flatMap { definitions[$0] }
    }

    open func setTileGroup(_ tileGroup: SKTileGroup?, forColumn column: Int, row: Int) {
        guard let index = index(column, row) else { return }
        groups[index] = tileGroup
        definitions[index] = tileGroup?.definition(column: column, row: row)
    }

    open func setTileGroup(
        _ tileGroup: SKTileGroup, andTileDefinition tileDefinition: SKTileDefinition, forColumn column: Int, row: Int
    ) {
        guard let index = index(column, row) else { return }
        groups[index] = tileGroup
        definitions[index] = tileDefinition
    }

    open func tileColumnIndex(fromPosition position: CGPoint) -> Int {
        guard tileSize.width > 0 else { return 0 }
        return max(0, Int(((position.x - contentFrame.minX) / tileSize.width).rounded(.down)))
    }

    open func tileRowIndex(fromPosition position: CGPoint) -> Int {
        guard tileSize.height > 0 else { return 0 }
        return max(0, Int(((position.y - contentFrame.minY) / tileSize.height).rounded(.down)))
    }

    open func centerOfTile(atColumn column: Int, row: Int) -> CGPoint {
        let origin = contentFrame.origin
        return CGPoint(x: origin.x + (CGFloat(column) + 0.5) * tileSize.width,
                       y: origin.y + (CGFloat(row) + 0.5) * tileSize.height)
    }

    open func setValue(_ value: SKAttributeValue, forAttribute key: String) {
        attributeValues[key] = value
    }

    open func value(forAttributeNamed key: String) -> SKAttributeValue? {
        attributeValues[key]
    }

    private func index(_ column: Int, _ row: Int) -> Int? {
        guard column >= 0, column < numberOfColumns, row >= 0, row < numberOfRows else { return nil }
        return row * numberOfColumns + column
    }

    private func resize(columns oldColumns: Int, rows oldRows: Int) {
        var newGroups = [SKTileGroup?](repeating: nil, count: max(0, numberOfColumns) * max(0, numberOfRows))
        var newDefinitions = [SKTileDefinition?](repeating: nil, count: newGroups.count)
        for row in 0 ..< max(0, min(oldRows, numberOfRows)) {
            for column in 0 ..< max(0, min(oldColumns, numberOfColumns)) {
                newGroups[row * numberOfColumns + column] = groups[row * oldColumns + column]
                newDefinitions[row * numberOfColumns + column] = definitions[row * oldColumns + column]
            }
        }
        groups = newGroups
        definitions = newDefinitions
    }

    /// One sprite per filled cell, in `transform` (the map's own, drawn).
    func tileCommands(
        transform: CGAffineTransform, alpha: CGFloat, z: CGFloat, cull: CGRect?
    ) -> [(CGFloat, DrawList.Command)] {
        let origin = contentFrame.origin
        var commands: [(CGFloat, DrawList.Command)] = []
        for row in 0 ..< numberOfRows {
            for column in 0 ..< numberOfColumns {
                guard let definition = definitions[row * numberOfColumns + column],
                      let texture = definition.textures.first,
                      definition.size.width > 0, definition.size.height > 0 else { continue }
                let size = definition.size
                let centre = CGPoint(x: origin.x + CGFloat(column) * tileSize.width + size.width / 2,
                                     y: origin.y + CGFloat(row) * tileSize.height + size.height / 2)
                let quarterTurns = Int(definition.rotation.rawValue)
                let quad = quarterTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
                let placed = CGAffineTransform(rotationAngle: CGFloat(quarterTurns) * .pi / 2)
                    .concatenating(CGAffineTransform(scaleX: definition.flipHorizontally ? -1 : 1,
                                                     y: definition.flipVertically ? -1 : 1))
                    .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
                    .concatenating(transform)
                let sprite = DrawList.Sprite(
                    transform: placed,
                    size: quad,
                    anchorPoint: CGPoint(x: 0.5, y: 0.5),
                    texture: texture,
                    textureRect: texture.textureRect,
                    color: color,
                    colorBlendFactor: colorBlendFactor,
                    alpha: alpha,
                    blendMode: blendMode,
                    shader: shader,
                    attributeValues: attributeValues
                )
                if DrawList.isCulled(sprite, by: cull) { continue }
                commands.append((z, .sprite(sprite)))
            }
        }
        return commands
    }
}
#endif
