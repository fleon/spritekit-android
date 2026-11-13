import Foundation
import SpriteKitShim

/// The GL operations the renderer needs, behind a protocol.
///
/// Only resource lifetime and pass setup go through here — never per-quad
/// work, which stays in the batcher's flat arrays. That keeps the hot path
/// free of dynamic dispatch while letting the whole renderer be driven by a
/// recording fake in tests, with no context, no window and no device.
public protocol RenderDevice: AnyObject {
    func createTexture(width: Int, height: Int, pixels: Data?) -> UInt32
    func deleteTexture(_ name: UInt32)

    /// Compiles and links a program. Returns 0 on failure, having logged it.
    func createProgram(vertex: String, fragment: String) -> UInt32
    func deleteProgram(_ name: UInt32)
}

/// Keeps GL handles for the shim's textures and shaders.
///
/// `SKTexture.glName` and `SKShader.glProgram` are the cache slots — they
/// live on the shim's types precisely so a texture used by many sprites is
/// uploaded once, and a shader shared by a world's tiles is linked once.
public final class ResourceCache {
    private let device: RenderDevice
    private var ownedTextures: Set<UInt32> = []
    private var ownedPrograms: Set<UInt32> = []
    /// GL names for packed pages, keyed by their index in `AssetIndex.pages`.
    private var pageNames: [Int: UInt32] = [:]

    /// Pixels for one packed page, which the asset index names. Hundreds of
    /// assets share a page, so this is called once per page, not per asset.
    public var pageSource: ((Int) -> (width: Int, height: Int, pixels: Data)?)?

    /// Pixels for a texture that the asset index does not back — one built
    /// from raw data, or a stand-in in a test.
    public var pixelSource: ((SKTexture) -> (width: Int, height: Int, pixels: Data)?)?

    public init(device: RenderDevice) {
        self.device = device
    }

    /// The GL name for a texture, uploading its pixels the first time.
    ///
    /// Named textures resolve to a packed page, and a page is uploaded once
    /// however many assets sit on it — the whole point of packing. Keying
    /// this on the texture instead would upload the same page once per asset
    /// name, which for this game would be about 1,600 uploads of 18 pages.
    @discardableResult
    public func name(for texture: SKTexture) -> UInt32 {
        if let page = texture.page {
            if let existing = pageNames[page] { return existing }
            let name = upload(pageSource?(page))
            pageNames[page] = name
            return name
        }

        // Not backed by the index: an atlas slice still shares its parent's
        // upload, since only the UVs differ.
        let root = texture.root
        if root.glName != 0 { return root.glName }
        let name = upload(pixelSource?(root))
        root.glName = name
        return name
    }

    private func upload(_ resolved: (width: Int, height: Int, pixels: Data)?) -> UInt32 {
        let name: UInt32
        if let resolved {
            name = device.createTexture(
                width: resolved.width,
                height: resolved.height,
                pixels: resolved.pixels
            )
        } else {
            // One opaque white pixel: a sprite drawn with it shows its tint,
            // which is a legible "asset missing" rather than a black hole.
            name = device.createTexture(width: 1, height: 1, pixels: Data([255, 255, 255, 255]))
        }
        if name != 0 { ownedTextures.insert(name) }
        return name
    }

    /// The GL program for a shader, translating and linking it the first time.
    @discardableResult
    public func program(for shader: SKShader) -> UInt32 {
        if shader.glProgram != 0 { return shader.glProgram }

        let attributes = shader.attributes.map { (name: $0.name, type: glslType(for: $0.type)) }
        let uniforms = shader.uniforms.map { (name: $0.name, type: glslType(for: $0.value)) }

        let fragment = ShaderTranslator.fragmentShader(
            from: shader.source,
            inputs: ShaderTranslator.Inputs(uniforms: uniforms, attributes: attributes)
        )
        let vertex = ShaderTranslator.spriteVertexShader(attributes: attributes)

        let name = device.createProgram(vertex: vertex, fragment: fragment)
        shader.glProgram = name
        if name != 0 { ownedPrograms.insert(name) }
        return name
    }

    /// Drops everything this cache uploaded. The GL context going away (an
    /// Android activity being backgrounded) invalidates every name, so the
    /// shim's slots are cleared too — see `forget(_:)`.
    public func removeAll(texturesIn textures: [SKTexture] = [], shadersIn shaders: [SKShader] = []) {
        for name in ownedTextures { device.deleteTexture(name) }
        for name in ownedPrograms { device.deleteProgram(name) }
        ownedTextures.removeAll()
        ownedPrograms.removeAll()
        pageNames.removeAll()
        for texture in textures { texture.root.glName = 0 }
        for shader in shaders { shader.glProgram = 0 }
    }

    public var uploadedTextureCount: Int { ownedTextures.count }
    public var linkedProgramCount: Int { ownedPrograms.count }

    // MARK: Types

    func glslType(for value: SKUniform.Value) -> String {
        switch value {
        case .float: return "float"
        case .vector2: return "vec2"
        case .vector3: return "vec3"
        case .vector4: return "vec4"
        case .texture: return "sampler2D"
        }
    }

    func glslType(for type: SKAttributeType) -> String {
        switch type {
        case .float, .halfFloat: return "float"
        case .vectorFloat2, .vectorHalfFloat2: return "vec2"
        case .vectorFloat3, .vectorHalfFloat3: return "vec3"
        case .vectorFloat4, .vectorHalfFloat4: return "vec4"
        case .none: return "float"
        }
    }
}
