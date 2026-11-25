import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

/// Records what the renderer asked GL to do, so the whole resource path can
/// be tested with no context, no window and no device.
final class RecordingDevice: RenderDevice {
    struct Upload {
        let width: Int
        let height: Int
        let byteCount: Int
    }

    private(set) var uploads: [Upload] = []
    private(set) var programs: [(vertex: String, fragment: String)] = []
    private(set) var deletedTextures: [UInt32] = []
    private(set) var deletedPrograms: [UInt32] = []

    private var nextName: UInt32 = 0
    /// Set to make linking fail, as a bad shader would.
    var failsToLink = false

    func createTexture(width: Int, height: Int, pixels: Data?) -> UInt32 {
        uploads.append(Upload(width: width, height: height, byteCount: pixels?.count ?? 0))
        nextName += 1
        return nextName
    }

    func deleteTexture(_ name: UInt32) { deletedTextures.append(name) }

    /// Each strip `writeRows` wrote: the texture, its first row and how many.
    private(set) var strips: [(name: UInt32, y: Int, rows: Int)] = []
    func writeRows(_ name: UInt32, width: Int, y: Int, rowCount: Int, pixels: Data, byteOffset: Int) {
        strips.append((name, y, rowCount))
    }

    private(set) var repeating: Set<UInt32> = []
    func setRepeats(_ name: UInt32) { repeating.insert(name) }

    /// Set to copy a texture's region on the GPU, as `GLDevice` does; off,
    /// a copy fails, as it does on a device whose framebuffer is incomplete.
    var copiesRegions = false
    private(set) var copies: [(source: UInt32, copy: UInt32, width: Int, height: Int)] = []
    func copyRegion(of source: UInt32, x: Int, y: Int, width: Int, height: Int) -> UInt32 {
        guard copiesRegions else { return 0 }
        nextName += 1
        copies.append((source, nextName, width, height))
        return nextName
    }

    // MARK: Compressed pages

    var supportsASTC = true
    /// Each compressed upload: its size, the levels uploaded and their bytes.
    private(set) var compressedUploads: [(name: UInt32, width: Int, height: Int, levels: Int, bytes: Int)] = []
    func createTexture(compressed page: CompressedPage, levels: Int) -> UInt32 {
        nextName += 1
        compressedUploads.append((nextName, page.width, page.height, levels, page.levels.prefix(levels).reduce(0) { $0 + $1.count }))
        return nextName
    }

    private(set) var mipmapped: [(name: UInt32, levels: Int)] = []
    func generateMipmaps(_ name: UInt32, levels: Int) { mipmapped.append((name, levels)) }

    func createProgram(vertex: String, fragment: String) -> UInt32 {
        programs.append((vertex, fragment))
        guard !failsToLink else { return 0 }
        nextName += 1
        return nextName
    }

    func deleteProgram(_ name: UInt32) { deletedPrograms.append(name) }

    // MARK: Render targets

    private(set) var createdTargets: [RenderTargetHandle] = []
    private(set) var deletedTargets: [RenderTargetHandle] = []
    var maximumTextureSide: Int = 4096
    /// Set to make a target fail, as a driver out of memory would.
    var failsToMakeTargets = false

    func createRenderTarget(width: Int, height: Int, stencil: Bool) -> RenderTargetHandle? {
        guard !failsToMakeTargets else { return nil }
        nextName += 3
        let handle = RenderTargetHandle(
            framebuffer: nextName, texture: nextName - 1,
            stencil: stencil ? nextName - 2 : 0,
            width: width, height: height
        )
        createdTargets.append(handle)
        return handle
    }

    func deleteRenderTarget(_ target: RenderTargetHandle) {
        deletedTargets.append(target)
    }
}

@Suite("Texture uploads")
struct TextureCacheTests {
    @Test("A texture uploads once however many sprites use it")
    func uploadsOnce() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let texture = SKTexture(imageNamed: "Brick")

