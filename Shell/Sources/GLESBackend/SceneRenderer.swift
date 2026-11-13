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
public final class SceneRenderer: FrameRenderer {
    private let device = GLDevice()
    private let cache: ResourceCache
    private let batcher = SpriteBatcher()
    private lazy var targets = RenderTargetPool(device: device)

    /// The view the game presents its scenes in. Its bounds are in points
    /// (`pointScale` pixels each), as UIKit's are; the drawable is pixels.
    public let view: SKView
    private var drawableSize: CGSize

    private var vao: GLuint = 0
    private var vbo: GLuint = 0
    private var ebo: GLuint = 0
    private var defaultProgram: GLuint = 0
    /// Glyphs and rasterised shape masks: 8-bit coverage, the node's colour.
    private var coverageProgram: GLuint = 0
    /// An `SKCropNode`'s mask, written into the stencil.
    private var maskProgram: GLuint = 0

    private let glyphPages = GlyphPages(atlas: TextEngine.shared.atlas)
    private let glyphSource = EngineGlyphSource(engine: TextEngine.shared)
    private let shapeMasks = ShapeMasks()

    /// Pixels per point, so glyphs are rasterised and masks filled at the
    /// density they are drawn at rather than at one pixel per point.
    private var deviceScale: CGFloat = 1

    /// Pixels for a packed page, by its index in `AssetIndex.pages`.
    private let pageLoader: (Int) -> (width: Int, height: Int, pixels: Data)?

