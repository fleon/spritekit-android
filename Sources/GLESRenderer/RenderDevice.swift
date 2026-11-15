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
    /// Rewrites a texture's pixels: RGBA8, rows bottom first, at the size it
    /// was made (a mutable texture, `SKTexture.modifyPixelData`).
    func updateTexture(_ name: UInt32, width: Int, height: Int, pixels: Data)

    /// Makes a texture from RGBA8 rows already bottom first, as GL takes
    /// them, uploading them as they are.
    func createTexture(width: Int, height: Int, bottomFirst pixels: Data) -> UInt32

    /// Writes `rowCount` rows from row `y` (counting from the bottom, as GL
    /// does) of a texture `createTexture(pixels: nil)` made, from `pixels`
    /// (bottom first) at `byteOffset`: one strip of an upload spread over
    /// frames.
    func writeRows(_ name: UInt32, width: Int, y: Int, rowCount: Int, pixels: Data, byteOffset: Int)

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

    /// Whether the GPU samples ASTC (`GL_KHR_texture_compression_astc_ldr`).
    /// Without it a compressed page is decoded on the CPU and uploaded as
    /// RGBA8 (`PageImage.decodedForRGBA8`).
    var supportsASTC: Bool { get }

    /// A texture of `page`'s first `levels` levels, uploaded as they are,
    /// filtered trilinearly when there's more than one; 0 if it cannot be.
    func createTexture(compressed page: CompressedPage, levels: Int) -> UInt32

    /// Makes a texture's mip levels from its first (`levels` of them in
    /// all, or every one with 0) and has it filtered trilinearly: a page
    /// that shipped compressed, decoded for a GPU without ASTC, or an image
    /// the game asked mipmaps of (`SKTexture.usesMipmaps`).
    func generateMipmaps(_ name: UInt32, levels: Int)
}

public extension RenderDevice {
    var maximumTextureSide: Int { 2048 }
    func createTexture(width: Int, height: Int, bottomFirst pixels: Data) -> UInt32 {
        createTexture(width: width, height: height, pixels: Premultiply.flippedRows(pixels, width: width, height: height))
    }
    func writeRows(_ name: UInt32, width: Int, y: Int, rowCount: Int, pixels: Data, byteOffset: Int) {}
    func setRepeats(_ name: UInt32) {}
    func updateTexture(_ name: UInt32, width: Int, height: Int, pixels: Data) {}
    func copyRegion(of source: UInt32, x: Int, y: Int, width: Int, height: Int) -> UInt32 { 0 }
    var supportsASTC: Bool { false }
    func createTexture(compressed page: CompressedPage, levels: Int) -> UInt32 { 0 }
    func generateMipmaps(_ name: UInt32, levels: Int) {}
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
    /// Programs by the shader source and inputs they were translated from.
    private var programsBySource: [String: UInt32] = [:]
    /// GL names for packed pages, keyed by their index in `AssetIndex.pages`.
    private var pageNames: [Int: UInt32] = [:]
    /// Packed images cut out of their pages for shaders that sample them
    /// as uniforms (`samplerName(for:)`), by asset name.
    private var sliceNames: [String: UInt32] = [:]
    /// The same, clamped, for shaded sprites' own images (`imageName(for:)`).
    private var imageNames: [String: UInt32] = [:]
    private var lastPage: (number: Int, image: PageImage)?
    /// Whole compressed pages uploaded again with level 0 alone, for shaders
    /// (`plainName(forPage:)`), by page.
    private var plainPages: [Int: UInt32] = [:]
    /// Pages whose texture is compressed, which `copyRegion` can't read.
    private var compressedPages: Set<Int> = []
    /// Images given mip levels as an unshaded sprite first drew them (`drawnName`).
    private var mipmappedImages: Set<UInt32> = []
    /// What each texture this cache owns takes on the GPU, and what it
    /// would take as RGBA8 with the same levels, by GL name.
    private var textureBytes: [UInt32: (bytes: Int, rgba: Int)] = [:]

    /// Pixels for one packed page, which the asset index names. Hundreds of
    /// assets share a page, so this is called once per page, not per asset.
    public var pageSource: ((Int) -> PageImage?)?

    /// Whether `pageSource`'s rows come bottom first, as GL takes them,
    /// turned over where they decoded rather than as they upload.
    public var pageRowsBottomFirst = false

    /// A page decoded ahead of its first draw (`SKTexture.preload`) and not
    /// uploaded yet, taken for `uploadAhead`.
    public var pageAhead: (() -> (page: Int, image: PageImage)?)?