        let a = cache.name(for: texture)
        let b = cache.name(for: texture)
        let c = cache.name(for: texture)

        #expect(a == b && b == c)
        #expect(a != 0)
        #expect(device.uploads.count == 1)
    }

    @Test("Atlas slices share their parent's upload")
    func slicesShare() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let atlas = SKTexture(imageNamed: "Atlas")
        let a = SKTexture(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), in: atlas)
        let b = SKTexture(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), in: atlas)

        #expect(cache.name(for: a) == cache.name(for: b))
        #expect(device.uploads.count == 1)
    }

    @Test("A texture with no pixels yet uploads a white placeholder")
    func placeholder() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        cache.name(for: SKTexture(imageNamed: "NotExportedYet"))

        #expect(device.uploads.count == 1)
        #expect(device.uploads[0].width == 1)
        #expect(device.uploads[0].byteCount == 4)
    }

    @Test("Resolved pixels are uploaded at their real size")
    func resolvedPixels() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        cache.pixelSource = { _ in (width: 64, height: 32, pixels: Data(count: 64 * 32 * 4)) }
        cache.name(for: SKTexture(imageNamed: "Brick"))

        #expect(device.uploads[0].width == 64)
        #expect(device.uploads[0].height == 32)
        #expect(device.uploads[0].byteCount == 64 * 32 * 4)
    }

}

/// `AssetIndex.shared` is process-wide, so these run one at a time: Swift
/// Testing runs suites in parallel by default and they would otherwise
/// clear the index out from under each other.
@Suite("Packed pages", .serialized)
struct PackedPageTests {
    /// The packed art: hundreds of named assets sit on a handful of pages,
    /// so uploads must key on the page, not the asset.
    @Test("Every asset on one packed page shares a single upload")
    func pageSharedAcrossAssets() throws {
        let index = try AssetIndex(json: Data("""
        {
          "version": 2,
          "scale": 3,
          "pages": [{"file": "page-0.png", "width": 1024, "height": 1024},
                    {"file": "page-1.png", "width": 1024, "height": 1024}],
          "assets": {
            "Brick1": {"page": 0, "rect": [0, 0, 150, 150], "size": [50, 50]},
            "Brick2": {"page": 0, "rect": [160, 0, 150, 150], "size": [50, 50]},
            "Brick3": {"page": 0, "rect": [320, 0, 150, 150], "size": [50, 50]},
            "Wall":   {"page": 1, "rect": [0, 0, 300, 60], "size": [100, 20]}
          }
        }
        """.utf8))
        AssetIndex.shared = index
        defer { AssetIndex.shared = nil }

        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        cache.pageSource = { _ in PageImage(width: 1024, height: 1024, pixels: Data(count: 16)) }

        let a = cache.name(for: SKTexture(imageNamed: "Brick1"))
        let b = cache.name(for: SKTexture(imageNamed: "Brick2"))
        let c = cache.name(for: SKTexture(imageNamed: "Brick3"))
        let d = cache.name(for: SKTexture(imageNamed: "Wall"))

        #expect(a == b && b == c)
        #expect(d != a)
        // Two pages, not four assets.
        #expect(device.uploads.count == 2)
    }

