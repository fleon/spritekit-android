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

    /// Switches a page to repeat wrapping. The asset index marks the pages
    /// that hold one whole tiling image; an atlas page must never be set
    /// this way or its neighbours bleed in.
    func setRepeats(_ name: UInt32)

    /// An offscreen colour target with an optional stencil attachment.
    /// Returns nil on failure, having logged it.
    func createRenderTarget(width: Int, height: Int, stencil: Bool) -> RenderTargetHandle?
    func deleteRenderTarget(_ target: RenderTargetHandle)

    /// A new texture holding `region` (in pixels, counted as GL counts a
    /// texture's own, from its first row) of the texture `source`, copied
    /// on the GPU; 0 if it cannot. The current framebuffer stays bound.
    func copyRegion(of source: UInt32, x: Int, y: Int, width: Int, height: Int) -> UInt32

    /// The longest side a texture may have. GLES 3.0 guarantees 2048; real
    /// devices give more, and an effect node covering a big screen's whole
    /// backdrop needs it.
    var maximumTextureSide: Int { get }
}

public extension RenderDevice {
    var maximumTextureSide: Int { 2048 }
    func setRepeats(_ name: UInt32) {}
    func copyRegion(of source: UInt32, x: Int, y: Int, width: Int, height: Int) -> UInt32 { 0 }
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
    /// Packed images cut out of their pages for shaders that sample them
    /// as uniforms (`samplerName(for:)`), by asset name.
    private var sliceNames: [String: UInt32] = [:]
    private var lastPage: (number: Int, image: (width: Int, height: Int, pixels: Data))?

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
            // A page the index marks as one whole tiling image may wrap.
            // Sky's planet maps need it: the shader reads them as a sphere's
            // surface and wraps longitude with `fract`, so a clamped map
            // smears its last column round the back of every planet.
            if name != 0, AssetIndex.shared.map { page < $0.pages.count && $0.pages[page].repeats } == true {
                device.setRepeats(name)
            }
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

    /// The texture a shader samples as a **uniform** (`SKUniform(name:texture:)`).
    ///
    /// SpriteKit hands such a shader the image alone: a shader that tiles
    /// it with `fract` (Kitchen's gingham, the lawns' and the seabed's
    /// grounds, the cracks' bricks) reads only its own pixels. A packed
    /// image is a slice of an atlas page, and the shader samples the page
    /// with the image's 0…1, so it would show the whole atlas. A slice is
    /// therefore cut out of its page once, into a texture of its own that
    /// wraps, the first time a shader asks for it. Whole pages, and textures
    /// the index does not back, are what `name(for:)` gives.
    public func samplerName(for texture: SKTexture) -> UInt32 {
        guard texture === texture.root, let entry = texture.asset, let index = AssetIndex.shared,
              index.pages.indices.contains(entry.page) else { return name(for: texture) }
        let page = index.pages[entry.page]
        if entry.rect.width >= page.size.width - 0.5, entry.rect.height >= page.size.height - 0.5 {
            return name(for: texture)
        }
        if let existing = sliceNames[entry.name] { return existing }
        // Copied out of the page already uploaded, on the GPU, where the
        // device can: decoding a page again costs a second or more on a
        // phone, and a backdrop asks for several slices off several pages.
        let pageName = name(for: texture)
        let unit = entry.textureRect
        let copied = device.copyRegion(
            of: pageName,
            x: Int((unit.minX * page.size.width).rounded()), y: Int((unit.minY * page.size.height).rounded()),
            width: Int((unit.width * page.size.width).rounded()), height: Int((unit.height * page.size.height).rounded())
        )
        if copied != 0 {
            ownedTextures.insert(copied)
            device.setRepeats(copied)
            sliceNames[entry.name] = copied
            return copied
        }
        // A page decodes once for the slices cut from it in a row.
        if lastPage?.number != entry.page { lastPage = pageSource?(entry.page).map { (entry.page, $0) } }
        guard let source = lastPage?.image else { return name(for: texture) }
        let x0 = max(0, Int(entry.rect.minX.rounded())), y0 = max(0, Int(entry.rect.minY.rounded()))
        let width = min(Int(entry.rect.width.rounded()), source.width - x0)
        let height = min(Int(entry.rect.height.rounded()), source.height - y0)
        guard width > 0, height > 0 else { return name(for: texture) }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            source.pixels.withUnsafeBytes { (from: UnsafeRawBufferPointer) in
                for row in 0..<height {
                    let start = ((y0 + row) * source.width + x0) * 4
                    out.baseAddress!.advanced(by: row * width * 4)
                        .copyMemory(from: from.baseAddress!.advanced(by: start), byteCount: width * 4)
                }
            }
        }
        let name = upload((width, height, pixels))
        if name != 0 { device.setRepeats(name) }
        sliceNames[entry.name] = name
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
        sliceNames.removeAll()
        lastPage = nil
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
        case .matrix2: return "mat2"
        case .matrix3: return "mat3"
        case .matrix4: return "mat4"
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
