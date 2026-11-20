import CAndroidShell
import Foundation
import GLESRenderer
import SpriteKitShim
import ShellCore
import TextShaping

/// Draws a scene graph with GLES 3.
///
/// The shell owns the window, the context and the clock; this owns every draw
/// call. Each frame it ticks the scene's actions, flattens it to a `DrawList`,
/// batches that, and walks the batches.
public final class SceneRenderer: FrameRenderer, MetalCommandExecutor {
    private let device = GLDevice()
    private let cache: ResourceCache
    private var batcher = SpriteBatcher()
    private lazy var targets = RenderTargetPool(device: device)

    /// The view the game presents its scenes in. Its bounds are in points
    /// (`pointScale` pixels each), as UIKit's are; the drawable is pixels.
    public let view: SKView
    private var drawableSize: CGSize

    /// An `SKRenderer`'s committed frames, and the target they draw into.
    private let films = FilmPasses()
    /// Targets free for a film's next frame; one is held by each frame
    /// waiting to be read back (`filmReadbacks`).
    private var freeFilmTargets: [RenderTargetHandle] = []
    /// A film frame read back from GL, rows bottom first, before it's turned
    /// over into the film's pixel buffer.
    /// Films' frames drawn and not yet read back: read at the top of the
    /// next frame (`collectFilmReadbacks`), once the GPU has drawn them, so
    /// the frame thread never waits for the GPU to catch up.
    private var filmReadbacks: [FilmReadback] = []
    /// How long a frame waits for a film being made to commit its next.
    private static let filmTurnWait: TimeInterval = 0.012

    /// The frame's sprites and composites, written once a frame (`stage`).
    private var vao: GLuint = 0
    private var vbo: GLuint = 0
    private var ebo: GLuint = 0
    /// What's drawn as it comes (text, shapes, bakes): written draw by draw.
    private var dynamicVAO: GLuint = 0
    private var dynamicVBO: GLuint = 0
    private var dynamicEBO: GLuint = 0
    /// The GL state as last set (`GLStateCache`).
    private var state = GLStateCache()
    private var defaultProgram: GLuint = 0
    /// Glyphs and rasterised shape masks: 8-bit coverage, the node's colour.
    private var coverageProgram: GLuint = 0
    /// A shape's fill or stroke with a texture: coverage times the texture.
    private var texturedCoverageProgram: GLuint = 0
    /// An `SKCropNode`'s mask, written into the stencil.
    private var maskProgram: GLuint = 0
    /// A crop drawn offscreen, its contents times its mask (`CropCompositing`).
    private var cropCompositeProgram: GLuint = 0
    /// A shape as a crop's mask: its coverage, cut at half.
    private var shapeMaskProgram: GLuint = 0

    private let glyphPages = GlyphPages(atlas: TextEngine.shared.atlas)
    /// The atlas's colour pages (emoji), RGBA.
    private let colourPages = GlyphPages(atlas: TextEngine.shared.atlas, colour: true)
    private var colourGlyphProgram: GLuint = 0
    private let glyphSource = EngineGlyphSource(engine: TextEngine.shared)
    private let shapeMasks = ShapeMasks()
    /// Shapes as triangles in the sprite batches; what it can't take
    /// (textured, crossing itself, a crop's mask) falls to `shapeMasks`.
    private let shapeMeshes = ShapeMeshes()
    /// Whether pages decode in software here, where the frame on screen
    /// may draw without one still decoding (`ResourceCache.defersPages`).
    private var defersPagesOnScreen = false

    /// Pixels per point, so glyphs are rasterised and masks filled at the
    /// density they are drawn at rather than at one pixel per point.
    private var deviceScale: CGFloat = 1

    /// Pixels for a packed page, by its index in `AssetIndex.pages`.
    private let pageLoader: (Int) -> PageImage?
    /// Pages `SKTexture.preload` decoded off the frame thread, for their upload.
    private let pageDecodes: PageDecodes
    /// Shaders a build made, for their programs ahead of their first draw.
    private let warmQueue = ShaderWarmQueue()
    /// Drawn surfaces and image pages readied off the frame thread, for their upload.
    private let textureQueue = TextureWarmQueue()
    /// The pages a launch's first seconds draw, for the next to decode early.
    private var launchPages: LaunchPages?
    /// When the renderer was made: the launch, near enough.
    private let launchStart = MediaTime.source()
    /// Where programs are linked off the frame thread, while the context lasts.
    private var builder: GLBuilderThread?
    /// How much of a frame building programs and uploading pages ahead of
    /// their first draw may take (`warmAhead`): a scene's GPU work spread
    /// over the frames a loading screen shows while it builds, rather
    /// than seconds of it in one warm-up draw.
    static let warmBudget: TimeInterval = 0.004

    /// Set once the first frame has been drawn, so the log says it happened
    /// exactly once rather than every frame.
    private var reportedFirstFrame = false
    /// Each scene's first frame and the launch's long frames, to logcat.
    private var timings = LaunchTimings()

    /// Frame times and per-frame counts, to logcat every few seconds.
    private var report = FrameReport()
    public var reportLabel: String = "" {
        didSet { report.begin(reportLabel) }
    }

    // MARK: The frame's state
    //
    // A pass needs to know what it is drawing into — which framebuffer, how
    // big it is, what scene rect it shows and what a shader's `gl_FragCoord`
    // means there. Nested effect and crop passes push and pop it. The
    // projection stays a parameter, threaded as the text and shape passes
    // already thread it.

    private struct Target {
        var framebuffer: GLuint
        var widthInPixels: Int
        var heightInPixels: Int
        /// The scene (or node) rect the target shows.
        var visible: CGRect
        var fragSpace: FragCoordSpace
        /// Pixels per scene point, which an effect node inside renders at.
        var density: CGFloat
        /// The only pixels drawn, if not all (`drawBandBlur`).
        var scissor: BandBlurPlan.PixelRect?
        /// The pixels the scene rect maps onto, if not the whole target: a
        /// band's strip in the strips' shared texture (`drawBandBlur`).
        var viewport: BandBlurPlan.PixelRect?

        init(
            framebuffer: GLuint, widthInPixels: Int, heightInPixels: Int, visible: CGRect,
            fragSpace: FragCoordSpace, density: CGFloat? = nil, scissor: BandBlurPlan.PixelRect? = nil
        ) {
            self.framebuffer = framebuffer
            self.widthInPixels = widthInPixels
            self.heightInPixels = heightInPixels
            self.visible = visible
            self.fragSpace = fragSpace
            self.density = density ?? (visible.height > 0 ? CGFloat(heightInPixels) / visible.height : 1)
            self.scissor = scissor
        }
    }

    private var target = Target(
        framebuffer: 0, widthInPixels: 0, heightInPixels: 0,
        visible: .zero, fragSpace: .target(heightInPixels: 0)
    )

    /// How deep the crop nodes are nested, which is also the stencil value
    /// the contents at this level must match.
    private var cropDepth: Int32 = 0
    /// The scissor GL holds now (nil: off).
    private var appliedScissor: BandBlurPlan.PixelRect?
    /// Whether the edge blur blurs only its bands (`drawBandBlur`), rather
    /// than passing the whole effect node through a texture of its own.
    public var blursBandsOnly = true
    /// Set while the frame on screen draws: films and bakes keep the
    /// effect node as it is.
    private var drawingScreen = false
    /// Rasterizing effect nodes drawn this frame, so the pool can drop the
    /// targets of ones that went away.
    private var liveKept: Set<RenderTargetPool.Key> = []
    /// Set once per build, so a mask carrying its own shader is reported
    /// rather than quietly clipped to the wrong shape.
    private var warnedShadedMask = false
    private var clampedEffects: Set<ObjectIdentifier> = []
    /// Textures handed to the game by `texture(from:)`, each deleted once
    /// the game lets go of it (`BakedTextures`).
    private var bakedTextures = BakedTextures()

    // MARK: The frame's tally, for the performance report

    public private(set) var drawCalls = 0
    public private(set) var targetBinds = 0
    public private(set) var effectsDrawn = 0
    /// Crops drawn offscreen and multiplied by their mask (`CropCompositing`).
    public private(set) var cropsComposited = 0
    public private(set) var effectsCached = 0
    public private(set) var quadsDrawn = 0
    /// What the GPU holds in textures (`GLDevice.liveTextureBytes`).
    public var liveTextureBytes: Int { device.liveTextureBytes }
    /// Nodes in the scene that aren't hidden, nor under a hidden one: what
    /// SpriteKit's node count shows.
    public var visibleNodeCount: Int {
        guard let scene = view.scene else { return 0 }
        var count = 0
        var stack: [SKNode] = [scene]
        while let node = stack.popLast() {
            guard !node.isHidden else { continue }
            count += 1
            stack.append(contentsOf: node.children)
        }
        return count
    }
    /// The textures the cache uploaded, and what they take on the GPU
    /// against what they'd take as RGBA8.
    public var textureCount: Int { cache.uploadedTextureCount }
    public var textureBytes: (gpu: Int, rgba: Int) { cache.uploadedTextureBytes }
    /// Buffer maps this frame: two for the staged stream, two for each
    /// draw written as it comes.
    public private(set) var streamMaps = 0

    /// Where each per-node attribute sits in each program, looked up once.
    /// A triangle-mesh sprite carries twelve of them and a skeletal rig is
    /// dozens of sprites, so this is a few thousand `glGetAttribLocation`
    /// calls a frame if it is not kept.
    private var attributeLocations: [GLuint: [String: GLint]] = [:]

    /// Where each uniform sits in each program, looked up once: a frame
    /// binds a few hundred sprites' uniforms, and Mali's
    /// `glGetUniformLocation` is a name lookup in the driver each time.
    private var uniformLocations: [GLuint: [String: GLint]] = [:]

    /// The frame's batches and composites go into one vertex and one index
    /// buffer, each mapped once (`stage`), their indices counting from the
    /// buffer's start so the vertex attributes are pointed once, when the
    /// buffers are made. Re-specifying a buffer for every draw makes a
    /// tiler's driver find new memory a few hundred times a frame while the
    /// GPU still holds the old.
    private var stagedVertexCapacity = 0
    private var stagedIndexCapacity = 0
    /// The capacities the stores were last given (`RenderPoison.stream`).
    private var stagedStores = (0, 0)
    /// Composite quads staged with the frame, by their effect node.
    private var stagedComposites: [ObjectIdentifier: SpriteBatcher.Batch] = [:]
    /// Each rasterizing effect node's contents as last batched, for a kept
    /// target that must draw again although the batcher left its contents
    /// out as fresh (`rasterIsFresh`): a new size (the render scale moved).
    private var rasterContents: [ObjectIdentifier: [SpriteBatcher.Pass]] = [:]
    /// The nodes whose contents the batcher left out this frame.
    private var skippedRaster: Set<ObjectIdentifier> = []

    /// The share of the screen's pixels the scene draws at. Below 1 the
    /// shell sizes the window's buffers to it and the display's compositor
    /// stretches them onto the screen (`surfaceScale`); until it has, and
    /// where Android won't, the scene draws into `sceneTarget` and is
    /// stretched onto the screen as the frame ends. Either way a phone's GPU
    /// that can't fill every pixel of a 1080 × 2340 screen a frame (a
    /// Mali-G72 MP3's) fills fewer.
    /// Shaders still count the screen's own pixels (`FragCoordSpace`), so
    /// the lights and the edge blur land where they do at full size.
    public var renderScale: CGFloat = 1
    /// Told the rate and scale drawn at whenever they change.
    public var onRunning: ((Int, Double) -> Void)?
    /// Told the scale Auto chose for the device, at its rate: kept, so it
    /// never chooses again there.
    public var onChosen: ((Int, Double) -> Void)?
    /// Whether a scene's frames measure how the game draws (a game may leave
    /// out its loading screen's).
    public var measuresScene: (SKScene?) -> Bool = { $0 != nil }
    /// Set once something chose `renderScale` (`debug.<app>.renderscale`):
    /// the governor leaves it alone.
    public var pinsRenderScale = false
    private var sceneTarget: RenderTargetHandle = .none
    /// Chooses `renderScale` once for the device from how frames keep time
    /// (`RenderScaleGovernor`), among the scales `configure` offers it.
    private var governor = RenderScaleGovernor()
    private var governs = false
    /// The rate the view draws at now. The scale the governor chooses waits
    /// for the next scene (`sceneShown`), as Apple's does, so nothing
    /// changes under a scene being played.
    private var appliedRate = RenderScaleGovernor.fastestAutoRate
    /// The scene drawn last, to catch a new one.
    private weak var lastScene: SKScene?

    /// Draws at `rate`, among `scales` (largest first; one where picked),
    /// the governor choosing between them if `governs`: `decided` if the
    /// device chose before, else measuring at the largest. Applied at once;
    /// `fromCurrent` keeps a measure under way when the rate and scales
    /// stay as they were.
    public func configure(rate: Int, scales: [Double], governs: Bool, decided: Double? = nil, fromCurrent: Bool = false) {
        let scales = pinsRenderScale ? [Double(renderScale)] : scales
        // A pinned scale measures nothing, as Apple's doesn't.
        let governs = governs && !pinsRenderScale
        if !(fromCurrent && rate == governor.rate && scales == governor.scales && governs == self.governs) {
            governor = RenderScaleGovernor(rate: rate, scales: scales, decided: decided)
        }
        self.governs = governs
        apply(rate: governor.rate)
    }

    /// The governor's rate and scale (unless pinned), now.
    private func apply(rate: Int) {
        appliedRate = rate
        view.preferredFramesPerSecond = rate
        if !pinsRenderScale { renderScale = CGFloat(governor.scale) }
        onRunning?(appliedRate, Double(renderScale))
    }

    /// A new scene: a scale the governor chose applies, and its first
    /// frames start a window afresh.
    private func sceneShown() {
        governor.startScene()
        if !drawsGovernorRung {
            apply(rate: governor.rate)
        }
    }

    /// Whether the view draws at the governor's rung.
    private var drawsGovernorRung: Bool {
        governor.rate == appliedRate && (pinsRenderScale || CGFloat(governor.scale) == renderScale)
    }

    /// One refresh of the display: a frame's budget, at the most.
    private var refreshInterval = 1.0 / 60

    /// Shows `scene` from the first frame.
    public convenience init(
        scene: SKScene,
        drawableSize: CGSize,
        pointScale: CGFloat,
        pageLoader: @escaping (Int) -> PageImage?
    ) {
        self.init(drawableSize: drawableSize, pointScale: pointScale, pageLoader: pageLoader) {
            $0.presentScene(scene)
        }
    }