    @Test("A page still decoding is left out of the frame, not waited for, and drawn once it's in")
    func deferredPage() throws {
        let index = try AssetIndex(json: Data("""
        {
          "version": 2, "scale": 3,
          "pages": [{"file": "p.png", "width": 8, "height": 8}],
          "assets": {"Brick": {"page": 0, "rect": [0, 0, 4, 4], "size": [4, 4]},
                     "Stone": {"page": 0, "rect": [4, 0, 4, 4], "size": [4, 4]}}
        }
        """.utf8))
        AssetIndex.shared = index
        defer { AssetIndex.shared = nil }

        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        var decoded = false
        var asked: [Int] = []
        var loads = 0
        cache.pageSource = { _ in loads += 1; return PageImage(width: 8, height: 8, pixels: Data(count: 8 * 8 * 4)) }
        cache.pageIsReady = { _ in decoded }
        cache.pageWanted = { asked.append($0) }
        cache.defersPages = true

        // Decoding: nothing drawn with it, nothing waited for, its decode asked for.
        #expect(cache.name(for: SKTexture(imageNamed: "Brick")) == 0)
        #expect(cache.imageName(for: SKTexture(imageNamed: "Stone")) == 0, "a shaded sprite's cut-out waits for it too")
        #expect(loads == 0)
        #expect(asked == [0, 0])
        #expect(cache.deferredPages >= 2)
        #expect(device.uploads.isEmpty)

        // Decoded: uploaded, and remembered.
        decoded = true
        let name = cache.name(for: SKTexture(imageNamed: "Brick"))
        #expect(name != 0)
        #expect(loads == 1)
        decoded = false
        #expect(cache.name(for: SKTexture(imageNamed: "Brick")) == name, "an uploaded page isn't asked about again")
    }

    @Test("Pages are left out only in play: a fixed frame step or a held clock waits for them")
    func deferralSwitch() {
        #expect(ResourceCache.defersPages(decodesInSoftware: true, fixedFrameStep: nil, clockHeld: false))
        #expect(!ResourceCache.defersPages(decodesInSoftware: true, fixedFrameStep: 1.0 / 60, clockHeld: false), "a capture's stills are complete")
        #expect(!ResourceCache.defersPages(decodesInSoftware: true, fixedFrameStep: nil, clockHeld: true), "a held clock waits")
        #expect(!ResourceCache.defersPages(decodesInSoftware: false, fixedFrameStep: nil, clockHeld: false), "ASTC on the GPU: nothing to defer")
    }

    @Test("A snapshot or film, kept as drawn, waits for its pages")
    func pageNotDeferred() throws {
        let index = try AssetIndex(json: Data("""
        {"version": 2, "scale": 3, "pages": [{"file": "p.png", "width": 8, "height": 8}],
         "assets": {"Brick": {"page": 0, "rect": [0, 0, 4, 4], "size": [4, 4]}}}
        """.utf8))
        AssetIndex.shared = index
        defer { AssetIndex.shared = nil }

        let cache = ResourceCache(device: RecordingDevice())
        cache.pageSource = { _ in PageImage(width: 8, height: 8, pixels: Data(count: 8 * 8 * 4)) }
        cache.pageIsReady = { _ in false }
        cache.pageWanted = { _ in Issue.record("not deferring: nothing to ask for") }
        cache.defersPages = false
        #expect(cache.name(for: SKTexture(imageNamed: "Brick")) != 0)
    }

    @Test("A shaded sprite's image is cut out of its page once, clamped; a uniform's wraps")
    func ownImage() throws {
        let index = try AssetIndex(json: Data("""
        {
          "version": 2, "scale": 3,
          "pages": [{"file": "p.png", "width": 8, "height": 8},
                    {"file": "whole.png", "width": 4, "height": 4, "repeats": true}],
          "assets": {"Brick": {"page": 0, "rect": [2, 2, 4, 4], "size": [4, 4]},
                     "Ground": {"page": 1, "rect": [0, 0, 4, 4], "size": [4, 4]}}
        }
        """.utf8))
        AssetIndex.shared = index
        defer { AssetIndex.shared = nil }

        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        cache.pageSource = { page in page == 0 ? PageImage(width: 8, height: 8, pixels: Data(count: 8 * 8 * 4)) : PageImage(width: 4, height: 4, pixels: Data(count: 4 * 4 * 4)) }

        let page = cache.name(for: SKTexture(imageNamed: "Brick"))
        let own = cache.imageName(for: SKTexture(imageNamed: "Brick"))
        #expect(own != page)
        #expect(cache.imageName(for: SKTexture(imageNamed: "Brick")) == own)
        #expect(cache.imageName(for: SKTexture(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: SKTexture(imageNamed: "Brick"))) == own)
        #expect(device.uploads.last?.width == 4 && device.uploads.last?.height == 4)
        #expect(!device.repeating.contains(own), "a sprite's own texture clamps, as SpriteKit's do")
        let wrapping = cache.samplerName(for: SKTexture(imageNamed: "Brick"))
        #expect(wrapping != own && device.repeating.contains(wrapping))
        // A whole page is the image already.
        #expect(cache.imageName(for: SKTexture(imageNamed: "Ground")) == cache.name(for: SKTexture(imageNamed: "Ground")))
    }