    /// A page `uploadAhead` is part way through, and the rows it has written.
    private var partial: (page: Int, name: UInt32, image: PageImage, rows: Int)?

    /// Rows a strip of `uploadAhead` writes: a megabyte of a 2048-pixel page,
    /// about a millisecond of a phone's frame.
    static let stripRows = 128

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
            // Drawn before `uploadAhead` finished it: the rest goes now.
            if partial?.page == page {
                uploadAhead(while: { true }, finishingOnly: true)
                if let existing = pageNames[page] { return existing }
            }
            let name = uploadPage(pageSource?(page), page: page)
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
        // A mutable texture uploads again each time its pixels change.
        if let mutable = root.mutablePixels {
            if root.glName == 0 {
                root.glName = device.createTexture(width: mutable.width, height: mutable.height, pixels: nil)
                if root.glName != 0 { own(root.glName, width: mutable.width, height: mutable.height) }
                root.uploadedRevision = -1
            }
            if root.glName != 0, root.uploadedRevision != root.revision {
                device.updateTexture(root.glName, width: mutable.width, height: mutable.height, pixels: mutable.pixels)
                root.uploadedRevision = root.revision
            }
            return root.glName
        }
        if root.glName != 0 { return root.glName }
        let name = upload(raw: pixelSource?(root))
        root.glName = name
        return name
    }

    /// The GL name for a texture an unshaded sprite draws with: `name(for:)`,
    /// with mip levels made the first time for an image the game asked them
    /// of (`SKTexture.usesMipmaps`).
    ///
    /// Only here: a texture a shader draws keeps one level, as a whole page
    /// does (`plainName`). The rigs ask for mip levels, and their meshes now
    /// draw here as real triangles (`SKTriangleMesh`): the game's
    /// `RigMeshNode` shader picked one of four triangles a pixel, so a texture
    /// coordinate's derivative jumped across every triangle's edge and the
    /// GPU read the smallest level along it, a dotted seam over every
    /// Switchling.
    public func drawnName(for texture: SKTexture) -> UInt32 {
        let name = name(for: texture)
        let root = texture.root
        if name != 0, texture.page == nil, root.usesMipmaps, root.mutablePixels == nil, mipmappedImages.insert(name).inserted {
            mipmap(name)
        }
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
        cutOut(texture, repeats: true)
    }

    /// The texture a **shaded sprite** samples as `u_texture`: its image
    /// alone, clamped at its edges as SpriteKit's sprite textures are.
    ///
    /// On iOS the game's images are each a texture of their own, so a
    /// shader's `v_tex_coord` runs 0…1 across the image (through its 9-slice)
    /// and `CrumbleNode` reads its brick's front face at a fixed `y`. The
    /// batcher hands a shaded sprite those coordinates (`Batch.ownImage`),
    /// so this is what they index. A slice copy rather than the page, since
    /// a shader may sample anywhere in 0…1, and a page would hand it the
    /// neighbours.
    public func imageName(for texture: SKTexture) -> UInt32 {
        cutOut(texture.root, repeats: false)
    }

    /// A packed image cut out of its page once, by asset name; whole pages
    /// and textures the index does not back are what `name(for:)` gives.
    private func cutOut(_ texture: SKTexture, repeats: Bool) -> UInt32 {
        guard texture === texture.root, let entry = texture.asset, let index = AssetIndex.shared,
              index.pages.indices.contains(entry.page) else { return name(for: texture) }
        let page = index.pages[entry.page]
        if entry.rect.width >= page.size.width - 0.5, entry.rect.height >= page.size.height - 0.5 {
            return plainName(forPage: entry.page, texture: texture)
        }
        if let existing = (repeats ? sliceNames : imageNames)[entry.name] { return existing }
        func keep(_ name: UInt32) {
            if repeats { sliceNames[entry.name] = name } else { imageNames[entry.name] = name }
        }
        // Copied out of the page already uploaded, on the GPU, where the
        // device can: decoding a page again costs a second or more on a
        // phone, and a backdrop asks for several slices off several pages.
        // A compressed page can't be read that way (it can't be a
        // framebuffer's attachment); its blocks are copied instead, below.
        let pageName = name(for: texture)
        let unit = entry.textureRect
        if !compressedPages.contains(entry.page) {
            let copied = device.copyRegion(
                of: pageName,
                x: Int((unit.minX * page.size.width).rounded()), y: Int((unit.minY * page.size.height).rounded()),
                width: Int((unit.width * page.size.width).rounded()), height: Int((unit.height * page.size.height).rounded())
            )
            if copied != 0 {
                own(copied, width: Int(entry.rect.width.rounded()), height: Int(entry.rect.height.rounded()))
                if repeats { device.setRepeats(copied) }
                keep(copied)
                return copied
            }
        }
        // A page reads once for the slices cut from it in a row.
        if lastPage?.number != entry.page { lastPage = pageSource?(entry.page).map { (entry.page, $0) } }
        guard let source = lastPage?.image else { return name(for: texture) }
        let x0 = max(0, Int(entry.rect.minX.rounded())), y0 = max(0, Int(entry.rect.minY.rounded()))
        let width = min(Int(entry.rect.width.rounded()), source.width - x0)
        let height = min(Int(entry.rect.height.rounded()), source.height - y0)
        guard width > 0, height > 0 else { return name(for: texture) }
        if let compressed = source.compressed {
            // Its blocks as they are, where the image sits on block
            // boundaries (the packer puts every atlas image there) and the
            // GPU takes ASTC; else decoded on the CPU, rows bottom first.
            let bottom = source.height - y0 - height
            if device.supportsASTC, let cut = compressed.cut(x: x0, y: bottom, width: width, height: height) {
                let name = device.createTexture(compressed: cut, levels: 1)
                if name != 0 {
                    own(name, width: width, height: height, bytes: cut.byteCount)
                    if repeats { device.setRepeats(name) }
                    keep(name)
                    return name
                }
            }
            let decoded = compressed.decode(x: x0, y: bottom, width: width, height: height)
            let name = device.createTexture(width: width, height: height, bottomFirst: Data(decoded))
            if name != 0 {
                own(name, width: width, height: height)
                if repeats { device.setRepeats(name) }
            }
            keep(name)
            return name
        }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            source.pixels.withUnsafeBytes { (from: UnsafeRawBufferPointer) in
                for row in 0..<height {
                    // The slice comes out top row first, whichever way the page's rows run.
                    let pageRow = pageRowsBottomFirst ? source.height - 1 - (y0 + row) : y0 + row
                    let start = (pageRow * source.width + x0) * 4
                    out.baseAddress!.advanced(by: row * width * 4)
                        .copyMemory(from: from.baseAddress!.advanced(by: start), byteCount: width * 4)
                }
            }
        }
        let name = upload(PageImage(width: width, height: height, pixels: pixels))
        if name != 0, repeats { device.setRepeats(name) }
        keep(name)
        return name
    }

    /// A whole page for a shader: the page itself, unless it has mip levels,
    /// which a shader that tiles its image with `fract` would show as a seam
    /// (the derivative jumps where the image wraps, and the GPU reads its
    /// smallest level along it). A compressed whole page is then uploaded
    /// again with level 0 alone, as every texture was before ASTC: whole
    /// pages repeat, so this one does too.
    private func plainName(forPage page: Int, texture: SKTexture) -> UInt32 {
        let mipped = AssetIndex.shared.map { page < $0.pages.count && $0.pages[page].levels > 1 } == true
        guard mipped else { return name(for: texture) }
        if let existing = plainPages[page] { return existing }
        guard let source = pageSource?(page) else { return name(for: texture) }
        var name: UInt32 = 0
        if let compressed = source.compressed, device.supportsASTC {
            name = device.createTexture(compressed: compressed, levels: 1)
            if name != 0 {
                own(name, width: source.width, height: source.height, bytes: compressed.levels.first?.count ?? 0)
            }
        }
        if name == 0 {
            let plain = source.compressed.map { PageImage(width: source.width, height: source.height, pixels: $0.decodeLevel0()) } ?? source
            name = pageRowsBottomFirst ? uploadBottomFirst(plain) : upload(plain)
        }
        if name != 0 { device.setRepeats(name) }
        plainPages[page] = name
        return name
    }

    /// Uploads a packed page as it arrives: its ASTC levels where the GPU
    /// takes them, else its pixels (making the mip levels it shipped with).
    private func uploadPage(_ image: PageImage?, page: Int) -> UInt32 {
        guard let image else { return upload(PageImage?.none) }
        if let compressed = image.compressed {
            if device.supportsASTC {
                let name = device.createTexture(compressed: compressed, levels: compressed.levels.count)
                if name != 0 {
                    compressedPages.insert(page)
                    own(name, width: image.width, height: image.height, levels: compressed.levels.count, bytes: compressed.byteCount)
                    return name
                }
            }
            return uploadPage(image.decodedForRGBA8(), page: page)
        }
        let name = pageRowsBottomFirst ? uploadBottomFirst(image) : upload(image)
        if name != 0, image.mipLevels > 1 { mipmap(name, levels: image.mipLevels) }
        return name
    }

    /// Makes `name`'s mip levels, and counts them.
    private func mipmap(_ name: UInt32, levels: Int = 0) {
        device.generateMipmaps(name, levels: levels)
        guard let size = textureBytes[name] else { return }
        // A full chain adds a third; a short one, its levels' quarters.
        var share = 1.0, step = 1.0
        for _ in 1 ..< (levels > 0 ? levels : 16) { step /= 4; share += step }
        textureBytes[name] = (Int(Double(size.bytes) * share), Int(Double(size.rgba) * share))
    }

    /// Counts a texture this cache owns: `bytes` on the GPU (RGBA8's if not
    /// given), against RGBA8's for the same levels.
    private func own(_ name: UInt32, width: Int, height: Int, levels: Int = 1, bytes: Int? = nil) {
        ownedTextures.insert(name)
        var rgba = 0
        for level in 0 ..< max(1, levels) { rgba += max(1, width >> level) * max(1, height >> level) * 4 }
        textureBytes[name] = (bytes ?? rgba, rgba)
    }

    private func uploadBottomFirst(_ resolved: PageImage?) -> UInt32 {
        guard let resolved else { return upload(PageImage?.none) }
        let name = device.createTexture(width: resolved.width, height: resolved.height, bottomFirst: resolved.pixels)
        if name != 0 { own(name, width: resolved.width, height: resolved.height) }
        return name
    }

    /// Uploads a texture the asset index doesn't back from pixels readied
    /// off the frame thread (rows bottom first), unless it has its upload.
    public func adopt(_ texture: SKTexture, width: Int, height: Int, bottomFirst pixels: Data) {
        let root = texture.root
        guard root.glName == 0, root.page == nil, root.mutablePixels == nil else { return }
        let name = device.createTexture(width: width, height: height, bottomFirst: pixels)
        guard name != 0 else { return }
        own(name, width: width, height: height)
        root.glName = name
    }

    /// Uploads pages decoded ahead of their first draw a strip at a time,
    /// while `hasTime` says the frame has room, so a scene's art reaches the
    /// GPU over the frames the loading screen shows while it builds rather
    /// than all at once in its warm-up draw. A page drawn before it's done
    /// is finished then (`name(for:)`).
    public func uploadAhead(while hasTime: () -> Bool) {
        uploadAhead(while: hasTime, finishingOnly: false)
    }

    private func uploadAhead(while hasTime: () -> Bool, finishingOnly: Bool) {
        guard pageRowsBottomFirst else { return }
        while hasTime() {
            if partial == nil {
                guard !finishingOnly, let next = pageAhead?() else { return }
                guard pageNames[next.page] == nil else { continue }
                var image = next.image
                if image.compressed != nil {
                    // Blocks upload as they are, with no conversion: a
                    // whole page is a few milliseconds' copy, so it goes in
                    // one step. Pixels for a GPU without ASTC go in strips.
                    if device.supportsASTC {
                        pageNames[next.page] = uploadPage(image, page: next.page)
                        markRepeats(next.page)
                        continue
                    }
                    image = image.decodedForRGBA8()
                }
                guard image.width > 0, image.height > 0, image.pixels.count >= image.width * image.height * 4 else {
                    pageNames[next.page] = upload(PageImage?.none)
                    continue
                }
                let name = device.createTexture(width: image.width, height: image.height, pixels: nil)
                guard name != 0 else { return }
                own(name, width: image.width, height: image.height)
                partial = (next.page, name, image, 0)
            }
            guard var strip = partial else { return }
            let count = min(Self.stripRows, strip.image.height - strip.rows)
            device.writeRows(
                strip.name, width: strip.image.width, y: strip.rows, rowCount: count,
                pixels: strip.image.pixels, byteOffset: strip.rows * strip.image.width * 4
            )
            strip.rows += count
            guard strip.rows >= strip.image.height else {
                partial = strip
                continue
            }
            partial = nil
            pageNames[strip.page] = strip.name
            if strip.image.mipLevels > 1 { mipmap(strip.name, levels: strip.image.mipLevels) }
            markRepeats(strip.page)
            if finishingOnly { return }
        }
    }

    private func markRepeats(_ page: Int) {
        guard let name = pageNames[page], name != 0 else { return }
        if AssetIndex.shared.map({ page < $0.pages.count && $0.pages[page].repeats }) == true {
            device.setRepeats(name)
        }
    }

    private func upload(_ resolved: PageImage?) -> UInt32 {
        let name: UInt32
        let width = resolved?.width ?? 1, height = resolved?.height ?? 1
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
        if name != 0 { own(name, width: width, height: height) }
        return name
    }

    private func upload(raw resolved: (width: Int, height: Int, pixels: Data)?) -> UInt32 {
        upload(resolved.map { PageImage(width: $0.width, height: $0.height, pixels: $0.pixels) })
    }

    /// Programs built on a thread of their own, ahead of their first draw.
    public var programBuilds: ProgramBuilds?

    /// What a shader's program is built from: its source and the inputs
    /// declared for it. The game makes a new `SKShader` for many a node from
    /// the same source (each tile's, each band's), and those share a program.
    public static func programKey(for shader: SKShader) -> String {
        var key = shader.source ?? ""
        for uniform in shader.uniforms { key += "\u{1}u \(glslType(for: uniform.value)) \(uniform.name)" }
        for attribute in shader.attributes { key += "\u{1}a \(glslType(for: attribute.type)) \(attribute.name)" }
        return key
    }

    /// The program's fragment shader, translated.
    public static func fragmentSource(for shader: SKShader) -> String {
        ShaderTranslator.fragmentShader(
            from: shader.source ?? "",
            inputs: ShaderTranslator.Inputs(
                uniforms: shader.uniforms.map { (name: $0.name, type: glslType(for: $0.value)) },
                attributes: shader.attributes.map { (name: $0.name, type: glslType(for: $0.type)) }
            )
        )
    }

    /// Hands `shaders` to `programBuilds` to build ahead of their first
    /// draw, from the thread that made them.
    public static func buildAhead(_ shaders: [SKShader], in builds: ProgramBuilds) {
        let vertex = ShaderTranslator.spriteVertexShader()
        for shader in shaders {
            let key = programKey(for: shader)
            guard !builds.knows(key) else { continue }
            builds.submit(key: key, vertex: vertex, fragment: fragmentSource(for: shader))
        }
    }

    /// The GL program for a shader, translating and linking it the first time.
    @discardableResult
    public func program(for shader: SKShader) -> UInt32 {
        if shader.glProgram != 0, shader.glProgramRevision == shader.revision { return shader.glProgram }
        shader.glProgramRevision = shader.revision

        // Shared by every draw, which sets its own shader's uniforms
        // (`SceneRenderer.bind`).
        let key = Self.programKey(for: shader)
        if let shared = programsBySource[key] {
            shader.glProgram = shared
            return shared
        }
        if let built = programBuilds?.take(key) {
            ownedPrograms.insert(built)
            programsBySource[key] = built
            shader.glProgram = built
            return built
        }

        let name = device.createProgram(vertex: ShaderTranslator.spriteVertexShader(), fragment: Self.fragmentSource(for: shader))
        shader.glProgram = name
        if name != 0 {
            ownedPrograms.insert(name)
            programsBySource[key] = name
            programBuilds?.hold(key)
        }
        return name
    }

    /// Drops everything this cache uploaded. The GL context going away (an
    /// Android activity being backgrounded) invalidates every name, so the
    /// shim's slots are cleared too — see `forget(_:)`.
    public func removeAll(texturesIn textures: [SKTexture] = [], shadersIn shaders: [SKShader] = []) {
        for name in ownedTextures { device.deleteTexture(name) }
        for name in ownedPrograms { device.deleteProgram(name) }
        ownedTextures.removeAll()
        textureBytes.removeAll()
        plainPages.removeAll()
        compressedPages.removeAll()
        mipmappedImages.removeAll()
        ownedPrograms.removeAll()
        programsBySource.removeAll()
        partial = nil
        pageNames.removeAll()
        sliceNames.removeAll()
        imageNames.removeAll()
        lastPage = nil
        for texture in textures { texture.root.glName = 0 }
        for shader in shaders { shader.glProgram = 0 }
    }

    public var uploadedTextureCount: Int { ownedTextures.count }
    /// Bytes the textures this cache uploaded take on the GPU, and what
    /// they'd take as RGBA8 (with the same mip levels).
    public var uploadedTextureBytes: (gpu: Int, rgba: Int) {
        textureBytes.values.reduce((0, 0)) { ($0.0 + $1.bytes, $0.1 + $1.rgba) }
    }
    public var linkedProgramCount: Int { ownedPrograms.count }

    // MARK: Types

    static func glslType(for value: SKUniform.Value) -> String {
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

    static func glslType(for type: SKAttributeType) -> String {
        switch type {
        case .float, .halfFloat: return "float"
        case .vectorFloat2, .vectorHalfFloat2: return "vec2"
        case .vectorFloat3, .vectorHalfFloat3: return "vec3"
        case .vectorFloat4, .vectorHalfFloat4: return "vec4"
        case .none: return "float"
        }
    }
}