    /// Hands `start` the view, which presents what it likes in it — through
    /// the game's own transitions, say.
    public init(
        drawableSize: CGSize,
        pointScale: CGFloat,
        pageLoader: @escaping (Int) -> PageImage?,
        start: @escaping (SKView) -> Void
    ) {
        self.pageLoader = pageLoader
        self.drawableSize = drawableSize
        cache = ResourceCache(device: device)
        view = SKView(bounds: CGRect(origin: .zero, size: Self.points(drawableSize, scale: pointScale)))
        view.contentScaleFactor = pointScale
        // The pages decode straight, as PNGs hold them; SpriteKit's
        // textures, and so the blend and the game's shaders, are
        // premultiplied (`Premultiply`).
        // Decoded wherever they're asked for: off the frame thread when the
        // game preloads them, as SpriteKit does (`PageDecodes`), else here
        // as they first draw. The log says which, and how long it took.
        // A compressed page is read as it ships, unless the GPU can't
        // sample ASTC, when it's decoded here instead (`GLDevice.supportsASTC`,
        // asked now, on the frame thread, while the context is current).
        let astc = GLDevice.astcSupported
        Log.info(astc ? "texture path: ASTC, with mip levels" : "texture path: RGBA8, decoded from ASTC on the CPU (no GL_KHR_texture_compression_astc_ldr)")
        let decodes = PageDecodes { number in
            let started = DispatchTime.now().uptimeNanoseconds
            let page = pageLoader(number).map { page -> PageImage in
                if page.compressed != nil { return astc ? page : page.decodedForRGBA8() }
                return PageImage(width: page.width, height: page.height, pixels: Premultiply.rgbaFlipped(page.pixels, width: page.width, height: page.height))
            }
            let took = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            Log.info("page \(number) decoded in \(String(format: "%.0f", took)) ms on the \(Thread.isMainThread ? "frame thread" : "preloading thread")")
            return page
        }
        pageDecodes = decodes
        cache.pageRowsBottomFirst = true
        cache.pageAhead = { decodes.takeNextReady() }
        // Decoded in software (no ASTC on the GPU), a page takes seconds on
        // an emulator: the frame on screen draws without it meanwhile.
        defersPagesOnScreen = !astc
        cache.pageIsReady = { decodes.isWaiting($0) }
        cache.pageWanted = { decodes.prefetch($0) }
        let launchPages = LaunchPages()
        self.launchPages = launchPages
        let launched = MediaTime.source()
        cache.pageSource = { page in
            launchPages.note(page, at: MediaTime.source() - launched)
            return FrameCosts.time(.pageWaits) { decodes.take(page) }
        }
        // What the last launch's splash and first scene drew starts
        // decoding now, while the splash shows.
        for page in launchPages.remembered { decodes.prefetch(page) }
        // Textures the asset index does not back: the noise lattices the
        // shaders sample (an `SKTexture(data:size:)` a game fills with
        // noise for its shaders to read), and solid-colour stand-ins. Without
        // this they upload as one white pixel, and a shader reading constant
        // noise draws something plausible rather than nothing — a flat sky
        // with no clouds, which is how this was found.
        cache.pixelSource = Self.pixels(of:)
        self.start = start
    }

    /// What presents the first scene, run once the GL state and the bake
    /// hook (`SKView.snapshot`) exist, at the end of `rendererDidStart`: a
    /// scene that bakes as it joins the view (one calling
    /// `SKView.texture(from:)` in `didMove`) would otherwise bake into
    /// nothing and keep that.
    private var start: ((SKView) -> Void)?

    private static func points(_ pixels: CGSize, scale: CGFloat) -> CGSize {
        scale > 0 ? CGSize(width: pixels.width / scale, height: pixels.height / scale) : pixels
    }

    // MARK: Lifecycle