    @Test("Pages decoded ahead upload a strip at a time, and a page drawn part way is finished")
    func uploadAhead() throws {
        let index = try AssetIndex(json: Data("""
        {
          "version": 2, "scale": 3,
          "pages": [{"file": "a.png", "width": 4, "height": 300},
                    {"file": "b.png", "width": 4, "height": 300}],
          "assets": {"A": {"page": 0, "rect": [0, 0, 4, 4], "size": [4, 4]},
                     "B": {"page": 1, "rect": [0, 0, 4, 4], "size": [4, 4]}}
        }
        """.utf8))
        AssetIndex.shared = index
        defer { AssetIndex.shared = nil }

        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        cache.pageRowsBottomFirst = true
        var ahead: [(page: Int, image: PageImage)] = [
            (0, PageImage(width: 4, height: 300, pixels: Data(count: 4 * 300 * 4))),
            (1, PageImage(width: 4, height: 300, pixels: Data(count: 4 * 300 * 4))),
        ]
        cache.pageAhead = { ahead.isEmpty ? nil : ahead.removeFirst() }
        cache.pageSource = { _ in Issue.record("decoded again"); return nil }

        // Three strips: page 0 whole (128 + 128 + 44 rows).
        var budget = 3
        cache.uploadAhead(while: { budget -= 1; return budget >= 0 })
        #expect(device.strips.map(\.rows) == [128, 128, 44])
        #expect(device.strips.map(\.y) == [0, 128, 256])
        let a = cache.name(for: SKTexture(imageNamed: "A"))
        #expect(device.strips.allSatisfy { $0.name == a })

        // One strip of page 1, then it's drawn: the rest goes at once.
        budget = 1
        cache.uploadAhead(while: { budget -= 1; return budget >= 0 })
        let b = cache.name(for: SKTexture(imageNamed: "B"))
        #expect(b != a)
        #expect(device.strips.filter { $0.name == b }.map(\.y) == [0, 128, 256])
        #expect(cache.name(for: SKTexture(imageNamed: "B")) == b)
    }

    @Test("A named texture reports its art's size in points, not pixels")
    func sizeInPoints() throws {
        let index = try AssetIndex(json: Data("""
        {
          "version": 2, "scale": 3,
          "pages": [{"file": "p.png", "width": 1024, "height": 1024}],
          "assets": {"Brick": {"page": 0, "rect": [0, 0, 150, 150], "size": [50, 50]}}
        }
        """.utf8))
        AssetIndex.shared = index
        defer { AssetIndex.shared = nil }

        #expect(SKTexture(imageNamed: "Brick").size() == CGSize(width: 50, height: 50))
    }
}

@Suite("Program linking")
struct ProgramCacheTests {
    @Test("A shader links once and is reused")
    func linksOnce() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let shader = SKShader(source: "void main() { gl_FragColor = SKDefaultShading(); }")

