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
          "version": 1,
          "scale": 3,
          "pages": [{"file": "page-0.png", "width": 1024, "height": 1024},
                    {"file": "page-1.png", "width": 1024, "height": 1024}],
          "assets": {
            "Brick1": {"page": 0, "rect": [0, 0, 150, 150], "size": [50, 50]},
            "Brick2": {"page": 0, "rect": [160, 0, 150, 150], "size": [50, 50]},
            "Brick3": {"page": 0, "rect": [320, 0, 150, 150], "size": [50, 50]},
            "Kerb":   {"page": 1, "rect": [0, 0, 300, 60], "size": [100, 20]}
          }
        }
        """.utf8))
        AssetIndex.shared = index
        defer { AssetIndex.shared = nil }

        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        cache.pageSource = { _ in (width: 1024, height: 1024, pixels: Data(count: 16)) }

        let a = cache.name(for: SKTexture(imageNamed: "Brick1"))
        let b = cache.name(for: SKTexture(imageNamed: "Brick2"))
        let c = cache.name(for: SKTexture(imageNamed: "Brick3"))
        let d = cache.name(for: SKTexture(imageNamed: "Kerb"))

        #expect(a == b && b == c)
        #expect(d != a)
        // Two pages, not four assets.
        #expect(device.uploads.count == 2)
    }

    @Test("A named texture reports its art's size in points, not pixels")
    func sizeInPoints() throws {
        let index = try AssetIndex(json: Data("""
        {
          "version": 1, "scale": 3,
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

    @Test("Attributes reach both stages")
    func attributesBothStages() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let shader = SKShader(source: "void main() { gl_FragColor = vec4(a_run); }")
        shader.attributes = [SKAttribute(name: "a_run", type: .vectorFloat4)]
        cache.program(for: shader)

        #expect(device.programs[0].vertex.contains("out vec4 a_run;"))
        #expect(device.programs[0].fragment.contains("in vec4 a_run;"))
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