    /// Set once the first frame has been drawn, so the log says it happened
    /// exactly once rather than every frame.
    private var reportedFirstFrame = false

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
    }

    private var target = Target(
        framebuffer: 0, widthInPixels: 0, heightInPixels: 0,
        visible: .zero, fragSpace: .target(heightInPixels: 0)
    )

    /// How deep the crop nodes are nested, which is also the stencil value
    /// the contents at this level must match.
    private var cropDepth: Int32 = 0
    /// Rasterizing effect nodes drawn this frame, so the pool can drop the
    /// targets of ones that went away.
    private var liveKept: Set<RenderTargetPool.Key> = []
    /// Set once per build, so a mask carrying its own shader is reported
    /// rather than quietly clipped to the wrong shape.
    private var warnedShadedMask = false
    private var warnedRotatedEffect = false
    private var clampedEffects: Set<ObjectIdentifier> = []
    /// Textures handed to the game by `texture(from:)`, by the node they
    /// were baked from. A backdrop bakes its floor again on every layout, so
    /// the one it had is dropped here rather than left on the GPU.
    private var bakedTextures: [ObjectIdentifier: UInt32] = [:]

    // MARK: The frame's tally, for the performance report

    public private(set) var drawCalls = 0
    public private(set) var targetBinds = 0
    public private(set) var effectsDrawn = 0
    public private(set) var effectsCached = 0
    public private(set) var quadsDrawn = 0

    /// Where each per-node attribute sits in each program, looked up once.
    /// A rig mesh sprite carries twelve of them and there are dozens of
    /// sprites in a Switchling, so this is a few thousand `glGetAttribLocation`
    /// calls a frame if it is not kept.
    private var attributeLocations: [GLuint: [String: GLint]] = [:]

    /// Shows `scene` from the first frame.
    public convenience init(
        scene: SKScene,
        drawableSize: CGSize,
        pointScale: CGFloat,
        pageLoader: @escaping (Int) -> (width: Int, height: Int, pixels: Data)?
    ) {
        self.init(drawableSize: drawableSize, pointScale: pointScale, pageLoader: pageLoader) {
            $0.presentScene(scene)
        }
    }

    /// Hands `start` the view, which presents what it likes in it — through
    /// the game's own `TransitionManager`, say.
    public init(
        drawableSize: CGSize,
        pointScale: CGFloat,
        pageLoader: @escaping (Int) -> (width: Int, height: Int, pixels: Data)?,
        start: (SKView) -> Void
    ) {
        self.pageLoader = pageLoader
        self.drawableSize = drawableSize
        cache = ResourceCache(device: device)
        view = SKView(bounds: CGRect(origin: .zero, size: Self.points(drawableSize, scale: pointScale)))
        view.contentScaleFactor = pointScale
        cache.pageSource = pageLoader
        // Textures the asset index does not back: the noise lattices the
        // shaders sample (`Starlight.noise` is an `SKTexture(data:size:)`
        // the sky's nebula, its clouds and its mottled blue all read through
        // `starNoise`), and solid-colour stand-ins. Without this they upload
        // as one white pixel, and a shader reading constant noise draws
        // something plausible rather than nothing — a flat sky with no
        // nebula, which is how this was found.
        cache.pixelSource = Self.pixels(of:)
        start(view)
    }

    private static func points(_ pixels: CGSize, scale: CGFloat) -> CGSize {
        scale > 0 ? CGSize(width: pixels.width / scale, height: pixels.height / scale) : pixels
    }

    // MARK: Lifecycle

    public func rendererDidStart(_ context: RenderContext) {
        Log.info("GLSL \(context.shadingLanguageVersion)")

        // A rig mesh sprite carries four triangles as twelve vec4s, and the
        // quad's own four attributes bring that to sixteen — exactly what
        // GLES 3.0 guarantees. Worth saying out loud, because a driver at
        // the minimum leaves no room and a rig shader would simply not link.
        var maxAttributes: GLint = 0
        glGetIntegerv(GLenum(GL_MAX_VERTEX_ATTRIBS), &maxAttributes)
        Log.info("max vertex attributes \(maxAttributes) (rig meshes need 16)")

        glGenVertexArrays(1, &vao)
        glBindVertexArray(vao)
        glGenBuffers(1, &vbo)
        glGenBuffers(1, &ebo)

        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
        glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), ebo)

        // The batcher's interleaving: x y u v r g b a blend.
        let stride = GLsizei(SpriteBatcher.floatsPerVertex * MemoryLayout<Float>.size)
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

        maskProgram = device.createProgram(
            vertex: ShaderTranslator.spriteVertexShader(),
            fragment: ShaderTranslator.maskFragmentShader
        )
        if maskProgram == 0 { Log.error("the crop mask program did not link") }

        // The art is premultiplied, so this is the blend for it.
        glEnable(GLenum(GL_BLEND))
        glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA))
        glDisable(GLenum(GL_DEPTH_TEST))
        glClearColor(0, 0, 0, 1)

        // `bake` and the baked floors every live backdrop keeps go through
        // this: the game asks its view for a texture of a subtree, and only
        // the renderer can answer, since only it has a framebuffer. The hook
        // is `SKViewSnapshot.swift`'s, which also explains why the priming
        // calls that throw the texture away need no pixels here.
        SKView.snapshot = { [weak self] _, node, crop in
            self?.bake(node, crop: crop)
        }

        Log.info("max texture side \(device.maximumTextureSide)")
    }

    public func drawableSizeDidChange(to size: CGSize) {
        drawableSize = size
        view.bounds = CGRect(origin: .zero, size: Self.points(size, scale: view.contentScaleFactor))
        glViewport(0, 0, GLsizei(size.width), GLsizei(size.height))
        Log.info("drawable \(Int(size.width)) x \(Int(size.height))")
    }

    public func rendererWillStop() {
        SKView.snapshot = nil
        for name in bakedTextures.values { device.deleteTexture(name) }
        bakedTextures.removeAll()
        targets.removeAll()
        cache.removeAll()
        glyphPages.removeAll()
        shapeMasks.removeAll()
        glyphSource.flush()
        if coverageProgram != 0 { device.deleteProgram(coverageProgram) }
        if maskProgram != 0 { device.deleteProgram(maskProgram) }
        // A new context relinks every program, and GL reuses names, so a
        // location learned for an old one must not be trusted again.
        attributeLocations.removeAll()
        if defaultProgram != 0 { device.deleteProgram(defaultProgram) }
        glDeleteBuffers(1, &vbo)
        glDeleteBuffers(1, &ebo)
        glDeleteVertexArrays(1, &vao)
    }

    // MARK: Frames

    /// The view's frame rate, pause and delegate decide.
    public func shouldDraw(_ frame: Frame) -> Bool {
        view.shouldRender(atTime: frame.time)
    }

    public func drawFrame(_ frame: Frame) {
        // The scene first: a transition, or a scene presenting another, can
        // change which scene the view shows, and the projection is that
        // scene's.
        let started = MediaTime.source()
        let list = view.tick(currentTime: frame.time, delta: frame.delta / max(slowdown, 1))
        noteSceneChange(at: frame.time)
        let passes = batcher.passes(for: list)
        // Ticking the actions, flattening the scene graph and batching it:
        // the port's own cost, with no GL in it. Worth separating, because
        // the rest of the frame on an emulator is mostly the host GL pipe
        // and says little about a phone, while this number carries across.
        let flattened = MediaTime.source()

        let projection = viewport.projection
        deviceScale = max(viewport.scale.x, viewport.scale.y)
        glyphSource.deviceScale = deviceScale

        target = Target(
            framebuffer: 0,
            widthInPixels: Int(frame.size.width),
            heightInPixels: Int(frame.size.height),
            visible: viewport.visibleSceneRect,
            fragSpace: .target(heightInPixels: Int(frame.size.height))
        )
        bindTarget()
        // The stencil clears with the colour: every crop node is balanced
        // (it increments on the way in and decrements on the way out), so a
        // frame starts with the buffer already zero — but a lost context or
        // a half-drawn frame would otherwise leave a stale mask behind.
        glClearStencil(0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT) | GLbitfield(GL_STENCIL_BUFFER_BIT))

        drawCalls = 0
        targetBinds = 1
        effectsDrawn = 0
        effectsCached = 0
        quadsDrawn = 0
        liveKept.removeAll(keepingCapacity: true)
        cropDepth = 0

        glBindVertexArray(vao)
        draw(passes, projection: projection, time: Float(frame.time))
        glBindVertexArray(0)

        targets.evictKept(except: liveKept)
        targets.endFrame()

        if !reportedFirstFrame {
            reportedFirstFrame = true
            Log.info("first frame: \(quadsDrawn) quads, \(drawCalls) draw calls, \(targetBinds) target binds")
        }
        report.add(
            delta: frame.delta,
            cpu: MediaTime.source() - started,
            scene: flattened - started,
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
                    + "\(shapeMasks.rasterised) masks rasterised"
            )
        }
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
            }
        }
    }

    /// `SKEffectNode`: the subtree into an offscreen texture, then that
    /// texture through the node's shader.
    ///
    /// The four behaviours AGENTS.md says the game depends on, and where each
    /// one is honoured:
    ///
    ///  - **The texture spans children that are off screen.** `bounds` is the
    ///    shim's `calculateAccumulatedFrame()`, which walks every child
    ///    whether the viewport shows it or not, and nothing here clips it to
    ///    the visible rect. That is what lets the live edge blur find its
    ///    buttons wherever they sit.
    ///  - **It renders at the scene's density, not the node's.** The density
    ///    comes from the bound target, so `BandedLayerNode` magnifying a band
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
        // nothing. This is the common case: `BackdropNode` wraps its scenery
        // in one and only turns the shader on behind the round buttons.
        guard shader != nil || rasterize || alpha < 0.999 else {
            draw(contents, projection: projection, time: time)
            return
        }
        guard bounds.width > 0, bounds.height > 0 else { return }

        let density = target.visible.height > 0
            ? CGFloat(target.heightInPixels) / target.visible.height
            : 1
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
            glClearColor(0, 0, 0, 0)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            draw(contents, projection: texture.projection, time: time)

            target = outer
            cropDepth = outerDepth
            bindTarget()
            glClearColor(0, 0, 0, 1)
            if outerDepth > 0 { glEnable(GLenum(GL_STENCIL_TEST)) }
        } else {
            effectsCached += 1
        }

        // The composite. `gl_FragCoord` must land in the texture just drawn,
        // not in the framebuffer being drawn into.
        var space = target.fragSpace
        if let mapped = texture.composite(
            transform: transform,
            visible: target.visible,
            parentHeightInPixels: target.heightInPixels
        ) {
            space = mapped
        } else if shader != nil, !warnedRotatedEffect {
            warnedRotatedEffect = true
            Log.error(
                "an effect node's transform is rotated or skewed; its shader's gl_FragCoord "
                + "falls back to the target's own pixels, which is not what SpriteKit reports"
            )
        }

        let quad = compositeQuad(
            bounds: bounds, transform: transform, alpha: alpha,
            texture: handle.texture, shader: shader, blendMode: blendMode
        )
        draw(quad, projection: projection, time: time, fragSpace: space)
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
            case .label, .shape:
                break
            }
        }
    }

    // MARK: Baking

    /// `SKView.texture(from:)`: a subtree rendered to a texture the game then
    /// samples. Every live backdrop bakes its floor this way once per layout.
    private func bake(_ node: SKNode, crop: CGRect?) -> SKTexture? {
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
        list.commands = DrawList(scene: node).commands
        let passes = batcher.passes(for: list)

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
        glClearColor(0, 0, 0, 0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        glBindVertexArray(vao)
        draw(passes, projection: plan.projection, time: 0)
        glBindVertexArray(0)

        target = outer
        cropDepth = outerDepth
        bindTarget()
        glClearColor(0, 0, 0, 1)
        if outerDepth > 0 { glEnable(GLenum(GL_STENCIL_TEST)) }

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

        // A backdrop re-bakes its floor whenever it lays out, and the one it
        // had is unreachable from that moment.
        let key = ObjectIdentifier(node)
        if let previous = bakedTextures[key] { device.deleteTexture(previous) }
        bakedTextures[key] = handle.texture
        return baked
    }

    private func bindTarget() {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), target.framebuffer)
        glViewport(0, 0, GLsizei(target.widthInPixels), GLsizei(target.heightInPixels))
        targetBinds += 1
    }

    /// A quad covering `bounds` under `transform`, carrying the effect's
    /// texture whole. Built through the batcher so the vertex layout and the
    /// `v_color_mix` contract stay in one place.
    private func compositeQuad(
        bounds: CGRect,
        transform: CGAffineTransform,
        alpha: CGFloat,
        texture: UInt32,
        shader: SKShader?,
        blendMode: SKBlendMode
    ) -> SpriteBatcher.Batch {
        let carrier = SKTexture(color: .white, size: bounds.size)
        carrier.glName = texture

        let sprite = DrawList.Sprite(
            transform: CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
                .concatenating(transform),
            size: bounds.size,
            anchorPoint: CGPoint(x: 0.5, y: 0.5),
            texture: carrier,
            textureRect: CGRect(x: 0, y: 0, width: 1, height: 1),
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
    /// (`debug.switchlings.slowdown`, as the game's `-AnimationSlowdown`), so
    /// a 0.1-second fade can be filmed on an emulator.
    public var slowdown: Double = 1

    /// The scene on screen and whether a transition is playing, as last
    /// logged.
    private var loggedScene: ObjectIdentifier?
    private var loggedTransition = false

    /// Says in logcat when the view's scene changes and when its transition
    /// lands, with the shell's clock, so a scene change can be timed.
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
    private func draw(_ label: DrawList.Label, projection: [Float]) {
        guard coverageProgram != 0 else { return }

        // Shaping and rasterising happen inside this, so the atlas is only
        // brought up to date afterwards — a glyph seen for the first time
        // this frame is on the GPU before its quad is drawn.
        let runs = CoverageGeometry.runs(for: label, source: glyphSource)
        guard !runs.isEmpty else { return }
        glyphPages.sync()

        for run in runs {
            let name = glyphPages.name(of: run.page)
            guard name != 0 else { continue }
            drawCoverage(run, texture: name, projection: projection)
        }
    }

    // MARK: Shapes

    /// Fills and strokes a shape through the path rasteriser.
    ///
    /// The mask is rasterised axis-aligned in the node's own space at the
    /// density it will be drawn at, then drawn as one quad through the
    /// node's transform — so a rotated or animated shape costs one mask, not
    /// one per angle.
    private func draw(_ shape: DrawList.Shape, projection: [Float]) {
        guard coverageProgram != 0, let path = shape.path else { return }

        let scale = deviceScale * transformScale(shape.transform)
        guard scale > 0 else { return }

        if shape.fillColor.alpha > 0,
           let mask = shapeMasks.fill(path, rule: .nonZero, scale: scale) {
            drawCoverage(
                CoverageGeometry.run(
                    mask: mask.bounds, transform: shape.transform,
                    colour: shape.fillColor, alpha: shape.alpha
                ),
                texture: mask.name,
                projection: projection
            )
        }

        if shape.lineWidth > 0, shape.strokeColor.alpha > 0,
           let mask = shapeMasks.stroke(
               path, width: shape.lineWidth,
               cap: shape.lineCap, join: shape.lineJoin, scale: scale
           ) {
            drawCoverage(
                CoverageGeometry.run(
                    mask: mask.bounds, transform: shape.transform,
                    colour: shape.strokeColor, alpha: shape.alpha
                ),
                texture: mask.name,
                projection: projection
            )
        }
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
        projection: [Float]
    ) {
        guard !run.indices.isEmpty else { return }

        glUseProgram(coverageProgram)
        var projection = projection
        let location = glGetUniformLocation(coverageProgram, "u_projection")
        if location >= 0 {
            glUniformMatrix4fv(location, 1, GLboolean(GL_FALSE), &projection)
        }

        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        let sampler = glGetUniformLocation(coverageProgram, "u_texture")
        if sampler >= 0 { glUniform1i(sampler, 0) }

        glEnable(GLenum(GL_BLEND))
        glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA))

        upload(vertices: run.vertices, indices: run.indices)
        glDrawElements(
            GLenum(GL_TRIANGLES), GLsizei(run.indices.count),
            GLenum(GL_UNSIGNED_SHORT), nil
        )
        drawCalls += 1
        quadsDrawn += run.indices.count / 6
    }

    private func upload(vertices: [Float], indices: [UInt16]) {
        vertices.withUnsafeBufferPointer { buffer in
            glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
            glBufferData(
                GLenum(GL_ARRAY_BUFFER),
                buffer.count * MemoryLayout<Float>.size,
                buffer.baseAddress, GLenum(GL_STREAM_DRAW)
            )
        }
        indices.withUnsafeBufferPointer { buffer in
            glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), ebo)
            glBufferData(
                GLenum(GL_ELEMENT_ARRAY_BUFFER),
                buffer.count * MemoryLayout<UInt16>.size,
                buffer.baseAddress, GLenum(GL_STREAM_DRAW)
            )
        }
    }

    private func draw(
        _ batch: SpriteBatcher.Batch,
        projection: [Float],
        time: Float,
        overrideProgram: GLuint = 0,
        fragSpace: FragCoordSpace? = nil
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
        glUseProgram(program)

        var projection = projection
        let location = glGetUniformLocation(program, "u_projection")
        if location >= 0 {
            glUniformMatrix4fv(location, 1, GLboolean(GL_FALSE), &projection)
        }

        // Which pixels `gl_FragCoord` counts. Every lit shader in the game
        // reads it, so this is pushed whether or not the batch has a shader
        // of its own — the location simply comes back -1 when it is unused.
        let space = fragSpace ?? target.fragSpace
        let fragLocation = glGetUniformLocation(program, ShaderTranslator.fragCoordUniform)
        if fragLocation >= 0 {
            glUniform4f(fragLocation, space.offsetX, space.offsetY, space.scaleX, space.scaleY)
        }

        if let shader = batch.shader, overrideProgram == 0 {
            bind(shader, program: program, time: time)
            bind(batch.attributeValues, program: program, shader: shader)
        }

        glActiveTexture(GLenum(GL_TEXTURE0))
        if let texture = batch.texture {
            glBindTexture(GLenum(GL_TEXTURE_2D), cache.name(for: texture))
        } else {
            glBindTexture(GLenum(GL_TEXTURE_2D), cache.name(for: SceneRenderer.white))
        }
        let sampler = glGetUniformLocation(program, "u_texture")
        if sampler >= 0 { glUniform1i(sampler, 0) }

        switch batch.blendMode {
        case .add:
            glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE))
        case .replace:
            glDisable(GLenum(GL_BLEND))
        default:
            glEnable(GLenum(GL_BLEND))
            glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA))
        }

        upload(vertices: batch.vertices, indices: batch.indices)
        glDrawElements(
            GLenum(GL_TRIANGLES), GLsizei(batch.indices.count),
            GLenum(GL_UNSIGNED_SHORT), nil
        )
        drawCalls += 1
        quadsDrawn += batch.quadCount

        if batch.blendMode == .replace { glEnable(GLenum(GL_BLEND)) }
    }

    // MARK: Touches

    /// Turns a touch into a point in the scene and hands it to the scene
    /// graph. The projection is this renderer's, so undoing it is too: the
    /// shell passes SDL's normalised window coordinates through untouched.
    public func receive(_ touch: TouchEvent) {
        guard let scene = view.scene else { return }
        // SDL's location is a share of the window from its top left, which
        // is UIKit's way round; the scene maps it on through its camera.
        let point = scene.convertPoint(fromView: CGPoint(
            x: touch.location.x * view.bounds.width,
            y: touch.location.y * view.bounds.height
        ))
        let phase: UITouchPhase
        switch touch.phase {
        case .began: phase = .began
        case .moved: phase = .moved
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        }
        scene.deliverTouch(phase: phase, at: point, identifier: touch.finger, timestamp: touch.time)
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
    private func bind(_ shader: SKShader, program: GLuint, time: Float) {
        let timeLocation = glGetUniformLocation(program, "u_time")
        if timeLocation >= 0 { glUniform1f(timeLocation, time) }

        var unit: GLint = 1
        for uniform in shader.uniforms {
            let location = glGetUniformLocation(program, uniform.name)
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
                // takes one each, so the game packs sets of values into a
                // matrix a column apiece — `NightSkyNode`'s nebula and fold
                // tints, and the planets' places, poses and rings.
                glUniformMatrix4fv(location, 1, GLboolean(GL_FALSE), &v)
            case let .texture(t):
                guard let t else { continue }
                glActiveTexture(GLenum(GL_TEXTURE0) + GLenum(unit))
                glBindTexture(GLenum(GL_TEXTURE_2D), cache.name(for: t))
                glUniform1i(location, unit)
                unit += 1
            }
        }
    }

    /// Pushes a node's own `SKAttribute` values.
    ///
    /// These are per node, not per vertex: SpriteKit's are, and the batcher
    /// honours that by never merging a sprite that carries them into another
    /// sprite's batch. So each is a *generic* vertex attribute — the constant
    /// GL hands every vertex when no array is enabled for that location —
    /// which is one call per value per draw and no buffer traffic at all.
    ///
    /// The generated vertex shader declares them as `a_<name>` and passes
    /// them straight through to a varying called `<name>`, which is what the
    /// game's fragment source reads. Generic attribute values are context
    /// state rather than VAO state, so nothing in the VAO has to change.
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
                location = glGetAttribLocation(program, "a_" + attribute.name)
                locations[attribute.name] = location
                learned = true
            }
            guard location >= 0 else { continue }
            let index = GLuint(location)
            switch value.value {
            case let .float(v):
                glVertexAttrib1f(index, Float(v))
            case let .vector2(v):
                glVertexAttrib2f(index, v.x, v.y)
            case let .vector3(v):
                glVertexAttrib3f(index, v.x, v.y, v.z)
            case let .vector4(v):
                glVertexAttrib4f(index, v.x, v.y, v.z, v.w)
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
    ///    flips cancel. `Starlight.noise` is one — the lattice the sky's
    ///    nebula, clouds and mottled blue all sample. Left unanswered it
    ///    uploads as one white pixel and the sky draws flat with no nebula.
    ///  - **An encoded image** (`.encoded`): a file's bytes, which is what
    ///    `SKTexture(image:)` carries — a rig's page, which lives outside
    ///    the packed art. Decoded here.
    ///  - **A flat colour** (`.color`), premultiplied like the art, since the
    ///    whole pipeline blends that way.
    ///  - **A drawn image** (`.image`): what the game painted through a
    ///    `CGContext` — every chunky surface — already premultiplied RGBA8.
    private static func pixels(of texture: SKTexture) -> (width: Int, height: Int, pixels: Data)? {
        switch texture.source {
        case let .data(data):
            let size = texture.size()
            let width = Int(size.width.rounded())
            let height = Int(size.height.rounded())
            guard width > 0, height > 0, data.count >= width * height * 4 else {
                Log.error("raw texture data is \(data.count) bytes, too few for \(width)x\(height) RGBA")
                return nil
            }
            return (width, height, GLDevice.flippedVertically(data, width: width, height: height))

        case let .encoded(data):
            do {
                let image = try PNGDecoder.decode(data)
                return (image.width, image.height, image.pixels)
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