        let a = cache.program(for: shader)
        let b = cache.program(for: shader)
        #expect(a == b && a != 0)
        #expect(device.programs.count == 1)
    }

    @Test("The linked fragment shader is the translated one")
    func linksTranslated() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let shader = SKShader(source: "void main() { gl_FragColor = texture2D(u_texture, v_tex_coord); }")
        cache.program(for: shader)

        let fragment = device.programs[0].fragment
        #expect(fragment.hasPrefix("#version 300 es"))
        #expect(!fragment.contains("gl_FragColor"))
        #expect(!fragment.contains("texture2D"))
    }

    @Test("The node's uniforms are declared with their GLSL types")
    func uniformTypes() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let shader = SKShader(source: "void main() { gl_FragColor = u_shape; }", uniforms: [
            SKUniform(name: "u_shape", vectorFloat4: SIMD4(1, 2, 3, 4)),
            SKUniform(name: "u_fade", float: 0.5),
            SKUniform(name: "u_normal", texture: SKTexture(imageNamed: "N")),
        ])
        cache.program(for: shader)

        let fragment = device.programs[0].fragment
        #expect(fragment.contains("uniform vec4 u_shape;"))
        #expect(fragment.contains("uniform float u_fade;"))
        #expect(fragment.contains("uniform sampler2D u_normal;"))
    }

    @Test("Attributes are uniforms of the fragment stage")
    func attributesBothStages() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let shader = SKShader(source: "void main() { gl_FragColor = vec4(a_run); }")
        shader.attributes = [SKAttribute(name: "a_run", type: .vectorFloat4)]
        cache.program(for: shader)

        #expect(!device.programs[0].vertex.contains("a_run"))
        #expect(device.programs[0].fragment.contains("uniform vec4 a_run;"))
    }

    @Test("Shaders made from the same source and inputs share one program")
    func sharedPrograms() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let source = "void main() { gl_FragColor = vec4(u_level); }"
        let a = SKShader(source: source, uniforms: [SKUniform(name: "u_level", float: 0.2)])
        let b = SKShader(source: source, uniforms: [SKUniform(name: "u_level", float: 0.7)])
        let other = SKShader(source: source, uniforms: [SKUniform(name: "u_level", vectorFloat2: .zero)])

        let first = cache.program(for: a)
        #expect(cache.program(for: b) == first)
        #expect(b.glProgram == first)
        #expect(device.programs.count == 1)
        // A uniform of another type declares another program.
        #expect(cache.program(for: other) != first)
        #expect(device.programs.count == 2)
    }

    @Test("A shader whose uniforms change after its program was built is built again")
    func rebuiltOnChange() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let shader = SKShader(source: "void main() { gl_FragColor = vec4(u_level); }")
        cache.program(for: shader)
        shader.addUniform(SKUniform(name: "u_level", float: 1))
        cache.program(for: shader)
        #expect(device.programs.count == 2)
        #expect(device.programs[1].fragment.contains("uniform float u_level;"))
        cache.program(for: shader)
        #expect(device.programs.count == 2)
    }

    @Test("A drawn texture readied off the frame thread is uploaded once, and drawing it uploads nothing more")
    func adoptedTexture() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        cache.pixelSource = { _ in Issue.record("readied again"); return nil }
        let texture = SKTexture(data: Data(count: 2 * 2 * 4), size: CGSize(width: 2, height: 2))
        cache.adopt(texture, width: 2, height: 2, bottomFirst: Data(count: 2 * 2 * 4))
        let name = texture.glName
        #expect(name != 0)
        #expect(cache.name(for: texture) == name)
        cache.adopt(texture, width: 2, height: 2, bottomFirst: Data(count: 2 * 2 * 4))
        #expect(device.uploads.count == 1)
    }

    @Test("A shader that fails to link is not cached as linked")
    func failedLink() {
        let device = RecordingDevice()
        device.failsToLink = true
        let cache = ResourceCache(device: device)
        let shader = SKShader(source: "nonsense")

        #expect(cache.program(for: shader) == 0)
        #expect(cache.linkedProgramCount == 0)
        // Tried again next frame rather than silently never drawing.
        cache.program(for: shader)
        #expect(device.programs.count == 2)
    }
}

@Suite("Context loss")
struct ContextLossTests {
    @Test("Dropping the cache deletes what it uploaded and clears the slots")
    func dropsEverything() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let texture = SKTexture(imageNamed: "Brick")
        let shader = SKShader(source: "void main() { gl_FragColor = vec4(1.0); }")
        cache.name(for: texture)
        cache.program(for: shader)