    public func rendererDidStart(_ context: RenderContext) {
        Log.info("GLSL \(context.shadingLanguageVersion)")

        // A triangle-mesh sprite carries four triangles as twelve vec4 uniforms
        // of its fragment stage (`bind(_:program:shader:)`), on top of the
        // lights its lit shaders declare.
        var maxFragmentVectors: GLint = 0
        glGetIntegerv(GLenum(GL_MAX_FRAGMENT_UNIFORM_VECTORS), &maxFragmentVectors)
        Log.info("max fragment uniform vectors \(maxFragmentVectors)")

        // Programs linked before are loaded rather than built again
        // (`ProgramCache`): made once, the first time a context starts.
        if device.programCache == nil {
            device.programCache = ProgramCache(
                driver: [GL_VENDOR, GL_RENDERER, GL_VERSION].map { Self.glString(GLenum($0)) }.joined(separator: "|")
            )
        }

        state.forgetAll()
        // Two vertex arrays, each over its own pair of buffers, its
        // attributes pointed once at the buffer's start: indices count from
        // there (`stage`, `uploadDynamic`).
        func vertexArray(_ array: inout GLuint, _ vertices: inout GLuint, _ indices: inout GLuint) {
            glGenVertexArrays(1, &array)
            glBindVertexArray(array)
            glGenBuffers(1, &vertices)
            glGenBuffers(1, &indices)
            glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertices)
            glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), indices)

            // The batcher's interleaving: x y u v r g b a blend.
            let stride = GLsizei(Self.vertexStride)
            func attribute(_ index: GLuint, _ count: GLint, _ offsetInFloats: Int) {
                glEnableVertexAttribArray(index)
                glVertexAttribPointer(
                    index, count, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride,
                    UnsafeRawPointer(bitPattern: offsetInFloats * MemoryLayout<Float>.size)
                )
            }
            attribute(GLDevice.Attribute.position, 2, 0)
            attribute(GLDevice.Attribute.texCoord, 2, 2)
            attribute(GLDevice.Attribute.colorMix, 4, 4)
            attribute(GLDevice.Attribute.blend, 1, 8)
        }
        vertexArray(&vao, &vbo, &ebo)
        vertexArray(&dynamicVAO, &dynamicVBO, &dynamicEBO)
        glBindVertexArray(0)

        defaultProgram = device.createProgram(
            vertex: ShaderTranslator.spriteVertexShader(),
            fragment: ShaderTranslator.defaultFragmentShader
        )
        if defaultProgram == 0 { Log.error("the default sprite program did not link") }

        coverageProgram = device.createProgram(
            vertex: ShaderTranslator.spriteVertexShader(),
            fragment: ShaderTranslator.coverageFragmentShader
        )
        if coverageProgram == 0 { Log.error("the coverage program did not link") }

        colourGlyphProgram = device.createProgram(
            vertex: ShaderTranslator.spriteVertexShader(),
            fragment: ShaderTranslator.colourGlyphFragmentShader
        )
        if colourGlyphProgram == 0 { Log.error("the colour glyph program did not link") }

        texturedCoverageProgram = device.createProgram(
            vertex: ShaderTranslator.spriteVertexShader(),
            fragment: ShaderTranslator.texturedCoverageFragmentShader
        )
        if texturedCoverageProgram == 0 { Log.error("the textured coverage program did not link") }

        maskProgram = device.createProgram(
            vertex: ShaderTranslator.spriteVertexShader(),
            fragment: ShaderTranslator.maskFragmentShader
        )
        if maskProgram == 0 { Log.error("the crop mask program did not link") }

        cropCompositeProgram = device.createProgram(
            vertex: ShaderTranslator.spriteVertexShader(),
            fragment: ShaderTranslator.cropCompositeFragmentShader
        )
        if cropCompositeProgram == 0 { Log.error("the crop composite program did not link") }

        shapeMaskProgram = device.createProgram(
            vertex: ShaderTranslator.spriteVertexShader(),
            fragment: ShaderTranslator.coverageMaskFragmentShader
        )
        if shapeMaskProgram == 0 { Log.error("the shape mask program did not link") }

        // The art is premultiplied, so this is the blend for it.
        setBlend(.alpha)
        glDisable(GLenum(GL_DEPTH_TEST))
        glClearColor(0, 0, 0, 1)

        // `SKView.texture(from:)` goes through this: the game asks its view for a texture of a subtree, and only
        // the renderer can answer, since only it has a framebuffer. The hook
        // is `SKViewSnapshot.swift`'s, which also explains why the priming
        // calls that throw the texture away need no pixels here.
        // Both draw or read with GL, whose context is current on the frame
        // thread alone; called from another they'd draw nothing, or into
        // whatever the frame thread had bound (as `texture(from:)` off
        // SpriteKit's main thread is wrong on Apple too). Refused, loudly.
        SKTexture.readBack = { [weak self] texture in
            guard Self.onGLThread("cgImage() of a baked texture") else { return nil }
            return self?.readBack(texture)
        }
        SKView.snapshot = { [weak self] _, node, crop in
            guard Self.onGLThread("SKView.texture(from:)") else { return nil }
            return self?.bake(node, crop: crop)
        }
        SKTexture.pageDecoder = { [pageDecodes] in pageDecodes.decode($0.sorted()) }
        SKTexture.pageWanted = { [pageDecodes] in pageDecodes.prefetch($0) }
        SKTexture.imageWarmer = { [textureQueue] textures in
            for texture in textures {
                guard let image = Self.pixels(of: texture) else { continue }
                textureQueue.add((texture, image.width, image.height, Premultiply.flippedRows(image.pixels, width: image.width, height: image.height)))
            }
        }
        // Programs are linked on a context of their own, off the frame
        // thread, where EGL can share one; else a few a frame here.
        if let builder = GLBuilderThread() {
            let device = device
            let builds = ProgramBuilds(schedule: { builder.async($0) }) { vertex, fragment in
                let name = device.createProgram(vertex: vertex, fragment: fragment)
                // Complete before the frame thread's context uses it.
                glFinish()
                return name
            }
            builds.waited = { FrameCosts.add(.programWaits, $0) }
            self.builder = builder
            cache.programBuilds = builds
            SKShader.programWarmer = { ResourceCache.buildAhead($0, in: builds) }
            Log.info("programs build on a shared context")
        } else {
            SKShader.programWarmer = { [warmQueue] in warmQueue.add($0) }
        }

        // `SKRenderer`'s command buffers (an offscreen render) draw here, on this
        // context, at the top of each frame.
        MetalExecution.executor = self

        batcher.shapeMeshes = shapeMeshes
        batcher.rasterIsFresh = { [weak self] owner, generation, digest in
            guard let self, rasterContents[owner] != nil,
                  targets.isFresh(.init(owner: owner), generation: generation, contents: digest) else { return false }
            skippedRaster.insert(owner)
            return true
        }

        Log.info("max texture side \(device.maximumTextureSide)")
        if let start {
            self.start = nil
            start(view)
        }
    }

    public func drawableSizeDidChange(to size: CGSize) {
        drawableSize = size
        view.bounds = CGRect(origin: .zero, size: Self.points(size, scale: view.contentScaleFactor))
        glViewport(0, 0, GLsizei(size.width), GLsizei(size.height))
        Log.info("drawable \(Int(size.width)) x \(Int(size.height))")
    }

    public func rendererWillStop() {
        SKView.snapshot = nil
        SKTexture.readBack = nil
        SKTexture.pageDecoder = nil
        SKTexture.pageWanted = nil
        SKTexture.imageWarmer = nil
        textureQueue.removeAll()
        SKShader.programWarmer = nil
        _ = warmQueue.removeAll()
        builder?.stop()
        builder = nil
        for name in cache.programBuilds?.removeAll() ?? [] { device.deleteProgram(name) }
        cache.programBuilds = nil
        if MetalExecution.executor === self { MetalExecution.executor = nil }
        films.failAll()
        for readback in filmReadbacks {
            for pass in readback.passes { device.deleteRenderTarget(pass.target) }
            readback.commands.complete(error: MTLCommandBufferError("the renderer stopped"))
        }
        filmReadbacks.removeAll()
        for kept in freeFilmTargets { device.deleteRenderTarget(kept) }
        freeFilmTargets.removeAll()
        for name in bakedTextures.removeAll() { device.deleteTexture(name) }
        targets.removeAll()
        cache.removeAll()
        pageDecodes.forgetResident()
        glyphPages.removeAll()
        colourPages.removeAll()
        shapeMasks.removeAll()
        shapeMeshes.removeAll()
        glyphSource.flush()
        if coverageProgram != 0 { device.deleteProgram(coverageProgram) }
        if colourGlyphProgram != 0 { device.deleteProgram(colourGlyphProgram) }
        if texturedCoverageProgram != 0 { device.deleteProgram(texturedCoverageProgram) }
        if maskProgram != 0 { device.deleteProgram(maskProgram) }
        if cropCompositeProgram != 0 { device.deleteProgram(cropCompositeProgram) }
        if shapeMaskProgram != 0 { device.deleteProgram(shapeMaskProgram) }
        if alongSamplerName != 0 { glDeleteSamplers(1, &alongSamplerName) }
        alongSamplerName = 0
        // A new context relinks every program, and GL reuses names, so a
        // location learned for an old one must not be trusted again.
        attributeLocations.removeAll()
        uniformLocations.removeAll()
        state.forgetAll()
        if sceneTarget.isValid { device.deleteRenderTarget(sceneTarget) }
        sceneTarget = .none
        stagedVertexCapacity = 0
        stagedIndexCapacity = 0
        stagedStores = (0, 0)
        stagedComposites.removeAll()
        rasterContents.removeAll()
        skippedRaster.removeAll()
        if defaultProgram != 0 { device.deleteProgram(defaultProgram) }
        glDeleteBuffers(1, &vbo)
        glDeleteBuffers(1, &ebo)
        glDeleteVertexArrays(1, &vao)
        glDeleteBuffers(1, &dynamicVBO)
        glDeleteBuffers(1, &dynamicEBO)
        glDeleteVertexArrays(1, &dynamicVAO)
    }

    // MARK: Frames

    /// The view's frame rate, pause and delegate decide.
    public func shouldDraw(_ frame: Frame) -> Bool {
        // An `SKRenderer`'s frames first: asking the view takes its turn
        // from a game filming through the view's delegate.
        drawFilmPasses()
        let draws = view.shouldRender(atTime: frame.time)
        // Asked again after a frame was swapped: so once the view pauses (a
        // game holding a still), the frame it paused in is on screen, and a tool
        // timing a capture by the still can take the screen now.
        if view.isPaused != heldLogged {
            heldLogged = view.isPaused
            if view.isPaused { Log.info("view held: its last frame is on screen") }
        }
        return draws
    }

    /// Whether the view's pause has been logged (`shouldDraw`).
    private var heldLogged = false

    /// Whether the game waits on work off the main thread
    /// (`GameHost.holdsFrameClock`, with `-FixedFrameStep`); the backend sets
    /// it.
    public var clockHold: () -> Bool = { false }
    public var holdsClock: Bool { clockHold() }

    public func drawFrame(_ frame: Frame) {
        // A page still decoding is left out of this frame, not waited for
        // (`ResourceCache.defersPages`), in play; a capture's stills and what's
        // kept as drawn wait.
        cache.defersPages = ResourceCache.defersPages(
            decodesInSoftware: defersPagesOnScreen, fixedFrameStep: MediaTime.fixedStep, clockHeld: holdsClock
        )
        defer { cache.defersPages = false }
        // The scene first: a transition, or a scene presenting another, can
        // change which scene the view shows, and the projection is that
        // scene's.
        let started = MediaTime.source()
        FrameCosts.reset()
        // Colour glyph pages last drawn from before this frame may be emptied.
        TextEngine.shared.atlas.nextFrame()
        let list = view.tick(currentTime: frame.time, delta: frame.delta / max(slowdown, 1))
        SceneDump.check(view, at: frame.time)
        noteSceneChange(at: frame.time)
        let ticked = MediaTime.source()
        // Shapes are tessellated as they're batched, for the density the
        // scene is drawn at: the screen's, times the share of it drawn.
        shapeMeshes.screenPixelsPerPoint = max(viewport.scale.x, viewport.scale.y)
        shapeMeshes.pixelsPerPoint = shapeMeshes.screenPixelsPerPoint * drawnFraction(of: frame)
        let passes = batcher.passes(for: list)
        // Ticking the actions, flattening the scene graph and batching it:
        // the runtime's own cost, with no GL in it. Worth separating, because
        // the rest of the frame on an emulator is mostly the host GL pipe
        // and says little about a phone, while this number carries across.
        let flattened = MediaTime.source()

        let projection = viewport.projection
        deviceScale = max(viewport.scale.x, viewport.scale.y)
        glyphSource.deviceScale = deviceScale

        let screenWidth = Int(frame.size.width)
        let screenHeight = Int(frame.size.height)
        // The window's buffer: the screen's size, or smaller once the shell
        // has the display stretch it (`surfaceScale`).
        let surfaceWidth = Int(frame.surfaceSize.width)
        let surfaceHeight = Int(frame.surfaceSize.height)
        let surfaceScaled = surfaceWidth < screenWidth || surfaceHeight < screenHeight
        let scene = sceneDrawTarget(screenWidth: screenWidth, screenHeight: screenHeight, surfaceScaled: surfaceScaled)
        let drawnWidth = scene.isValid ? scene.width : surfaceWidth
        let drawnHeight = scene.isValid ? scene.height : surfaceHeight
        target = Target(
            framebuffer: scene.framebuffer,
            widthInPixels: drawnWidth,
            heightInPixels: drawnHeight,
            visible: viewport.visibleSceneRect,
            // Shaders count the screen's own pixels however many are drawn.
            fragSpace: drawnWidth != screenWidth || drawnHeight != screenHeight
                ? FragCoordSpace(
                    offsetX: 0, offsetY: Float(screenHeight),
                    scaleX: Float(screenWidth) / Float(drawnWidth),
                    scaleY: -Float(screenHeight) / Float(drawnHeight)
                )
                : .target(heightInPixels: screenHeight)
        )
        bindTarget()
        RenderPoison.fillTarget()
        glClearColor(0, 0, 0, 1)
        // The stencil clears with the colour: every crop node is balanced
        // (it increments on the way in and decrements on the way out), so a
        // frame starts with the buffer already zero — but a lost context or
        // a half-drawn frame would otherwise leave a stale mask behind.
        glClearStencil(0)
        // A clear writes only the stencil bits the mask lets through.
        glStencilMask(0xFF)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT) | GLbitfield(GL_STENCIL_BUFFER_BIT))

        drawCalls = 0
        targetBinds = 1
        effectsDrawn = 0
        cropsComposited = 0
        effectsCached = 0
        quadsDrawn = 0
        streamMaps = 0
        liveKept.removeAll(keepingCapacity: true)
        cropDepth = 0

        state.forgetTextures()
        let staged = stage(passes)
        drawingScreen = true
        draw(staged, projection: projection, time: Float(frame.time))
        drawingScreen = false
        stagedComposites.removeAll(keepingCapacity: true)
        bindVertexArray(0)

        if scene.isValid {
            present(scene, screenWidth: screenWidth, screenHeight: screenHeight)
        } else {
            // Nothing reads the stencil back: a tiler needn't write it out.
            var stencil = GLenum(GL_STENCIL)
            glInvalidateFramebuffer(GLenum(GL_FRAMEBUFFER), 1, &stencil)
        }
        if view.scene !== lastScene {
            lastScene = view.scene
            sceneShown()
        } else if governs, !governor.isDecided, measuresScene(view.scene) {
            // A frame's budget is a refresh, or longer at a slower rate.
            let budget = max(refreshInterval, 1 / Double(max(appliedRate, 1)))
            // Judged by the wall clock, as before frames were paced: `delta`
            // is rounded to whole refreshes. What it chooses is drawn from
            // the next scene on (`sceneShown`).
            if governor.add(frame: frame.interval, budget: budget) {
                onChosen?(governor.rate, governor.scale)
            }
        }

        targets.evictKept(except: liveKept)
        targets.endFrame()
        if rasterContents.count > liveKept.count {
            rasterContents = rasterContents.filter { liveKept.contains(.init(owner: $0.key)) }
        }
        skippedRaster.removeAll(keepingCapacity: true)
        warmAhead()
        launchPages?.writeIfDue(at: MediaTime.source() - launchStart)

        if !pendingCaptures.isEmpty {
            let image = readScreen(
                width: surfaceWidth, height: surfaceHeight,
                stretchedTo: (screenWidth, screenHeight)
            )
            let waiting = pendingCaptures
            pendingCaptures.removeAll()
            for done in waiting { done(image) }
        }

        if !reportedFirstFrame {
            reportedFirstFrame = true
            Log.info("first frame: \(quadsDrawn) quads, \(drawCalls) draw calls, \(targetBinds) target binds")
        }
        timings.drew(view.scene, interval: frame.interval) { [device] in device.programCache?.summary ?? "" }
        FrameCosts.report(tick: ticked - started, draw: MediaTime.source() - ticked)
        report.add(
            delta: frame.interval,
            step: frame.delta,
            cpu: MediaTime.source() - started,
            scene: flattened - started,
            renderScale: Double(renderScale),
            budget: max(refreshInterval, 1 / Double(max(appliedRate, 1))),
            renderer: self
        )

        // Coverage is the part that could quietly cost a fortune: a glyph
        // atlas re-uploaded every frame, or a shape rasterised every frame
        // because its cache key moved. Both are cheap to get wrong and
        // invisible from a screenshot, so the counts are logged once the
        // frame loop has settled — they should have stopped rising.
        if frame.index == 300 || frame.index == 900 {
            Log.info(
                "coverage after \(frame.index) frames: "
                    + "\(glyphPages.uploads) glyph uploads (\(glyphPages.uploadedBytes / 1024) KB), "
                    + "\(shapeMasks.rasterised) masks rasterised "
                    + "(\(Int((shapeMasks.rasteriseSeconds * 1000).rounded())) ms, "
                    + "uploaded in \(Int((shapeMasks.uploadSeconds * 1000).rounded())) ms), "
                    + "\(shapeMeshes.tessellated) shapes tessellated "
                    + "(\(Int((shapeMeshes.tessellateSeconds * 1000).rounded())) ms)"
            )
        }
    }

    /// Builds programs, then uploads pages, that something will draw soon,
    /// for `warmBudget` of the frame. One program is built whatever it takes
    /// (a link can't be split), so a frame never builds none.
    private func warmAhead() {
        let started = MediaTime.source()
        func hasTime() -> Bool { MediaTime.source() - started < Self.warmBudget }
        var built = false
        while !built || hasTime(), let shader = warmQueue.next() {
            guard shader.glProgram == 0 else { continue }
            cache.program(for: shader)
            built = true
        }
        while hasTime(), let item = textureQueue.next() {
            cache.adopt(item.texture, width: item.width, height: item.height, bottomFirst: item.pixels)
        }
        cache.uploadAhead(while: hasTime)
    }

    private func draw(_ passes: [SpriteBatcher.Pass], projection: [Float], time: Float) {
        for pass in passes {
            switch pass {
            case let .batches(batches):
                for batch in batches { draw(batch, projection: projection, time: time) }

            case let .effect(bounds, transform, shader, alpha, blendMode,
                             rasterize, owner, generation, digest, contents):
                drawEffect(
                    bounds: bounds, transform: transform, shader: shader, alpha: alpha,
                    blendMode: blendMode, rasterize: rasterize, owner: owner,
                    generation: generation, digest: digest, contents: contents,
                    projection: projection, time: time
                )

            case let .crop(_, mask, contents):
                drawCrop(mask: mask, contents: contents, projection: projection, time: time)

            case let .label(label):
                draw(label, projection: projection)

            case let .shape(shape):
                draw(shape, projection: projection)

            case let .coverage(staged):
                draw(staged, projection: projection)
            }
        }
    }

    /// `SKEffectNode`: the subtree into an offscreen texture, then that
    /// texture through the node's shader.
    ///
    /// The four behaviours games depend on (`SKEffectNode`'s own note), and
    /// where each one is honoured:
    ///
    ///  - **The texture spans children that are off screen.** `bounds` is the
    ///    shim's `calculateAccumulatedFrame()`, which walks every child
    ///    whether the viewport shows it or not, and nothing here clips it to
    ///    the visible rect. That is what lets a band blur find its bands
    ///    wherever they sit.
    ///  - **It renders at the scene's density, not the node's.** The density
    ///    comes from the bound target, so an effect node magnifying a band
    ///    inside a cache it scales back down costs no resampling.
    ///  - **`gl_FragCoord` is the texture's.** The contents draw with the
    ///    texture's own space; the composite draws with a map back into it
    ///    (`EffectTexture.composite`), so a shader reading the coordinate
    ///    gets the texture's pixels even though the pixels land in the
    ///    parent. A crop node round an effect node therefore moves the band,
    ///    exactly as on iOS.
    ///  - **`v_color_mix.a` carries alpha.** The composite quad is drawn with
    ///    the node's composited alpha there, so the subtree fades as one
    ///    picture rather than child by child.
    private func drawEffect(
        bounds: CGRect,
        transform: CGAffineTransform,
        shader: SKShader?,
        alpha: CGFloat,
        blendMode: SKBlendMode,
        rasterize: Bool,
        owner: ObjectIdentifier,
        generation: UInt64,
        digest: UInt64,
        contents: [SpriteBatcher.Pass],
        projection: [Float],
        time: Float
    ) {
        // An effect node that neither shades nor caches nor fades composites
        // to exactly what drawing its children in place does, so it costs
        // nothing. This is the common case: a game may wrap a whole layer in
        // one and only turn its shader on now and then.
        guard shader != nil || rasterize || alpha < 0.999 else {
            // The contents are in the effect node's own space (`DrawList`),
            // so they are carried by its transform, as the composite would.
            draw(contents, projection: Self.concatenate(projection, transform), time: time)
            return
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Left out by the batcher as fresh: what it last drew, should the
        // target need it again after all.
        let contents = contents.isEmpty && skippedRaster.contains(owner) ? rasterContents[owner] ?? [] : contents

        if drawingScreen, blursBandsOnly, !rasterize, let shader, drawBandBlur(
            bounds: bounds, transform: transform, shader: shader, alpha: alpha, blendMode: blendMode,
            contents: contents, projection: projection, time: time
        ) {
            return
        }

        let density = target.density
        let texture = EffectTexture(
            bounds: bounds, density: density, maximumSide: device.maximumTextureSide
        )
        if texture.isClamped, clampedEffects.insert(owner).inserted {
            Log.info(
                "effect node clamped: \(Int(bounds.width))x\(Int(bounds.height)) pt at \(density)x "
                + "would be past \(device.maximumTextureSide) px, drawn at \(texture.density)x instead"
            )
        }

        let handle: RenderTargetHandle
        var needsRedraw = true
        if rasterize {
            let key = RenderTargetPool.Key(owner: owner)
            liveKept.insert(key)
            guard let kept = targets.kept(
                for: key,
                width: texture.widthInPixels, height: texture.heightInPixels,
                generation: generation, contents: digest, stencil: false
            ) else {
                draw(contents, projection: projection, time: time)
                return
            }
            handle = kept.target
            needsRedraw = kept.needsRedraw
            // A resize deletes the old target, whose name may come back.
            state.forgetTextures()
            if needsRedraw { targets.markDrawn(key, generation: generation, contents: digest) }
        } else {
            guard let transient = targets.transient(
                width: texture.widthInPixels, height: texture.heightInPixels, stencil: false
            ) else {
                draw(contents, projection: projection, time: time)
                return
            }
            handle = transient
        }

        if needsRedraw {
            effectsDrawn += 1
            let outer = target
            let outerDepth = cropDepth
            // A crop's stencil belongs to the target that holds it; an
            // offscreen target has none, so the clip is suspended for the
            // contents and restored after. Nothing in the game crops across
            // an effect boundary, and clipping again inside the texture
            // would need the mask in the texture's own coordinates.
            if outerDepth > 0 { glDisable(GLenum(GL_STENCIL_TEST)) }
            cropDepth = 0

            target = Target(
                framebuffer: handle.framebuffer,
                widthInPixels: handle.width,
                heightInPixels: handle.height,
                visible: texture.bounds,
                fragSpace: texture.contentsSpace
            )
            bindTarget()
            RenderPoison.fillTarget()
            glClearColor(0, 0, 0, 0)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            let deferredBefore = cache.deferredPages
            draw(contents, projection: texture.projection, time: time)
            // A page left out while it decodes: the kept pixels lack it, so
            // they are drawn again rather than kept.
            if rasterize, cache.deferredPages != deferredBefore { targets.markStale(.init(owner: owner)) }

            target = outer
            cropDepth = outerDepth
            bindTarget()
            glClearColor(0, 0, 0, 1)
            resumeCrops()
        } else {
            effectsCached += 1
        }

        // The composite: the effect's shader counts the pixels of the target
        // it lands in, as SpriteKit's does (a blur that finds its band on the
        // screen from `gl_FragCoord` depends on it).
        let space = target.fragSpace

        let quad = stagedComposites[owner] ?? compositeQuad(
            bounds: bounds, transform: transform, alpha: alpha, shader: shader, blendMode: blendMode
        )
        draw(quad, projection: projection, time: time, fragSpace: space, texture: handle.texture)
    }

    /// `SKCropNode`: the mask into the stencil, then the contents where it
    /// passes.
    ///
    /// SpriteKit clips by the mask node's alpha, so the mask pass discards
    /// where the mask is transparent rather than writing the whole quad.
    /// Nesting intersects: a nested crop writes only inside its parent's
    /// region, and the pass is balanced — it increments on the way in and
    /// decrements on the way out — so the buffer is back to zero afterwards
    /// and sibling crops do not inherit one another's shapes.
    /// `projection` after `transform`: a column-major 4×4 times the affine
    /// transform lifted to one.
    static func concatenate(_ projection: [Float], _ transform: CGAffineTransform) -> [Float] {
        guard projection.count == 16, !transform.isIdentity else { return projection }
        let m: [Float] = [
            Float(transform.a), Float(transform.b), 0, 0,
            Float(transform.c), Float(transform.d), 0, 0,
            0, 0, 1, 0,
            Float(transform.tx), Float(transform.ty), 0, 1,
        ]
        var out = [Float](repeating: 0, count: 16)
        for column in 0 ..< 4 {
            for row in 0 ..< 4 {
                var sum: Float = 0
                for k in 0 ..< 4 { sum += projection[k * 4 + row] * m[column * 4 + k] }
                out[column * 4 + row] = sum
            }
        }
        return out
    }

    private func drawCrop(
        mask: [SpriteBatcher.Pass],
        contents: [SpriteBatcher.Pass],
        projection: [Float],
        time: Float
    ) {
        guard !mask.isEmpty else {
            // SpriteKit draws a crop node with no mask as if it clipped
            // everything away. The game never does it, and swallowing the
            // subtree silently would look like a missing scene, so draw it.
            draw(contents, projection: projection, time: time)
            return
        }
        if cropCompositeProgram != 0, CropCompositing.composites(mask),
           drawCompositedCrop(mask: mask, contents: contents, projection: projection, time: time) {
            return
        }

        if cropDepth == 0 { glEnable(GLenum(GL_STENCIL_TEST)) }
        cropDepth += 1
        let level = cropDepth

        // Write: only where the enclosing mask (or the whole target, at the
        // top level) already passes.
        glColorMask(GLboolean(GL_FALSE), GLboolean(GL_FALSE), GLboolean(GL_FALSE), GLboolean(GL_FALSE))
        glStencilMask(0xFF)
        glStencilFunc(GLenum(GL_EQUAL), level - 1, 0xFF)
        glStencilOp(GLenum(GL_KEEP), GLenum(GL_KEEP), GLenum(GL_INCR))
        drawMask(mask, projection: projection, time: time)

        // Draw inside it.
        glColorMask(GLboolean(GL_TRUE), GLboolean(GL_TRUE), GLboolean(GL_TRUE), GLboolean(GL_TRUE))
        glStencilMask(0)
        glStencilFunc(GLenum(GL_EQUAL), level, 0xFF)
        draw(contents, projection: projection, time: time)

        // Put the buffer back.
        glColorMask(GLboolean(GL_FALSE), GLboolean(GL_FALSE), GLboolean(GL_FALSE), GLboolean(GL_FALSE))
        glStencilMask(0xFF)
        glStencilFunc(GLenum(GL_EQUAL), level, 0xFF)
        glStencilOp(GLenum(GL_KEEP), GLenum(GL_KEEP), GLenum(GL_DECR))
        drawMask(mask, projection: projection, time: time)
        glColorMask(GLboolean(GL_TRUE), GLboolean(GL_TRUE), GLboolean(GL_TRUE), GLboolean(GL_TRUE))

        cropDepth -= 1
        if cropDepth == 0 {
            glDisable(GLenum(GL_STENCIL_TEST))
        } else {
            glStencilMask(0)
            glStencilFunc(GLenum(GL_EQUAL), cropDepth, 0xFF)
        }
    }

    /// A crop whose mask holds a shape, as SpriteKit draws one: its contents
    /// and its mask's coverage each into a target the size of the mask's
    /// reach on the target drawn into, then the contents times the mask
    /// (`cropCompositeFragmentShader`). False when it can't be, and the
    /// stencil takes it.
    private func drawCompositedCrop(
        mask: [SpriteBatcher.Pass],
        contents: [SpriteBatcher.Pass],
        projection: [Float],
        time: Float
    ) -> Bool {
        guard let reach = CropCompositing.bounds(of: mask) else { return false }
        // Only what the target shows: a list's crop runs far off it.
        let shown = target.visible
        let left = max(reach.minX, shown.minX), right = min(reach.maxX, shown.maxX)
        let bottom = max(reach.minY, shown.minY), top = min(reach.maxY, shown.maxY)
        guard right > left, top > bottom else { return true }          // nothing on it
        let plan = EffectTexture(
            bounds: CGRect(x: left, y: bottom, width: right - left, height: top - bottom),
            density: target.density, maximumSide: device.maximumTextureSide
        )
        guard let drawn = targets.transient(width: plan.widthInPixels, height: plan.heightInPixels, stencil: true),
              let coverage = targets.transient(width: plan.widthInPixels, height: plan.heightInPixels, stencil: false)
        else { return false }

        cropsComposited += 1
        let outer = target
        let outerDepth = cropDepth
        // As an effect node's: the stencil is the outer target's, and the
        // crops inside count from none in a target of their own.
        if outerDepth > 0 { glDisable(GLenum(GL_STENCIL_TEST)) }
        cropDepth = 0

        target = Target(
            framebuffer: drawn.framebuffer, widthInPixels: drawn.width, heightInPixels: drawn.height,
            visible: plan.bounds, fragSpace: plan.contentsSpace, density: plan.density
        )
        bindTarget()
        RenderPoison.fillTarget()
        glClearColor(0, 0, 0, 0)
        glClearStencil(0)
        glStencilMask(0xFF)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT) | GLbitfield(GL_STENCIL_BUFFER_BIT))
        draw(contents, projection: plan.projection, time: time)

        target = Target(
            framebuffer: coverage.framebuffer, widthInPixels: coverage.width, heightInPixels: coverage.height,
            visible: plan.bounds, fragSpace: plan.contentsSpace, density: plan.density
        )
        bindTarget()
        // Clear again, not as the contents left it: a crop or effect drawn
        // in them puts the clear colour back to opaque, which would leave
        // the mask covering its whole target.
        glClearColor(0, 0, 0, 0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        drawMaskCoverage(mask, projection: plan.projection, time: time)

        target = outer
        cropDepth = outerDepth
        bindTarget()
        glClearColor(0, 0, 0, 1)
        resumeCrops()

        // The contents times the mask, onto the target, inside any crops
        // around it.
        useProgram(cropCompositeProgram)
        bindSampler(coverage.texture, unit: 1)
        let sampler = uniformLocation(cropCompositeProgram, "u_mask")
        if sampler >= 0 { glUniform1i(sampler, 1) }
        let texel = uniformLocation(cropCompositeProgram, "u_mask_texel")
        if texel >= 0 { glUniform2f(texel, 1 / Float(coverage.width), 1 / Float(coverage.height)) }
        let quad = compositeQuad(bounds: plan.bounds, transform: .identity, alpha: 1, shader: nil, blendMode: .alpha)
        draw(quad, projection: projection, time: time, overrideProgram: cropCompositeProgram,
             fragSpace: outer.fragSpace, texture: drawn.texture)
        return true
    }

    /// A composited crop's mask as coverage: its shapes, labels and sprites
    /// as they draw, their alpha included, as SpriteKit multiplies by a
    /// mask that holds a shape (`CropCompositing`).
    private func drawMaskCoverage(_ passes: [SpriteBatcher.Pass], projection: [Float], time: Float) {
        for pass in passes {
            switch pass {
            case let .batches(batches):
                for batch in batches { draw(batch, projection: projection, time: time) }
            case let .coverage(staged):
                draw(staged, projection: projection, asCoverage: true)
            case let .shape(shape):
                draw(shape, projection: projection, asCoverage: true)
            case let .label(label):
                draw(label, projection: projection)
            case .effect, .crop:
                continue                // never composited (`CropCompositing`)
            }
        }
    }

    /// Back in the crops `cropDepth` deep after drawing into a target of
    /// its own, where a crop leaves the stencil's mask writing and its
    /// function matching its own level.
    private func resumeCrops() {
        guard cropDepth > 0 else { return }
        glEnable(GLenum(GL_STENCIL_TEST))
        glStencilMask(0)
        glStencilFunc(GLenum(GL_EQUAL), cropDepth, 0xFF)
        glStencilOp(GLenum(GL_KEEP), GLenum(GL_KEEP), GLenum(GL_KEEP))
    }

    /// The mask's sprites, through the alpha-testing program rather than
    /// their own.
    private func drawMask(_ passes: [SpriteBatcher.Pass], projection: [Float], time: Float) {
        for pass in passes {
            switch pass {
            case let .batches(batches):
                for batch in batches {
                    if batch.shader != nil, !warnedShadedMask {
                        warnedShadedMask = true
                        Log.error("a crop node's mask carries a shader; it is clipped by its texture's alpha instead")
                    }
                    draw(batch, projection: projection, time: time, overrideProgram: maskProgram)
                }
            case let .effect(_, _, _, _, _, _, _, _, _, contents):
                drawMask(contents, projection: projection, time: time)
            case let .crop(_, _, contents):
                drawMask(contents, projection: projection, time: time)
            case let .shape(shape):
                // A shape mask (the scroll areas' rounded clips) cuts by
                // where its fill and stroke reach.
                draw(shape, projection: projection, program: shapeMaskProgram)
            case let .coverage(staged):
                draw(staged, projection: projection, mask: true)
            case let .label(label):
                // A label mask (a gradient cut to a word, say) cuts by its glyphs'
                // coverage, at half as a shape's does.
                draw(label, projection: projection, program: shapeMaskProgram)
            }
        }
    }

    // MARK: SKRenderer

    public func enqueue(_ commandBuffer: MTLCommandBuffer) {
        films.push(commandBuffer)
    }

    /// Draws what an `SKRenderer` has committed since the last frame, each
    /// pass into a target of its texture's size, and reads it back into the
    /// film's pixel buffer.
    private func drawFilmPasses() {
        collectFilmReadbacks()
        for buffer in films.take(waitingUpTo: Self.filmTurnWait) {
            var failure: Error?
            var drawn: [FilmReadback.Pass] = []
            for pass in buffer.passes {
                switch drawFilm(pass) {
                case let .success(frame): drawn.append(frame)
                case let .failure(error): failure = error
                }
            }
            // Read back as the next frame starts; until then the film waits
            // for it, as it would for the GPU on Apple.
            guard failure == nil, !drawn.isEmpty else {
                freeFilmTargets += drawn.map(\.target)
                buffer.complete(error: failure)
                continue
            }
            filmReadbacks.append(FilmReadback(commands: buffer, passes: drawn))
        }
    }

    /// One command buffer's film frames, drawn into targets of their own and
    /// waiting to be read back into its pixel buffers.
    private struct FilmReadback {
        struct Pass {
            let target: RenderTargetHandle
            let pixels: CVPixelBuffer
        }

        let commands: MTLCommandBuffer
        let passes: [Pass]
    }

    /// Reads the frames drawn last time into their pixel buffers and
    /// completes their command buffers. A frame later the GPU has drawn
    /// them, so the read is only the copy. Each is read as GL has it, rows
    /// bottom first and RGBA, straight into its buffer, which says so
    /// (`CVPixelBuffer.isHeldAsRendered`): the video writer reads that
    /// order as it converts, and a buffer's lock puts it right for anything
    /// else, so nothing turns it round on this thread.
    private func collectFilmReadbacks() {
        guard !filmReadbacks.isEmpty else { return }
        let waiting = filmReadbacks
        filmReadbacks.removeAll(keepingCapacity: true)
        glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 4)
        for readback in waiting {
            for pass in readback.passes {
                let pixels = pass.pixels
                let width = min(pass.target.width, pixels.width), height = min(pass.target.height, pixels.height)
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), pass.target.framebuffer)
                glPixelStorei(GLenum(GL_PACK_ROW_LENGTH), GLint(pixels.bytesPerRow / 4))
                // Bottom first: GL's first row goes in the buffer's last.
                let into = pixels.baseAddress + (pixels.height - height) * pixels.bytesPerRow
                glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), into)
                pixels.isHeldAsRendered = true
                freeFilmTargets.append(pass.target)
            }
            let error = glGetError()
            readback.commands.complete(error: error == GLenum(GL_NO_ERROR) ? nil : MTLCommandBufferError("GL error \(error) reading a film's frame back"))
        }
        glPixelStorei(GLenum(GL_PACK_ROW_LENGTH), 0)
    }

    /// A target of the film's size, reused where one is free.
    private func filmTarget(width: Int, height: Int) -> RenderTargetHandle? {
        if let index = freeFilmTargets.firstIndex(where: { $0.width == width && $0.height == height }) {
            return freeFilmTargets.remove(at: index)
        }
        // Another size: the film's changed, so those left over go.
        for kept in freeFilmTargets { device.deleteRenderTarget(kept) }
        freeFilmTargets.removeAll()
        return device.createRenderTarget(width: width, height: height, stencil: true)
    }

    private func drawFilm(_ pass: RecordedRenderPass) -> Result<FilmReadback.Pass, Error> {
        guard let color = pass.color, let pixels = color.pixelBuffer else {
            return .failure(MTLCommandBufferError("a film's pass has nothing to draw into"))
        }
        let width = color.width, height = color.height
        guard let handle = filmTarget(width: width, height: height) else {
            return .failure(MTLCommandBufferError("no \(width) × \(height) target"))
        }

        let frame = Viewport(
            drawableSize: pass.viewport.size,
            sceneSize: pass.sceneSize,
            scaleMode: pass.scaleMode,
            anchorPoint: pass.anchorPoint
        )
        deviceScale = max(frame.scale.x, frame.scale.y)
        glyphSource.deviceScale = deviceScale
        shapeMeshes.pixelsPerPoint = deviceScale
        shapeMeshes.screenPixelsPerPoint = deviceScale
        target = Target(
            framebuffer: handle.framebuffer,
            widthInPixels: width,
            heightInPixels: height,
            visible: frame.visibleSceneRect,
            fragSpace: .target(heightInPixels: height)
        )
        bindTarget()
        glViewport(GLint(pass.viewport.minX), GLint(pass.viewport.minY), GLsizei(pass.viewport.width), GLsizei(pass.viewport.height))
        RenderPoison.fillTarget()
        let clear = pass.loadAction == .clear ? pass.clearColor : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        glClearColor(GLfloat(clear.red), GLfloat(clear.green), GLfloat(clear.blue), GLfloat(clear.alpha))
        glClearStencil(0)
        // A clear writes only the stencil bits the mask lets through.
        glStencilMask(0xFF)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT) | GLbitfield(GL_STENCIL_BUFFER_BIT))
        glClearColor(0, 0, 0, 1)
        cropDepth = 0

        state.forgetTextures()
        // A film's frames are kept: every page they show is waited for.
        let defers = cache.defersPages
        cache.defersPages = false
        defer { cache.defersPages = defers }
        draw(stage(batcher.passes(for: pass.list)), projection: frame.projection, time: Float(pass.time))
        stagedComposites.removeAll(keepingCapacity: true)
        bindVertexArray(0)

        let error = glGetError()
        guard error == GLenum(GL_NO_ERROR) else {
            freeFilmTargets.append(handle)
            return .failure(MTLCommandBufferError("GL error \(error) drawing a film's frame"))
        }
        return .success(FilmReadback.Pass(target: handle, pixels: pixels))
    }

    // MARK: Baking

    /// `SKView.texture(from:)`: a subtree rendered to a texture the game then
    /// samples, as a game may bake a static layer once per layout.
    /// Whether the caller is on the frame thread, whose GL context the
    /// renderer draws with; says so once for each `what` that isn't.
    nonisolated private static func onGLThread(_ what: String) -> Bool {
        guard !Thread.isMainThread else { return true }
        offThreadLock.lock()
        let first = offThreadCalls.insert(what).inserted
        offThreadLock.unlock()
        if first { Log.error("\(what) called off the frame thread (\(Thread.current.name ?? "unnamed")): refused, as GL is current only there") }
        return false
    }

    nonisolated private static let offThreadLock = NSLock()
    nonisolated(unsafe) private static var offThreadCalls: Set<String> = []

    private func bake(_ node: SKNode, crop: CGRect?) -> SKTexture? {
        FrameCosts.time(.bakes) { bakeNow(node, crop: crop) }
    }

    private func bakeNow(_ node: SKNode, crop: CGRect?) -> SKTexture? {
        // A snapshot is kept as drawn: every page it shows is waited for.
        let defers = cache.defersPages
        cache.defersPages = false
        defer { cache.defersPages = defers }
        // The subtree draws with the node's own transform (a crop is given
        // in that space too: a root scaled by some factor, cropped to the
        // scaled rect), so its frame is measured there, as SpriteKit's is: a
        // canvas scaled down
        // by `edgeShadeMapScale`, which a frame in the node's own space
        // would leave as a small patch in a texture too big for it.
        let bounds = crop ?? node.calculateAccumulatedFrame()
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let density = target.visible.height > 0
            ? CGFloat(target.heightInPixels) / target.visible.height
            : view.contentScaleFactor
        let plan = EffectTexture(bounds: bounds, density: density, maximumSide: device.maximumTextureSide)

        guard let handle = device.createRenderTarget(
            width: plan.widthInPixels, height: plan.heightInPixels, stencil: false
        ) else { return nil }

        var list = DrawList()
        // SpriteKit draws a snapshot in tree order, whatever the view's
        // `ignoresSiblingOrder` (measured by readback on a Mac).
        list.commands = DrawList(scene: node).commands
        // Its shapes for the snapshot's density, the frame's put back after.
        let framePixelsPerPoint = shapeMeshes.pixelsPerPoint
        shapeMeshes.pixelsPerPoint = density
        let passes = batcher.passes(for: list)
        shapeMeshes.pixelsPerPoint = framePixelsPerPoint

        let outer = target
        let outerDepth = cropDepth
        if outerDepth > 0 { glDisable(GLenum(GL_STENCIL_TEST)) }
        cropDepth = 0
        target = Target(
            framebuffer: handle.framebuffer,
            widthInPixels: handle.width, heightInPixels: handle.height,
            visible: plan.bounds, fragSpace: plan.contentsSpace
        )
        bindTarget()
        RenderPoison.fillTarget()
        glClearColor(0, 0, 0, 0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        // Drawn as it comes: the frame's staged stream may still be read by
        // draws to come.
        draw(passes, projection: plan.projection, time: 0)
        bindVertexArray(0)

        target = outer
        cropDepth = outerDepth
        bindTarget()
        glClearColor(0, 0, 0, 1)
        resumeCrops()

        // The framebuffer has done its job; the texture it wrote into is
        // what the game keeps. Deleting the handle with its texture zeroed
        // frees the one and leaves the other.
        device.deleteRenderTarget(RenderTargetHandle(
            framebuffer: handle.framebuffer, texture: 0, stencil: handle.stencil,
            width: handle.width, height: handle.height
        ))

        // The texture owns the GL name from here: `glName` is the cache slot,
        // and a texture that already has one is never uploaded again. Its
        // points size is the baked rect, so a sprite made from it measures as
        // the game expects.
        let baked = SKTexture(color: .clear, size: bounds.size)
        baked.glName = handle.texture

        // A game may bake again whenever it lays out, and let go of the
        // texture it had: those the game has dropped are deleted now.
        for name in bakedTextures.sweep() { device.deleteTexture(name) }
        state.forgetTextures()
        bakedTextures.add(baked, name: handle.texture, width: handle.width, height: handle.height)
        return baked
    }

    /// Hands `done` the next frame drawn, read back before it's swapped:
    /// `drawHierarchy`'s part, for a game's debug captures of its screen.
    public func captureNextFrame(_ done: @escaping (RasterImage?) -> Void) {
        pendingCaptures.append(done)
    }

    private var pendingCaptures: [(RasterImage?) -> Void] = []

    /// The default framebuffer as drawn, row 0 the top, stretched to the
    /// screen's size as the display shows it when the buffer is smaller.
    private func readScreen(width: Int, height: Int, stretchedTo screen: (width: Int, height: Int)) -> RasterImage? {
        guard let image = readScreen(width: width, height: height) else { return nil }
        guard width != screen.width || height != screen.height else { return image }
        return Self.stretched(image, toWidth: screen.width, height: screen.height)
    }

    /// `image` resized with bilinear filtering, as `GL_LINEAR` samples it:
    /// a debug capture of a frame the display stretched.
    private static func stretched(_ image: RasterImage, toWidth width: Int, height: Int) -> RasterImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let sx = Double(image.width) / Double(width)
        let sy = Double(image.height) / Double(height)
        for y in 0 ..< height {
            let fy = max(0, (Double(y) + 0.5) * sy - 0.5)
            let y0 = min(Int(fy), image.height - 1), y1 = min(y0 + 1, image.height - 1)
            let wy = fy - Double(y0)
            for x in 0 ..< width {
                let fx = max(0, (Double(x) + 0.5) * sx - 0.5)
                let x0 = min(Int(fx), image.width - 1), x1 = min(x0 + 1, image.width - 1)
                let wx = fx - Double(x0)
                for c in 0 ..< 4 {
                    func at(_ px: Int, _ py: Int) -> Double { Double(image.pixels[(py * image.width + px) * 4 + c]) }
                    let top = at(x0, y0) * (1 - wx) + at(x1, y0) * wx
                    let bottom = at(x0, y1) * (1 - wx) + at(x1, y1) * wx
                    pixels[(y * width + x) * 4 + c] = UInt8(clamping: Int((top * (1 - wy) + bottom * wy).rounded()))
                }
            }
        }
        return RasterImage(width: width, height: height, pixels: pixels)
    }

    /// The default framebuffer as drawn, row 0 the top.
    private func readScreen(width: Int, height: Int) -> RasterImage? {
        guard width > 0, height > 0 else { return nil }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        var rows = [UInt8](repeating: 0, count: width * height * 4)
        glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &rows)
        let rowBytes = width * 4
        var flipped = [UInt8](repeating: 0, count: rows.count)
        for row in 0 ..< height {
            flipped.replaceSubrange(row * rowBytes ..< (row + 1) * rowBytes, with: rows[(height - 1 - row) * rowBytes ..< (height - row) * rowBytes])
        }
        // The screen is opaque, whatever alpha the last blend left.
        for at in stride(from: 3, to: flipped.count, by: 4) { flipped[at] = 255 }
        return RasterImage(width: width, height: height, pixels: flipped)
    }

    /// A baked texture's pixels, premultiplied, row 0 the top: what the
    /// game's `cgImage()` asks of a snapshot (to fit a node by what it
    /// draws, say).
    private func readBack(_ texture: SKTexture) -> RasterImage? {
        guard let size = bakedTextures.size(of: texture.glName), size.width > 0, size.height > 0 else { return nil }
        var framebuffer: GLuint = 0
        var previous: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &previous)
        glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture.glName, 0)
        var rows = [UInt8](repeating: 0, count: size.width * size.height * 4)
        glReadPixels(0, 0, GLsizei(size.width), GLsizei(size.height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &rows)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(previous))
        glDeleteFramebuffers(1, &framebuffer)
        // GL's rows run up from the bottom; a bitmap's down from the top.
        let stride = size.width * 4
        var flipped = [UInt8](repeating: 0, count: rows.count)
        for row in 0 ..< size.height {
            flipped.replaceSubrange(row * stride ..< (row + 1) * stride, with: rows[(size.height - 1 - row) * stride ..< (size.height - row) * stride])
        }
        return RasterImage(width: size.width, height: size.height, pixels: flipped)
    }

    public var surfaceScale: CGFloat { renderScale }
    public var preferredFrameRate: Int { view.preferredFramesPerSecond }

    /// How much of the screen's resolution the scene is drawn at, as
    /// `sceneDrawTarget` will choose: the display's stretch of a smaller
    /// buffer, else `renderScale` below 1, else all of it.
    private func drawnFraction(of frame: Frame) -> CGFloat {
        let screen = frame.size, surface = frame.surfaceSize
        guard screen.width > 0, screen.height > 0 else { return 1 }
        if surface.width < screen.width || surface.height < screen.height {
            return max(surface.width / screen.width, surface.height / screen.height)
        }
        return min(max(renderScale, 0.25), 1)
    }

    /// Where the frame draws: `.none` for the window's buffer, else a target
    /// `renderScale` of the screen's size (made again when that changes),
    /// stretched onto the buffer as the frame ends. Only while the buffer is
    /// still the screen's size: once the display stretches it, the frame
    /// draws straight into it, whatever size it is.
    private func sceneDrawTarget(screenWidth: Int, screenHeight: Int, surfaceScaled: Bool) -> RenderTargetHandle {
        let scale = min(max(renderScale, 0.25), 1)
        guard scale < 1, !surfaceScaled else {
            if sceneTarget.isValid {
                device.deleteRenderTarget(sceneTarget)
                sceneTarget = .none
                Log.info(surfaceScaled ? "render scale \(scale): the scene drawn on the window's buffer, stretched by the display" : "render scale 1: the scene drawn on the screen")
            }
            return .none
        }
        let pixels = SurfaceGeometry.pixels(of: CGSize(width: screenWidth, height: screenHeight), scale: scale)
        let width = Int(pixels.width)
        let height = Int(pixels.height)
        if sceneTarget.isValid, sceneTarget.width == width, sceneTarget.height == height { return sceneTarget }
        if sceneTarget.isValid { device.deleteRenderTarget(sceneTarget) }
        sceneTarget = device.createRenderTarget(width: width, height: height, stencil: true) ?? .none
        if sceneTarget.isValid { Log.info("render scale \(scale): the scene drawn at \(width)x\(height), stretched to \(screenWidth)x\(screenHeight)") }
        return sceneTarget
    }

    /// Stretches the frame drawn at `renderScale` onto the screen.
    private func present(_ scene: RenderTargetHandle, screenWidth: Int, screenHeight: Int) {
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), scene.framebuffer)
        var stencil = GLenum(GL_STENCIL_ATTACHMENT)
        glInvalidateFramebuffer(GLenum(GL_READ_FRAMEBUFFER), 1, &stencil)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 0)
        // Every pixel is written: the last frame's needn't be read back in.
        var attachments = [GLenum(GL_COLOR), GLenum(GL_STENCIL)]
        glInvalidateFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 2, &attachments)
        glBlitFramebuffer(
            0, 0, GLint(scene.width), GLint(scene.height),
            0, 0, GLint(screenWidth), GLint(screenHeight),
            GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR)
        )
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        targetBinds += 1
    }

    private func bindTarget() {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), target.framebuffer)
        targetBinds += 1
        applyViewport()
        applyScissor()
    }

    private func applyViewport() {
        if let rect = target.viewport {
            glViewport(GLint(rect.x0), GLint(rect.y0), GLsizei(rect.width), GLsizei(rect.height))
        } else {
            glViewport(0, 0, GLsizei(target.widthInPixels), GLsizei(target.heightInPixels))
        }
    }

    /// GL's scissor as the bound target asks.
    private func applyScissor() {
        guard appliedScissor != target.scissor else { return }
        if let rect = target.scissor {
            if appliedScissor == nil { glEnable(GLenum(GL_SCISSOR_TEST)) }
            glScissor(GLint(rect.x0), GLint(rect.y0), GLsizei(rect.width), GLsizei(rect.height))
        } else {
            glDisable(GLenum(GL_SCISSOR_TEST))
        }
        appliedScissor = target.scissor
    }

    /// A band blur (an effect node blurring bands of the screen) drawn
    /// without a texture of the whole effect node (`BandBlurPlan`): each band's strip into a small
    /// texture of its own first, then the contents straight into the target
    /// outside the bands, then each strip onto its band through the blur.
    /// The contents report the `gl_FragCoord` they would have in the
    /// effect's texture, so lit shaders inside see what they always did.
    ///
    /// Returns false, having drawn nothing that shows, where it can't draw
    /// the same picture: an effect node that fades, blends otherwise, is
    /// scaled, turned or cropped, holds crops or shaded effect nodes of its
    /// own, or whose bands cover most of the target (a blur over the whole screen).
    private func drawBandBlur(
        bounds: CGRect,
        transform: CGAffineTransform,
        shader: SKShader,
        alpha: CGFloat,
        blendMode: SKBlendMode,
        contents: [SpriteBatcher.Pass],
        projection: [Float],
        time: Float
    ) -> Bool {
        guard alpha >= 0.999, blendMode == .alpha, cropDepth == 0, target.scissor == nil,
              transform.a == 1, transform.d == 1, transform.b == 0, transform.c == 0,
              bounds.width > 0, bounds.height > 0,
              target.visible.width > 0, target.visible.height > 0,
              let uniforms = BandBlurPlan.Uniforms(shader),
              Self.drawsAnywhere(contents)
        else { return false }
        let dx = Double(target.widthInPixels) / Double(target.visible.width)
        let dy = Double(target.heightInPixels) / Double(target.visible.height)
        guard abs(dx - dy) <= 0.01 * dy else { return false }
        let texture = EffectTexture(bounds: bounds, density: target.density, maximumSide: device.maximumTextureSide)
        guard !texture.isClamped else { return false }
        let offset = CGPoint(x: transform.tx, y: transform.ty)
        guard let plan = BandBlurPlan(
            uniforms: uniforms,
            width: target.widthInPixels, height: target.heightInPixels,
            visible: target.visible, fragSpace: target.fragSpace,
            bounds: bounds, offset: offset
        ) else { return false }

        /// Where a pixel's corner of the target the effect lands in lies in
        /// the effect's coordinates (that target's, not the strips').
        let shown = target.visible
        func local(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(
                x: shown.minX + CGFloat(Double(x) / dx) - offset.x,
                y: shown.minY + CGFloat(Double(y) / dy) - offset.y
            )
        }
        func contentsSpace(at origin: CGPoint) -> FragCoordSpace {
            BandBlurPlan.contentsSpace(
                origin: origin, dx: dx, dy: dy, bounds: bounds,
                textureWidth: texture.widthInPixels, textureHeight: texture.heightInPixels
            )
        }

        // The strips first, all in one texture drawn in one pass (each its
        // own viewport), so the target is left once, before it draws any of
        // the contents: side by side when they're tall (landscape), stacked
        // when they're wide.
        let wide = plan.strips.allSatisfy { $0.strip.width >= $0.strip.height }
        var places: [(x: Int, y: Int)] = []
        var atlasWidth = 0, atlasHeight = 0
        for strip in plan.strips {
            if wide {
                places.append((0, atlasHeight))
                atlasWidth = max(atlasWidth, strip.strip.width)
                atlasHeight += strip.strip.height
            } else {
                places.append((atlasWidth, 0))
                atlasWidth += strip.strip.width
                atlasHeight = max(atlasHeight, strip.strip.height)
            }
        }
        var strips: [(rect: CGRect, textureRect: CGRect, span: SIMD2<Float>, band: BandBlurPlan.PixelRect)] = []
        var atlas: GLuint = 0
        if !plan.strips.isEmpty {
            guard atlasWidth <= device.maximumTextureSide, atlasHeight <= device.maximumTextureSide,
                  let handle = targets.transient(width: atlasWidth, height: atlasHeight, stencil: false)
            else { return false }
            atlas = handle.texture
            effectsDrawn += 1
            let outer = target
            target = Target(
                framebuffer: handle.framebuffer,
                widthInPixels: handle.width,
                heightInPixels: handle.height,
                visible: .zero,
                fragSpace: outer.fragSpace,
                density: outer.density
            )
            bindTarget()
            RenderPoison.fillTarget()
            glClearColor(0, 0, 0, 0)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            for (strip, place) in zip(plan.strips, places) {
                let pixels = strip.strip
                let origin = local(pixels.x0, pixels.y0)
                let rect = CGRect(origin: origin, size: CGSize(width: Double(pixels.width) / dx, height: Double(pixels.height) / dy))
                let area = BandBlurPlan.PixelRect(
                    x0: place.x, y0: place.y, x1: place.x + pixels.width, y1: place.y + pixels.height
                )
                target.visible = rect
                // The atlas's pixel (0, 0), where this strip's contents would put it.
                target.fragSpace = contentsSpace(at: local(pixels.x0 - place.x, pixels.y0 - place.y))
                target.viewport = area
                target.scissor = area
                applyViewport()
                applyScissor()
                draw(contents, projection: BandBlurPlan.projection(showing: rect), time: time)
                strips.append((
                    rect: rect,
                    textureRect: CGRect(
                        x: CGFloat(place.x) / CGFloat(atlasWidth), y: CGFloat(place.y) / CGFloat(atlasHeight),
                        width: CGFloat(pixels.width) / CGFloat(atlasWidth), height: CGFloat(pixels.height) / CGFloat(atlasHeight)
                    ),
                    span: SIMD2(
                        strip.span.x * Float(pixels.width) / Float(atlasWidth),
                        strip.span.y * Float(pixels.height) / Float(atlasHeight)
                    ),
                    band: strip.band
                ))
            }
            target = outer
            bindTarget()
            glClearColor(0, 0, 0, 1)
        }

        let outer = target
        if !plan.direct.isEmpty {
            target.fragSpace = contentsSpace(at: local(0, 0))
            target.scissor = plan.direct
            applyScissor()
            draw(contents, projection: Self.concatenate(projection, transform), time: time)
            target = outer
        }
        for strip in strips {
            target.scissor = strip.band
            applyScissor()
            let quad = compositeQuad(
                bounds: strip.rect, transform: transform, alpha: alpha, shader: shader, blendMode: blendMode,
                textureRect: strip.textureRect
            )
            draw(quad, projection: projection, time: time, fragSpace: outer.fragSpace,
                 texture: atlas, span: strip.span)
        }
        target = outer
        applyScissor()
        return true
    }

    /// Whether `passes` draw the same wherever their target's pixels lie,
    /// and cheaply enough to draw more than once: no crops (whose stencil an
    /// offscreen target lacks) and no effect node that redraws every frame.
    private static func drawsAnywhere(_ passes: [SpriteBatcher.Pass]) -> Bool {
        for pass in passes {
            switch pass {
            case .crop:
                return false
            case let .effect(_, _, shader, alpha, _, rasterize, _, _, _, contents):
                if !rasterize, shader != nil || alpha < 0.999 { return false }
                if !rasterize, !drawsAnywhere(contents) { return false }
            case .batches, .label, .shape, .coverage:
                continue
            }
        }
        return true
    }

    /// A quad covering `bounds` under `transform`, carrying the effect's
    /// texture whole. Built through the batcher so the vertex layout and the
    /// `v_color_mix` contract stay in one place.
    ///
    /// It carries no texture: the effect's target is bound by name as it
    /// draws (`draw(_:…texture:)`), so it can be staged with the frame.
    private func compositeQuad(
        bounds: CGRect,
        transform: CGAffineTransform,
        alpha: CGFloat,
        shader: SKShader?,
        blendMode: SKBlendMode,
        textureRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> SpriteBatcher.Batch {
        let sprite = DrawList.Sprite(
            transform: CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
                .concatenating(transform),
            size: bounds.size,
            anchorPoint: CGPoint(x: 0.5, y: 0.5),
            texture: nil,
            textureRect: textureRect,
            color: .white,
            colorBlendFactor: 0,
            alpha: alpha,
            blendMode: blendMode,
            shader: shader,
            attributeValues: [:]
        )
        var list = DrawList()
        list.commands = [.sprite(sprite)]
        guard case let .batches(batches)? = batcher.passes(for: list).first, let batch = batches.first else {
            return SpriteBatcher.Batch(blendMode: blendMode, attributeValues: [:])
        }
        return batch
    }

    /// Every action and transition runs this many times slower
    /// (`debug.<app>.slowdown`, as a game's own slowdown might), so
    /// a 0.1-second fade can be filmed on an emulator.
    public var slowdown: Double = 1

    /// The scene on screen and whether a transition is playing, as last
    /// logged.
    private var loggedScene: ObjectIdentifier?
    private var loggedTransition = false

    /// Says in logcat when the view's scene changes and when its transition
    /// lands, with the shell's clock, so a scene change can be timed.
    private static func glString(_ name: GLenum) -> String {
        guard let bytes = glGetString(name) else { return "" }
        return String(cString: UnsafeRawPointer(bytes).assumingMemoryBound(to: CChar.self))
    }

    private func noteSceneChange(at time: TimeInterval) {
        let scene = view.scene.map(ObjectIdentifier.init)
        let transitioning = view.isTransitioning
        guard scene != loggedScene || transitioning != loggedTransition else { return }
        let name = view.scene.map { String(describing: type(of: $0)) } ?? "nothing"
        let stamp = String(format: "%.3f", time)
        if scene != loggedScene {
            Log.info("scene \(name) at \(stamp)\(transitioning ? ", transition playing" : "")")
        } else if !transitioning {
            Log.info("transition into \(name) landed at \(stamp)")
        }
        loggedScene = scene
        loggedTransition = transitioning
    }

    // MARK: Text

    /// Draws a label from the layout the node already made.
    ///
    /// Nothing is measured here: `label.layout` holds the lines as the node
    /// broke and placed them, with both alignment modes already applied to
    /// each line's pen origin, and that is also what it reported as its
    /// `contentFrame`. Re-measuring would be a second opinion, and the two
    /// would drift.
    private func draw(_ label: DrawList.Label, projection: [Float], program: GLuint? = nil) {
        let program = program ?? coverageProgram
        guard program != 0 else { return }

        // Shaping and rasterising happen inside this, so the atlas is only
        // brought up to date afterwards — a glyph seen for the first time
        // this frame is on the GPU before its quad is drawn.
        let runs = CoverageGeometry.runs(for: label, source: glyphSource)
        guard !runs.isEmpty else { return }
        glyphPages.sync()
        colourPages.sync()

        for run in runs {
            guard let (name, runProgram) = textureAndProgram(of: run, coverage: program) else { continue }
            drawCoverage(run, texture: name, projection: projection, program: runProgram)
        }
    }

    /// A glyph run's page texture and program: a colour run's off its RGBA
    /// page with the colour glyph program, which a crop's mask doesn't
    /// draw (it stencils by coverage).
    private func textureAndProgram(of run: CoverageGeometry.Run, coverage program: GLuint) -> (GLuint, GLuint)? {
        guard run.isColour else {
            let name = glyphPages.name(of: run.page)
            return name == 0 ? nil : (name, program)
        }
        let name = colourPages.name(of: run.page)
        guard name != 0, colourGlyphProgram != 0, program != shapeMaskProgram else { return nil }
        return (name, colourGlyphProgram)
    }

    // MARK: Shapes

    /// Fills and strokes a shape through the path rasteriser.
    ///
    /// The mask is rasterised axis-aligned in the node's own space at the
    /// density it will be drawn at, then drawn as one quad through the
    /// node's transform — so a rotated or animated shape costs one mask, not
    /// one per angle.
    /// `asCoverage`: drawn into a composited crop's mask, where only its
    /// coverage counts and it blends as alpha whatever its node's mode.
    private func draw(_ shape: DrawList.Shape, projection: [Float], program: GLuint? = nil, asCoverage: Bool = false) {
        let program = program ?? coverageProgram
        guard program != 0, let path = shape.path else { return }

        let scale = maskScale(for: shape, path: path)
        guard scale > 0 else { return }

        // A texture (not as a crop's mask, which cuts by coverage alone) is
        // stretched over the path's bounds, as SpriteKit maps it.
        let textured = { (texture: SKTexture?) -> SKTexture? in
            program == self.coverageProgram && self.texturedCoverageProgram != 0 ? texture : nil
        }

        if shape.fillColor.alpha > 0,
           let mask = shapeMasks.fill(path, rule: .nonZero, scale: scale, owner: shape.owner) {
            drawCoverage(
                CoverageGeometry.run(
                    mask: mask.bounds, transform: shape.transform,
                    colour: shape.fillColor, alpha: shape.alpha
                ),
                texture: mask.name,
                projection: projection,
                program: program,
                fill: textured(shape.fillTexture).map { ($0, CoverageGeometry.fillMap(mask: mask.bounds, path: path.boundingBox)) },
                blendMode: asCoverage ? .alpha : shape.blendMode
            )
        }

        if shape.lineWidth > 0, shape.strokeColor.alpha > 0,
           let mask = shapeMasks.stroke(
               path, width: shape.lineWidth,
               cap: shape.lineCap, join: shape.lineJoin, scale: scale,
               edgePixels: shapeMeshes.screenPixelsPerPoint,
               glow: shape.glowWidth, antialiased: shape.isAntialiased, miterLimit: shape.miterLimit,
               owner: shape.owner
           ) {
            drawCoverage(
                CoverageGeometry.run(
                    mask: mask.bounds, transform: shape.transform,
                    colour: shape.strokeColor, alpha: shape.alpha
                ),
                texture: mask.name,
                projection: projection,
                program: program,
                fill: textured(shape.strokeTexture).map { ($0, CoverageGeometry.fillMap(mask: mask.bounds, path: path.boundingBox)) },
                blendMode: asCoverage ? .alpha : shape.blendMode
            )
        }
    }

    /// The density a shape's mask is rasterised at: the one it's drawn at,
    /// unless that makes the mask longer than a texture, or the rasteriser,
    /// allows (a scrolling strip tall enough to scroll through a long list is
    /// tens of thousands of pixels). Then less, so the mask fits and the
    /// shape still draws, stretched; its edges soften where a texel spans
    /// more than a pixel.
    private func maskScale(for shape: DrawList.Shape, path: CGPath) -> CGFloat {
        let scale = deviceScale * transformScale(shape.transform)
        let box = path.boundingBoxOfPath
        // A stroke's mask reaches half its width past the path either side,
        // and a mitred corner up to the miter limit's half-widths.
        let width = max(shape.lineWidth, 0)
        let reach = max(box.width, box.height) + (shape.lineJoin == .miter ? width * 10 : width)
        return PathRasteriser.scale(scale, fitting: reach, textureSide: device.maximumTextureSide)
    }

    /// How much a transform scales: the square root of the area it
    /// multiplies by, which is the right number for a rotated shape and the
    /// plain scale for an unrotated one.
    private func transformScale(_ transform: CGAffineTransform) -> CGFloat {
        let determinant = abs(transform.a * transform.d - transform.b * transform.c)
        return determinant > 0 ? sqrt(determinant) : 0
    }

    // MARK: Coverage quads

    /// Draws one run of coverage quads: glyphs or a mask, the texture saying
    /// how much of each pixel is covered and the vertices saying in what
    /// colour.
    private func drawCoverage(
        _ run: CoverageGeometry.Run,
        texture: GLuint,
        projection: [Float],
        program: GLuint? = nil,
        streamFirstIndex: Int = -1,
        streamFirstVertex: Int = 0,
        fill: (texture: SKTexture, map: SIMD4<Float>)? = nil,
        blendMode: SKBlendMode = .alpha
    ) {
        guard !run.indices.isEmpty else { return }

        var program = program ?? coverageProgram
        var fillName: GLuint = 0
        if let fill {
            fillName = cache.imageName(for: fill.texture)
            // Its page still decoding: left out of this frame.
            if fillName == 0, cache.defersPages { return }
            if fillName != 0 { program = texturedCoverageProgram }
        }
        useProgram(program)
        let held = state.uniforms(of: program)
        setProjection(projection, program: program, held: held)
        bindSprite(texture, program: program, held: held)
        if let fill, fillName != 0 {
            bindSampler(fillName, unit: 1)
            let sampler = uniformLocation(program, "u_fill")
            if sampler >= 0 { glUniform1i(sampler, 1) }
            let map = uniformLocation(program, "u_fill_map")
            if map >= 0 { glUniform4f(map, fill.map.x, fill.map.y, fill.map.z, fill.map.w) }
        }
        setBlend(blendMode)

        if streamFirstIndex >= 0 {
            bindVertexArray(vao)
            drawElements(count: run.indices.count, first: streamFirstIndex, vertices: streamFirstVertex, run.vertices.count / SpriteBatcher.floatsPerVertex)
        } else {
            let first = uploadDynamic(vertices: run.vertices, indices: run.indices)
            bindVertexArray(dynamicVAO)
            drawElements(count: run.indices.count, first: first)
        }
        quadsDrawn += run.indices.count / 6
    }

    /// A label or shape staged with the frame; `mask` as a crop's mask,
    /// where only shapes draw.
    private func draw(_ staged: CoverageGeometry.Staged, projection: [Float], mask: Bool = false, asCoverage: Bool = false) {
        guard staged.isStaged else {
            switch staged.origin {
            case let .label(label): draw(label, projection: projection, program: mask ? shapeMaskProgram : nil)
            case let .shape(shape): draw(shape, projection: projection, program: mask ? shapeMaskProgram : nil, asCoverage: asCoverage)
            }
            return
        }
        let program = mask ? shapeMaskProgram : coverageProgram
        guard program != 0 else { return }
        for part in staged.parts {
            var name = part.mask
            var partProgram = program
            if name == 0 {
                guard let (page, runProgram) = textureAndProgram(of: part.run, coverage: program) else { continue }
                name = page
                partProgram = runProgram
            }
            guard name != 0 else { continue }
            let fill = mask || texturedCoverageProgram == 0 ? nil : part.texture.map { ($0, part.textureMap) }
            // A shape blends as its node says, as a sprite does.
            var blendMode = SKBlendMode.alpha
            if !mask, !asCoverage, case let .shape(shape) = staged.origin { blendMode = shape.blendMode }
            drawCoverage(
                part.run, texture: name, projection: projection, program: partProgram,
                streamFirstIndex: part.streamFirstIndex, streamFirstVertex: part.streamFirstVertex, fill: fill,
                blendMode: blendMode
            )
        }
    }

    // MARK: The stream

    /// Bytes a vertex takes: the batcher's x y u v r g b a blend.
    static let vertexStride = SpriteBatcher.floatsPerVertex * MemoryLayout<Float>.size

    /// Where a frame's buffers start: enough for a busy frame, so
    /// most never grow.
    private static let streamVertexBytes = 2 << 20
    private static let streamIndexBytes = 1 << 20
    /// Where the buffers for what's drawn as it comes start.
    private static let dynamicVertexBytes = 256 << 10
    private static let dynamicIndexBytes = 64 << 10

    /// Writes every batch in `passes`, and the quad each effect composites
    /// with, into the frame's stream at once, one map of each buffer, and
    /// hands the passes back with each batch's place in it. Their indices
    /// count from the buffer's start (32-bit, as a frame passes 65,536
    /// vertices), so no draw moves the vertex attributes.
    private func stage(_ passes: [SpriteBatcher.Pass]) -> [SpriteBatcher.Pass] {
        stagedComposites.removeAll(keepingCapacity: true)
        // Text and shapes too: written draw by draw into a buffer earlier
        // draws still read, as they were, Adreno drew them from whatever
        // the next writes had left there (a number from another frame, half
        // a label, stripes of the glyph atlas).
        shapeMasks.beginFrame()
        let passes = resolveCoverage(passes)
        // Every glyph the frame shaped is on its page before any is drawn.
        glyphPages.sync()
        colourPages.sync()
        var vertexBytes = 0
        var indexCount = 0
        measure(passes, vertexBytes: &vertexBytes, indexCount: &indexCount)
        guard vertexBytes > 0, indexCount > 0 else { return passes }
        let indexBytes = indexCount * MemoryLayout<UInt32>.size

        // A fresh store each time, so nothing a frame still in flight reads
        // is written over (and the writes need no sync).
        if vertexBytes > stagedVertexCapacity || stagedVertexCapacity == 0 {
            stagedVertexCapacity = max(Self.streamVertexBytes, vertexBytes * 3 / 2)
        }
        if indexBytes > stagedIndexCapacity || stagedIndexCapacity == 0 {
            stagedIndexCapacity = max(Self.streamIndexBytes, indexBytes * 3 / 2)
        }
        let vertexTarget = GLenum(GL_COPY_WRITE_BUFFER)
        let indexTarget = GLenum(GL_COPY_READ_BUFFER)
        // Bound to the copy targets rather than the array and element ones,
        // so no vertex array's bindings change.
        glBindBuffer(vertexTarget, vbo)
        glBindBuffer(indexTarget, ebo)
        let stores = (stagedVertexCapacity, stagedIndexCapacity)
        if !RenderPoison.stream || stagedStores != stores {
            glBufferData(vertexTarget, stagedVertexCapacity, nil, GLenum(GL_STREAM_DRAW))
            glBufferData(indexTarget, stagedIndexCapacity, nil, GLenum(GL_STREAM_DRAW))
            stagedStores = stores
        }

        var writer = StreamWriter(
            vertices: map(vertexTarget, bytes: vertexBytes),
            indices: map(indexTarget, bytes: indexBytes),
            vertexBytes: vertexBytes, indexCount: indexCount
        )
        let staged = write(passes, into: &writer)
        writer.finish(vertexTarget: vertexTarget, indexTarget: indexTarget)
        glBindBuffer(vertexTarget, 0)
        glBindBuffer(indexTarget, 0)
        return staged
    }

    /// The whole range of the store just orphaned. Never unsynchronised:
    /// the orphan is the driver's to honour, and where it doesn't (or
    /// handles an unsynchronised map as Qualcomm's drivers do) a synchronised
    /// map waits rather than writing over a frame still being drawn.
    private func map(_ target: GLenum, bytes: Int) -> UnsafeMutableRawPointer? {
        streamMaps += 1
        let access = GLbitfield(GL_MAP_WRITE_BIT) | GLbitfield(GL_MAP_INVALIDATE_BUFFER_BIT)
        return glMapBufferRange(target, 0, bytes, access)
    }

    /// Labels and shapes made into their coverage runs, ahead of the
    /// frame's one write (`stage`).
    private func resolveCoverage(_ passes: [SpriteBatcher.Pass]) -> [SpriteBatcher.Pass] {
        passes.map { pass in
            switch pass {
            case .batches, .coverage:
                return pass
            case let .effect(bounds, transform, shader, alpha, blendMode, rasterize, owner, generation, digest, contents):
                return .effect(
                    bounds: bounds, transform: transform, shader: shader, alpha: alpha, blendMode: blendMode,
                    rasterize: rasterize, owner: owner, generation: generation, digest: digest,
                    contents: resolveCoverage(contents)
                )
            case let .crop(transform, mask, contents):
                return .crop(transform: transform, mask: resolveCoverage(mask), contents: resolveCoverage(contents))
            case let .label(label):
                guard coverageProgram != 0 else { return pass }
                let parts = CoverageGeometry.runs(for: label, source: glyphSource).map { CoverageGeometry.Staged.Part(run: $0, mask: 0) }
                return .coverage(.init(origin: .label(label), parts: parts))
            case let .shape(shape):
                return .coverage(.init(origin: .shape(shape), parts: shapeParts(shape)))
            }
        }
    }

    /// A shape's fill and stroke as coverage runs over their masks.
    private func shapeParts(_ shape: DrawList.Shape) -> [CoverageGeometry.Staged.Part] {
        guard let path = shape.path else { return [] }
        let scale = maskScale(for: shape, path: path)
        guard scale > 0 else { return [] }
        var parts: [CoverageGeometry.Staged.Part] = []
        if shape.fillColor.alpha > 0,
           let mask = shapeMasks.fill(path, rule: .nonZero, scale: scale, owner: shape.owner) {
            parts.append(.init(
                run: CoverageGeometry.run(mask: mask.bounds, transform: shape.transform, colour: shape.fillColor, alpha: shape.alpha),
                mask: mask.name,
                texture: shape.fillTexture,
                textureMap: CoverageGeometry.fillMap(mask: mask.bounds, path: path.boundingBox)
            ))
        }
        if shape.lineWidth > 0, shape.strokeColor.alpha > 0,
           let mask = shapeMasks.stroke(
               path, width: shape.lineWidth, cap: shape.lineCap, join: shape.lineJoin, scale: scale,
               edgePixels: shapeMeshes.screenPixelsPerPoint,
               glow: shape.glowWidth, antialiased: shape.isAntialiased, miterLimit: shape.miterLimit,
               owner: shape.owner
           ) {
            parts.append(.init(
                run: CoverageGeometry.run(mask: mask.bounds, transform: shape.transform, colour: shape.strokeColor, alpha: shape.alpha),
                mask: mask.name,
                texture: shape.strokeTexture,
                textureMap: CoverageGeometry.fillMap(mask: mask.bounds, path: path.boundingBox)
            ))
        }
        return parts
    }

    /// How much `passes` and their composites stage.
    private func measure(_ passes: [SpriteBatcher.Pass], vertexBytes: inout Int, indexCount: inout Int) {
        for pass in passes {
            switch pass {
            case let .batches(batches):
                for batch in batches where !batch.indices.isEmpty {
                    vertexBytes += batch.vertices.count * MemoryLayout<Float>.size
                    indexCount += batch.indices.count
                }
            case let .effect(bounds, _, _, _, _, _, _, _, _, contents):
                measure(contents, vertexBytes: &vertexBytes, indexCount: &indexCount)
                if bounds.width > 0, bounds.height > 0 {
                    vertexBytes += 4 * Self.vertexStride
                    indexCount += 6
                }
            case let .crop(_, mask, contents):
                measure(mask, vertexBytes: &vertexBytes, indexCount: &indexCount)
                measure(contents, vertexBytes: &vertexBytes, indexCount: &indexCount)
            case let .coverage(staged):
                for part in staged.parts where !part.run.indices.isEmpty {
                    vertexBytes += part.run.vertices.count * MemoryLayout<Float>.size
                    indexCount += part.run.indices.count
                }
            case .label, .shape:
                break
            }
        }
    }

    private func write(_ passes: [SpriteBatcher.Pass], into writer: inout StreamWriter) -> [SpriteBatcher.Pass] {
        passes.map { pass in
            switch pass {
            case var .batches(batches):
                for index in batches.indices where !batches[index].indices.isEmpty {
                    batches[index].streamFirstIndex = writer.add(batches[index].vertices, batches[index].indices)
                    batches[index].streamFirstVertex = writer.lastFirstVertex
                }
                return .batches(batches)
            case let .effect(bounds, transform, shader, alpha, blendMode, rasterize, owner, generation, digest, contents):
                if rasterize, !(contents.isEmpty && skippedRaster.contains(owner)) { rasterContents[owner] = contents }
                let staged = write(contents, into: &writer)
                if bounds.width > 0, bounds.height > 0 {
                    var quad = compositeQuad(bounds: bounds, transform: transform, alpha: alpha, shader: shader, blendMode: blendMode)
                    if !quad.indices.isEmpty {
                        quad.streamFirstIndex = writer.add(quad.vertices, quad.indices)
                        quad.streamFirstVertex = writer.lastFirstVertex
                        stagedComposites[owner] = quad
                    }
                }
                return .effect(
                    bounds: bounds, transform: transform, shader: shader, alpha: alpha, blendMode: blendMode,
                    rasterize: rasterize, owner: owner, generation: generation, digest: digest, contents: staged
                )
            case let .crop(transform, mask, contents):
                return .crop(transform: transform, mask: write(mask, into: &writer), contents: write(contents, into: &writer))
            case var .coverage(staged):
                for index in staged.parts.indices where !staged.parts[index].run.indices.isEmpty {
                    staged.parts[index].streamFirstIndex = writer.add(staged.parts[index].run.vertices, staged.parts[index].run.indices)
                    staged.parts[index].streamFirstVertex = writer.lastFirstVertex
                }
                return .coverage(staged)
            case .label, .shape:
                return pass
            }
        }
    }

    /// Gives a draw that isn't in the frame's stream (a bake, a kept target
    /// drawn again) buffers of its own: re-specified with its data, which
    /// every driver backs with fresh storage where a draw still to run
    /// reads the old. Hands back where its indices start, for `drawElements`.
    private func uploadDynamic(vertices: [Float], indices: [UInt16]) -> Int {
        let vertexTarget = GLenum(GL_COPY_WRITE_BUFFER)
        let indexTarget = GLenum(GL_COPY_READ_BUFFER)
        glBindBuffer(vertexTarget, dynamicVBO)
        glBindBuffer(indexTarget, dynamicEBO)
        streamMaps += 2
        vertices.withUnsafeBytes { source in
            glBufferData(vertexTarget, source.count, source.baseAddress, GLenum(GL_STREAM_DRAW))
        }
        var rebased = [UInt32](repeating: 0, count: indices.count)
        rebased.withUnsafeMutableBytes { StreamWriter.rebase(indices, by: 0, into: $0.baseAddress!) }
        rebased.withUnsafeBytes { source in
            glBufferData(indexTarget, source.count, source.baseAddress, GLenum(GL_STREAM_DRAW))
        }
        glBindBuffer(vertexTarget, 0)
        glBindBuffer(indexTarget, 0)
        return 0
    }

    private func drawElements(count: Int, first: Int) {
        glDrawElements(
            GLenum(GL_TRIANGLES), GLsizei(count), GLenum(GL_UNSIGNED_INT),
            UnsafeRawPointer(bitPattern: first * MemoryLayout<UInt32>.size)
        )
        drawCalls += 1
    }

    /// A draw from the frame's stream, given the vertices it reaches
    /// (`vertexCount` from `firstVertex`). Without the range a Mali driver
    /// reads every index of the draw on the CPU to find it: with shapes as
    /// triangles, tens of thousands of indices a frame and most of what the
    /// draw calls cost on a Galaxy M31 (simpleperf, `libGLES_mali` under
    /// `glDrawElements`).
    private func drawElements(count: Int, first: Int, vertices firstVertex: Int, _ vertexCount: Int) {
        guard vertexCount > 0 else { return drawElements(count: count, first: first) }
        glDrawRangeElements(
            GLenum(GL_TRIANGLES), GLuint(firstVertex), GLuint(firstVertex + vertexCount - 1),
            GLsizei(count), GLenum(GL_UNSIGNED_INT),
            UnsafeRawPointer(bitPattern: first * MemoryLayout<UInt32>.size)
        )
        drawCalls += 1
    }

    /// A uniform's location in `program`, asked of GL once.
    private func uniformLocation(_ program: GLuint, _ name: String) -> GLint {
        if let known = uniformLocations[program]?[name] { return known }
        let location = glGetUniformLocation(program, name)
        uniformLocations[program, default: [:]][name] = location
        return location
    }

    private func draw(
        _ batch: SpriteBatcher.Batch,
        projection: [Float],
        time: Float,
        overrideProgram: GLuint = 0,
        fragSpace: FragCoordSpace? = nil,
        texture override: GLuint = 0,
        span: SIMD2<Float>? = nil
    ) {
        guard !batch.indices.isEmpty else { return }

        let program: GLuint
        if overrideProgram != 0 {
            program = overrideProgram
        } else if let shader = batch.shader {
            program = cache.program(for: shader)
            guard program != 0 else { return }
        } else {
            program = defaultProgram
            guard program != 0 else { return }
        }
        useProgram(program)
        let held = state.uniforms(of: program)
        setProjection(projection, program: program, held: held)

        // Which pixels `gl_FragCoord` counts. Every lit shader in the game
        // reads it, so this is pushed whether or not the batch has a shader
        // of its own — the location simply comes back -1 when it is unused.
        setFragSpace(fragSpace ?? target.fragSpace, program: program, held: held)

        if let shader = batch.shader, overrideProgram == 0 {
            bind(shader, program: program, held: held, time: time)
            bind(batch.attributeValues, program: program, shader: shader)
            if let span {
                // A band's strip in place of the whole effect node's texture
                // (`drawBandBlur`): the program no longer holds the shader's
                // own values.
                let location = uniformLocation(program, "u_span")
                if location >= 0 { glUniform2f(location, span.x, span.y) }
                held.shader = nil
            }
        }

        let name: GLuint
        if override != 0 {
            name = override
        } else if let texture = batch.texture {
            name = batch.ownImage ? cache.imageName(for: texture) : cache.drawnName(for: texture)
            // Its page still decoding: left out of this frame.
            if name == 0, cache.defersPages { return }
        } else {
            name = cache.name(for: SceneRenderer.white)
        }
        bindSprite(name, program: program, held: held)
        // A textured stroke's texture repeats along it and clamps across,
        // through a sampler of its own, so the texture's own wrapping (what
        // its sprites sample with) is left as it is.
        if batch.repeatsAlong { glBindSampler(0, alongSampler()) }

        // SpriteKit's blend modes over premultiplied colour. A light drawn as
        // a `.multiplyX2` pass leaves what's under a grey of 0.5 as painted.
        setBlend(batch.blendMode)

        if batch.streamFirstIndex >= 0 {
            bindVertexArray(vao)
            drawElements(count: batch.indices.count, first: batch.streamFirstIndex, vertices: batch.streamFirstVertex, batch.vertices.count / SpriteBatcher.floatsPerVertex)
        } else {
            let first = uploadDynamic(vertices: batch.vertices, indices: batch.indices)
            bindVertexArray(dynamicVAO)
            drawElements(count: batch.indices.count, first: first)
        }
        if batch.repeatsAlong { glBindSampler(0, 0) }
        quadsDrawn += batch.quadCount
    }

    private var alongSamplerName: GLuint = 0

    /// Linear, as every texture here is drawn; repeating along a stroke
    /// (`s`) and clamped across it (`t`), so the feathered rim past each
    /// side reads the edge rather than the other side.
    private func alongSampler() -> GLuint {
        if alongSamplerName != 0 { return alongSamplerName }
        var name: GLuint = 0
        glGenSamplers(1, &name)
        glSamplerParameteri(name, GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glSamplerParameteri(name, GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glSamplerParameteri(name, GLenum(GL_TEXTURE_WRAP_S), GL_REPEAT)
        glSamplerParameteri(name, GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        alongSamplerName = name
        return name
    }

    // MARK: State, set only where it changes

    private func useProgram(_ program: GLuint) {
        guard state.program != program else { return }
        glUseProgram(program)
        state.program = program
    }

    private func bindVertexArray(_ array: GLuint) {
        guard state.vertexArray != array else { return }
        glBindVertexArray(array)
        state.vertexArray = array
    }

    private func activateUnit(_ unit: Int) {
        guard state.activeUnit != unit else { return }
        glActiveTexture(GLenum(GL_TEXTURE0) + GLenum(unit))
        state.activeUnit = unit
    }

    /// The sprite's own texture, on unit 0. Always bound: uploads land on
    /// the active unit, which is 0 between draws, and leave it unbound.
    private func bindSprite(_ name: GLuint, program: GLuint, held: GLStateCache.ProgramUniforms) {
        activateUnit(0)
        glBindTexture(GLenum(GL_TEXTURE_2D), name)
        state.textures[0] = name
        guard !held.samplerSet else { return }
        let sampler = uniformLocation(program, "u_texture")
        if sampler >= 0 { glUniform1i(sampler, 0) }
        held.samplerSet = true
    }

    /// A shader's sampler on `unit` (1 and up), left as it is when the unit
    /// holds it already. Unit 0 is active again afterwards.
    private func bindSampler(_ name: GLuint, unit: Int) {
        if unit < GLStateCache.units, state.textures[unit] == name { return }
        activateUnit(unit)
        glBindTexture(GLenum(GL_TEXTURE_2D), name)
        if unit < GLStateCache.units { state.textures[unit] = name }
        activateUnit(0)
    }

    private func setProjection(_ projection: [Float], program: GLuint, held: GLStateCache.ProgramUniforms) {
        guard held.projection != projection else { return }
        let location = uniformLocation(program, "u_projection")
        if location >= 0 {
            var matrix = projection
            glUniformMatrix4fv(location, 1, GLboolean(GL_FALSE), &matrix)
        }
        held.projection = projection
    }

    private func setFragSpace(_ space: FragCoordSpace, program: GLuint, held: GLStateCache.ProgramUniforms) {
        guard held.fragSpace != space else { return }
        let location = uniformLocation(program, ShaderTranslator.fragCoordUniform)
        if location >= 0 {
            glUniform4f(location, space.offsetX, space.offsetY, space.scaleX, space.scaleY)
        }
        held.fragSpace = space
    }

    private func setBlend(_ mode: SKBlendMode) {
        let blend: GLStateCache.Blend
        switch mode {
        case .add:
            blend = .init(enabled: true, equation: GLenum(GL_FUNC_ADD), source: GLenum(GL_ONE), destination: GLenum(GL_ONE))
        case .subtract:
            blend = .init(enabled: true, equation: GLenum(GL_FUNC_REVERSE_SUBTRACT), source: GLenum(GL_ONE), destination: GLenum(GL_ONE))
        case .multiply:
            blend = .init(enabled: true, equation: GLenum(GL_FUNC_ADD), source: GLenum(GL_DST_COLOR), destination: GLenum(GL_ONE_MINUS_SRC_ALPHA))
        case .multiplyX2:
            blend = .init(enabled: true, equation: GLenum(GL_FUNC_ADD), source: GLenum(GL_DST_COLOR), destination: GLenum(GL_SRC_COLOR))
        case .screen:
            blend = .init(enabled: true, equation: GLenum(GL_FUNC_ADD), source: GLenum(GL_ONE), destination: GLenum(GL_ONE_MINUS_SRC_COLOR))
        case .replace:
            // The function stays as it was, or unknown (0) if it was.
            blend = .init(enabled: false, equation: state.blend?.equation ?? 0,
                          source: state.blend?.source ?? 0, destination: state.blend?.destination ?? 0)
        case .alpha, .multiplyAlpha:
            blend = .init(enabled: true, equation: GLenum(GL_FUNC_ADD), source: GLenum(GL_ONE), destination: GLenum(GL_ONE_MINUS_SRC_ALPHA))
        }
        let was = state.blend
        guard was != blend else { return }
        if was?.enabled != blend.enabled {
            if blend.enabled { glEnable(GLenum(GL_BLEND)) } else { glDisable(GLenum(GL_BLEND)) }
        }
        // A disabled blend keeps whatever function it had.
        if blend.enabled {
            if was?.equation != blend.equation { glBlendEquation(blend.equation) }
            if was?.source != blend.source || was?.destination != blend.destination {
                glBlendFunc(blend.source, blend.destination)
            }
        }
        state.blend = blend
    }

    // MARK: Touches

    /// Turns a touch into a point in the scene and hands it to the scene
    /// graph. The projection is this renderer's, so undoing it is too: the
    /// shell passes SDL's normalised window coordinates through untouched.
    public func receive(_ touch: TouchEvent) {
        guard let scene = view.scene else { return }
        // One finger at a time, as the game asks of its view on iOS
        // (`isMultipleTouchEnabled = false`): a second finger is ignored
        // until the first lifts.
        if touch.phase == .began {
            guard primaryFinger == nil else { return }
            primaryFinger = touch.finger
            timings.pressed()
        }
        guard touch.finger == primaryFinger else { return }
        if touch.phase == .ended || touch.phase == .cancelled { primaryFinger = nil }
        // SDL's location is a share of the window from its top left, which
        // is UIKit's way round; the scene maps it on through its camera.
        let inView = CGPoint(
            x: touch.location.x * view.bounds.width,
            y: touch.location.y * view.bounds.height
        )
        let point = scene.convertPoint(fromView: inView)
        let phase: UITouchPhase
        switch touch.phase {
        case .began: phase = .began
        case .moved: phase = .moved
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        }
        // A text field taking typing is a view over the game's on iOS, so a
        // touch that starts on it is the field's, not the scene's.
        if phase == .began { touchIsField = UITextField.takesTouch(at: inView) }
        if touchIsField {
            UITextField.touch(phase, at: inView)
            return
        }
        scene.deliverTouch(phase: phase, at: point, identifier: touch.finger, timestamp: touch.time)
    }

    /// The finger the scene is following, if one is down.
    private var primaryFinger: Int?
    /// Whether that finger came down on the text field taking typing.
    private var touchIsField = false

    /// Input other than touches, for whoever drives the scene (the game's
    /// controller). Unset, nothing takes it.
    public var onInput: ((InputEvent) -> Bool)?
    /// The window's metrics, with the view already resized to the drawable.
    public var onMetrics: ((WindowMetrics, SKView) -> Void)?
    /// Called once, after the first metrics have been handed on.
    public var onAppear: (() -> Void)?
    private var appeared = false

    public func receive(_ input: InputEvent) -> Bool {
        timings.pressed()
        return onInput?(input) ?? false
    }

    public func windowMetricsDidChange(_ metrics: WindowMetrics) {
        refreshInterval = 1 / Double(max(metrics.refreshRate, 1))
        view.refreshInterval = refreshInterval
        // The density can change (another display, a fold): points follow it.
        view.resize(drawable: drawableSize, displayScale: metrics.displayScale)
        let scale = view.contentScaleFactor
        view.safeAreaInsets = UIEdgeInsets(
            top: metrics.safeArea.top / scale, left: metrics.safeArea.left / scale,
            bottom: metrics.safeArea.bottom / scale, right: metrics.safeArea.right / scale
        )
        onMetrics?(metrics, view)
        if !appeared {
            appeared = true
            onAppear?()
        }
    }

    /// The shell tells `UIApplication` itself; a touch in flight as the
    /// game leaves is cancelled, so no button stays pressed.
    public func applicationStateDidChange(active: Bool) {
        guard !active else { return }
        view.scene?.cancelTouches(timestamp: MediaTime.source())
        primaryFinger = nil
    }

    /// How the presented scene's points map onto the drawable. In a
    /// transition the view draws both scenes in the incoming one's
    /// coordinates, so this is always the presented scene's.
    private var viewport: Viewport {
        let scene = view.scene
        return Viewport(
            drawableSize: drawableSize,
            sceneSize: scene?.size ?? view.bounds.size,
            scaleMode: scene?.scaleMode ?? .aspectFill,
            anchorPoint: scene?.anchorPoint ?? .zero
        )
    }

    /// Pushes a shader's uniforms. `u_time` is the game's shader clock and
    /// must come from the shell's monotonic clock, not the wall clock, or the
    /// currents and lights run at the wrong pace.
    ///
    /// A program keeps its uniforms, so when it already holds this shader's
    /// (the last drawn with it was this shader, and none of its uniforms has
    /// been written since: a skeletal rig's dozens of sprites in a row) only its
    /// textures are bound again, as units are shared by every program.
    private func bind(_ shader: SKShader, program: GLuint, held: GLStateCache.ProgramUniforms, time: Float) {
        if held.time != time {
            let timeLocation = uniformLocation(program, "u_time")
            if timeLocation >= 0 { glUniform1f(timeLocation, time) }
            held.time = time
        }

        let uniforms = shader.uniforms
        if held.holds(shader) {
            let locations = held.locations
            var unit = 1
            for (index, uniform) in uniforms.enumerated() {
                guard case let .texture(t) = uniform.value, let t, locations[index] >= 0 else { continue }
                bindSampler(cache.samplerName(for: t), unit: unit)
                unit += 1
            }
            return
        }

        var locations: [GLint] = []
        var generations: [UInt32] = []
        locations.reserveCapacity(uniforms.count)
        generations.reserveCapacity(uniforms.count)
        var unit: GLint = 1
        for uniform in uniforms {
            let location = uniformLocation(program, uniform.name)
            locations.append(location)
            generations.append(uniform.generation)
            guard location >= 0 else { continue }
            switch uniform.value {
            case let .float(v):
                glUniform1f(location, Float(v))
            case let .vector2(v):
                glUniform2f(location, v.x, v.y)
            case let .vector3(v):
                glUniform3f(location, v.x, v.y, v.z)
            case let .vector4(v):
                glUniform4f(location, v.x, v.y, v.z, v.w)
            case var .matrix2(v):
                glUniformMatrix2fv(location, 1, GLboolean(GL_FALSE), &v)
            case var .matrix3(v):
                glUniformMatrix3fv(location, 1, GLboolean(GL_FALSE), &v)
            case var .matrix4(v):
                // Not exotic: Metal gives a shader 31 buffers and a uniform
                // takes one each, so a game may pack sets of values into a
                // matrix a column apiece — colour tints, or several objects'
                // places and poses.
                glUniformMatrix4fv(location, 1, GLboolean(GL_FALSE), &v)
            case let .texture(t):
                guard let t else { continue }
                bindSampler(cache.samplerName(for: t), unit: Int(unit))
                glUniform1i(location, unit)
                unit += 1
            }
        }
        held.shader = shader
        held.shaderRevision = shader.revision
        held.generations = generations
        held.locations = locations
    }

    /// Pushes a node's own `SKAttribute` values.
    ///
    /// These are per node, not per vertex: SpriteKit's are, and the batcher
    /// honours that by never merging a sprite that carries them into another
    /// sprite's batch. So each is a uniform of the fragment stage
    /// (`ShaderTranslator`), set before the sprite's draw: one call per value
    /// and no buffer traffic, as constant vertex attributes were, without
    /// the varyings that carried those, which dropped mesh triangles on Mali.
    ///
    /// Only what the node set is pushed. SpriteKit requires every attribute a
    /// shader declares to be set on every node drawn with it, so a missing one
    /// is a bug upstream rather than something to invent a value for.
    private func bind(_ values: [String: SKAttributeValue], program: GLuint, shader: SKShader) {
        guard !values.isEmpty else { return }
        var locations = attributeLocations[program] ?? [:]
        var learned = false
        for attribute in shader.attributes {
            guard let value = values[attribute.name] else { continue }
            let location: GLint
            if let known = locations[attribute.name] {
                location = known
            } else {
                location = glGetUniformLocation(program, attribute.name)
                locations[attribute.name] = location
                learned = true
            }
            guard location >= 0 else { continue }
            switch value.value {
            case let .float(v):
                glUniform1f(location, Float(v))
            case let .vector2(v):
                glUniform2f(location, v.x, v.y)
            case let .vector3(v):
                glUniform3f(location, v.x, v.y, v.z)
            case let .vector4(v):
                glUniform4f(location, v.x, v.y, v.z, v.w)
            case .texture, .matrix2, .matrix3, .matrix4:
                // `SKAttributeValue` shares `SKUniform.Value`, but SpriteKit's
                // `SKAttributeType` has no textures and no matrices, so neither
                // can reach a node's attributes. Skipped, as before.
                continue
            }
        }
        if learned { attributeLocations[program] = locations }
    }

    /// Pixels for a texture the asset index does not back. Three kinds, and
    /// they must not be confused:
    ///
    ///  - **Raw pixels** (`.data`), as SpriteKit's `SKTexture(data:size:)`
    ///    takes them: RGBA8, rows bottom first. `GLDevice.createTexture`
    ///    reverses the rows because its usual input is a decoded PNG, which
    ///    stores the top row first, so these are reversed here and the two
    ///    flips cancel. A noise lattice a game's shaders sample is one. Left
    ///    unanswered it uploads as one white pixel and the shader draws flat.
    ///  - **An encoded image** (`.encoded`): a file's bytes, which is what
    ///    `SKTexture(image:)` carries — an image page that lives outside the
    ///    packed art. Decoded here.
    ///  - **A flat colour** (`.color`), premultiplied like the art, since the
    ///    whole pipeline blends that way.
    ///  - **A drawn image** (`.image`): what the game painted through a
    ///    `CGContext` — every chunky surface — already premultiplied RGBA8.
    nonisolated private static func pixels(of texture: SKTexture) -> (width: Int, height: Int, pixels: Data)? {
        switch texture.source {
        case let .data(data):
            let size = texture.size()
            let width = Int(size.width.rounded())
            let height = Int(size.height.rounded())
            guard width > 0, height > 0, data.count >= width * height * 4 else {
                Log.error("raw texture data is \(data.count) bytes, too few for \(width)x\(height) RGBA")
                return nil
            }
            return (width, height, Premultiply.flippedRows(data, width: width, height: height))

        case let .encoded(data):
            do {
                let image = try PNGDecoder.decode(data)
                return (image.width, image.height, Premultiply.rgba(image.pixels))
            } catch {
                Log.error("a texture's image would not decode: \(error)")
                return nil
            }

        case let .color(colour, size):
            let width = max(1, Int(size.width.rounded()))
            let height = max(1, Int(size.height.rounded()))
            func byte(_ value: CGFloat) -> UInt8 { UInt8(clamping: Int((max(0, min(1, value)) * 255).rounded())) }
            let a = colour.alpha
            let pixel: [UInt8] = [
                byte(colour.red * a), byte(colour.green * a), byte(colour.blue * a), byte(a),
            ]
            return (width, height, Data(Array(repeating: pixel, count: width * height).joined()))

        case .image:
            // Drawn by the game through a `CGContext` — every chunky surface
            // arrives this way, already RGBA8 premultiplied, so there is
            // nothing to decode.
            return texture.ownPixels
        case .named, .slice:
            return nil
        }
    }

    /// Stands in for "no texture": a sprite with only a colour still samples
    /// something, so one white pixel keeps the default shader uniform.
    private static let white = SKTexture(color: .white, size: CGSize(width: 1, height: 1))
}