        #expect(cache.uploadedTextureCount == 1)
        #expect(cache.linkedProgramCount == 1)

        cache.removeAll(texturesIn: [texture], shadersIn: [shader])

        #expect(device.deletedTextures.count == 1)
        #expect(device.deletedPrograms.count == 1)
        #expect(texture.glName == 0)
        #expect(shader.glProgram == 0)

        // And it re-uploads afterwards rather than reusing a dead name.
        cache.name(for: texture)
        #expect(device.uploads.count == 2)
    }
}

/// Compressed pages: uploaded as they ship, cut out block for block, and a
/// plain copy for shaders.
@Suite("Compressed pages")
@MainActor
struct CompressedPageCacheTests {
    /// A page of 4×4 blocks whose every block's first byte is its index.
    static func page(width: Int, height: Int, levels: Int) -> CompressedPage {
        var data: [Data] = []
        for level in 0 ..< levels {
            let w = max(1, width >> level), h = max(1, height >> level)
            var bytes = Data(count: CompressedPage.byteCount(width: w, height: h, blockWidth: 4, blockHeight: 4))
            for block in 0 ..< bytes.count / 16 { bytes[block * 16] = UInt8(block & 0xFF) }
            data.append(bytes)
        }
        return CompressedPage(width: width, height: height, blockWidth: 4, blockHeight: 4, format: 0x93B0, levels: data)
    }

    static let index = """
    {
      "version": 2, "scale": 3,
      "pages": [{"file": "atlas-000.ktx", "width": 64, "height": 64, "format": "astc", "block": [4, 4], "levels": 3},
                {"file": "whole/Ground.ktx", "width": 40, "height": 40, "repeats": true, "format": "astc", "block": [4, 4], "levels": 2}],
      "assets": {"Brick": {"page": 0, "rect": [8, 20, 10, 12], "size": [3.33, 4]},
                 "Ground": {"page": 1, "rect": [0, 0, 40, 40], "size": [13.33, 13.33]}}
    }
    """

    @Test("A compressed page uploads its levels as they ship, and counts its bytes")
    func uploadsLevels() throws {
        AssetIndex.shared = try AssetIndex(json: Data(Self.index.utf8))
        defer { AssetIndex.shared = nil }
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        cache.pageSource = { $0 == 0 ? PageImage(Self.page(width: 64, height: 64, levels: 3)) : PageImage(Self.page(width: 40, height: 40, levels: 2)) }
        let name = cache.name(for: SKTexture(imageNamed: "Brick"))
        #expect(device.compressedUploads.count == 1)
        #expect(device.compressedUploads.first?.name == name && device.compressedUploads.first?.levels == 3)
        #expect(device.uploads.isEmpty, "no RGBA8 upload for a page the GPU samples as ASTC")
        let bytes = cache.uploadedTextureBytes
        #expect(bytes.gpu == (256 + 64 + 16) * 16)
        #expect(bytes.rgba == (64 * 64 + 32 * 32 + 16 * 16) * 4)
    }

    @Test("An atlas image cuts out of its compressed page block for block")
    func cutsBlocks() throws {
        AssetIndex.shared = try AssetIndex(json: Data(Self.index.utf8))
        defer { AssetIndex.shared = nil }
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        cache.pageRowsBottomFirst = true
        cache.pageSource = { $0 == 0 ? PageImage(Self.page(width: 64, height: 64, levels: 3)) : PageImage(Self.page(width: 40, height: 40, levels: 2)) }
        let wrapping = cache.samplerName(for: SKTexture(imageNamed: "Brick"))
        // Brick is at x 8, and its bottom 64 - 20 - 12 = 32 up: blocks 2…4 across, 8…10 up.
        let cut = try #require(device.compressedUploads.last)
        #expect(cut.name == wrapping && cut.width == 10 && cut.height == 12 && cut.levels == 1)
        #expect(cut.bytes == 3 * 3 * 16)
        #expect(device.repeating.contains(wrapping))
        #expect(device.uploads.isEmpty, "decoded on the CPU when blocks would do")
    }

    @Test("A shader gets a whole page without its mip levels, which would seam where it tiles")
    func plainForShaders() throws {
        AssetIndex.shared = try AssetIndex(json: Data(Self.index.utf8))
        defer { AssetIndex.shared = nil }
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        cache.pageSource = { $0 == 0 ? PageImage(Self.page(width: 64, height: 64, levels: 3)) : PageImage(Self.page(width: 40, height: 40, levels: 2)) }
        let drawn = cache.name(for: SKTexture(imageNamed: "Ground"))
        let sampled = cache.samplerName(for: SKTexture(imageNamed: "Ground"))
        let shaded = cache.imageName(for: SKTexture(imageNamed: "Ground"))
        #expect(drawn != sampled && sampled == shaded)
        #expect(device.compressedUploads.map(\.levels) == [2, 1])
        #expect(device.repeating.contains(sampled))
    }

    @Test("A shader's whole page uploaded ahead of its first draw is copied, not waited for (its pixels are gone)")
    func plainAfterUploadAhead() throws {
        AssetIndex.shared = try AssetIndex(json: Data(Self.index.utf8))
        defer { AssetIndex.shared = nil }
        for copies in [true, false] {
            let device = RecordingDevice()
            device.supportsASTC = false
            device.copiesRegions = copies
            let cache = ResourceCache(device: device)
            cache.pageRowsBottomFirst = true
            // Decoding in software, and the decoded page taken by the upload
            // ahead: never ready again, as `PageDecodes.isWaiting` says.
            cache.defersPages = true
            cache.pageIsReady = { _ in false }
            cache.pageWanted = { _ in }
            var ahead: [(page: Int, image: PageImage)] = [(1, PageImage(Self.page(width: 40, height: 40, levels: 2)))]
            cache.pageAhead = { ahead.isEmpty ? nil : ahead.removeFirst() }
            var reads = 0
            cache.pageSource = { _ in reads += 1; return PageImage(Self.page(width: 40, height: 40, levels: 2)) }
            cache.uploadAhead(while: { true })
            let drawn = cache.name(for: SKTexture(imageNamed: "Ground"))
            let sampled = cache.samplerName(for: SKTexture(imageNamed: "Ground"))
            #expect(drawn != 0)
            #expect(sampled != 0 && sampled != drawn, "the shader's map is bound, level 0 alone")
            #expect(device.repeating.contains(sampled))
            #expect(cache.samplerName(for: SKTexture(imageNamed: "Ground")) == sampled)
            if copies {
                #expect(device.copies.map(\.source) == [drawn] && device.copies.first?.width == 40)
                #expect(reads == 0, "copied on the GPU, not decoded again")
            } else {
                #expect(reads == 1, "read again once, where the GPU can't copy it")
            }
        }
    }

    @Test("Without ASTC a page decodes to RGBA8 and makes the levels it shipped with")
    func fallsBackToRGBA8() throws {
        AssetIndex.shared = try AssetIndex(json: Data(Self.index.utf8))
        defer { AssetIndex.shared = nil }
        let device = RecordingDevice()
        device.supportsASTC = false
        let cache = ResourceCache(device: device)
        cache.pageRowsBottomFirst = true
        cache.pageSource = { $0 == 0 ? PageImage(Self.page(width: 64, height: 64, levels: 3)) : PageImage(Self.page(width: 40, height: 40, levels: 2)) }
        let name = cache.name(for: SKTexture(imageNamed: "Brick"))
        #expect(device.compressedUploads.isEmpty)
        #expect(device.uploads.last?.width == 64 && device.uploads.last?.byteCount == 64 * 64 * 4)
        #expect(device.mipmapped.first?.name == name && device.mipmapped.first?.levels == 3)
    }
}
