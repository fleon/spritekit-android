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

    private let view: SKView
    private let scene: SKScene

    private var vao: GLuint = 0
    private var vbo: GLuint = 0
    private var ebo: GLuint = 0
    private var defaultProgram: GLuint = 0
    /// Glyphs and rasterised shape masks: 8-bit coverage, the node's colour.
    private var coverageProgram: GLuint = 0

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

    /// Where each per-node attribute sits in each program, looked up once.
    /// A rig mesh sprite carries twelve of them and there are dozens of
    /// sprites in a Switchling, so this is a few thousand `glGetAttribLocation`
    /// calls a frame if it is not kept.
    private var attributeLocations: [GLuint: [String: GLint]] = [:]

    public init(
        scene: SKScene,
        drawableSize: CGSize,
        pageLoader: @escaping (Int) -> (width: Int, height: Int, pixels: Data)?
    ) {
        self.scene = scene
        self.pageLoader = pageLoader
        cache = ResourceCache(device: device)
        view = SKView(bounds: CGRect(origin: .zero, size: drawableSize))
        cache.pageSource = pageLoader
        cache.pixelSource = SceneRenderer.pixels(of:)
        view.presentScene(scene)
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

        // The art is premultiplied, so this is the blend for it.
        glEnable(GLenum(GL_BLEND))
        glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA))
        glDisable(GLenum(GL_DEPTH_TEST))
        glClearColor(0, 0, 0, 1)
    }

    public func drawableSizeDidChange(to size: CGSize) {
        view.bounds = CGRect(origin: .zero, size: size)
        glViewport(0, 0, GLsizei(size.width), GLsizei(size.height))
        Log.info("drawable \(Int(size.width)) x \(Int(size.height))")
    }

    public func rendererWillStop() {
        cache.removeAll()
        glyphPages.removeAll()
        shapeMasks.removeAll()
        glyphSource.flush()
        if coverageProgram != 0 { device.deleteProgram(coverageProgram) }
        // A new context relinks every program, and GL reuses names, so a
        // location learned for an old one must not be trusted again.
        attributeLocations.removeAll()
        if defaultProgram != 0 { device.deleteProgram(defaultProgram) }
        glDeleteBuffers(1, &vbo)
        glDeleteBuffers(1, &ebo)
        glDeleteVertexArrays(1, &vao)
    }

    // MARK: Frames

    public func drawFrame(_ frame: Frame) {
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

        let list = view.tick(currentTime: frame.time, delta: frame.delta)
        let passes = batcher.passes(for: list)

        let projection = viewport.projection
        deviceScale = max(viewport.scale.x, viewport.scale.y)
        glyphSource.deviceScale = deviceScale

        glBindVertexArray(vao)
        draw(passes, projection: projection, time: Float(frame.time))
        glBindVertexArray(0)

        if !reportedFirstFrame {
            reportedFirstFrame = true
            Log.info("first frame: \(passes.reduce(0) { $0 + $1.quadCount }) quads, \(passes.count) passes")
        }

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

            case let .effect(_, _, _, _, contents):
                // Rendering to an offscreen target and compositing through
                // the effect's shader is not in yet; drawing the contents
                // straight through keeps the scene visible meanwhile, and
                // keeps the draw order honest.
                draw(contents, projection: projection, time: time)

            case let .crop(_, _, contents):
                // Likewise: the stencil pass is not in yet, so nothing is
                // clipped. Scenes that rely on it will overdraw.
                draw(contents, projection: projection, time: time)

            case let .label(label):
                draw(label, projection: projection)

            case let .shape(shape):
                draw(shape, projection: projection)
            }
        }
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

    private func draw(_ batch: SpriteBatcher.Batch, projection: [Float], time: Float) {
        guard !batch.indices.isEmpty else { return }

        let program: GLuint
        if let shader = batch.shader {
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

        if let shader = batch.shader {
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

        batch.vertices.withUnsafeBufferPointer { vertices in
            glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
            glBufferData(
                GLenum(GL_ARRAY_BUFFER),
                vertices.count * MemoryLayout<Float>.size,
                vertices.baseAddress, GLenum(GL_STREAM_DRAW)
            )
        }
        batch.indices.withUnsafeBufferPointer { indices in
            glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), ebo)
            glBufferData(
                GLenum(GL_ELEMENT_ARRAY_BUFFER),
                indices.count * MemoryLayout<UInt16>.size,
                indices.baseAddress, GLenum(GL_STREAM_DRAW)
            )
        }

        glDrawElements(
            GLenum(GL_TRIANGLES), GLsizei(batch.indices.count),
            GLenum(GL_UNSIGNED_SHORT), nil
        )

        if batch.blendMode == .replace { glEnable(GLenum(GL_BLEND)) }
    }

    // MARK: Touches

    /// Turns a touch into a point in the scene and hands it to the scene
    /// graph. The projection is this renderer's, so undoing it is too: the
    /// shell passes SDL's normalised window coordinates through untouched.
    public func receive(_ touch: TouchEvent) {
        let rect = viewport.visibleSceneRect
        // SDL counts y down from the top of the window; a scene counts it up.
        let point = CGPoint(
            x: rect.minX + touch.location.x * rect.width,
            y: rect.minY + (1 - touch.location.y) * rect.height
        )
        let phase: UITouchPhase
        switch touch.phase {
        case .began: phase = .began
        case .moved: phase = .moved
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        }
        scene.deliverTouch(phase: phase, at: point, identifier: touch.finger, timestamp: touch.time)
    }

    /// How scene points map onto the drawable, which is also what maps a
    /// touch back the other way.
    private var viewport: Viewport {
        Viewport(
            drawableSize: view.bounds.size,
            sceneSize: scene.size,
            scaleMode: scene.scaleMode,
            anchorPoint: scene.anchorPoint
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
            case .texture:
                continue
            }
        }
        if learned { attributeLocations[program] = locations }
    }

    /// Pixels for a texture the asset index does not back: one built from a
    /// file's bytes (a rig's page, which lives outside the packed art) or
    /// from a flat colour.
    private static func pixels(of texture: SKTexture) -> (width: Int, height: Int, pixels: Data)? {
        switch texture.source {
        case let .data(data):
            do {
                let image = try PNGDecoder.decode(data)
                return (image.width, image.height, image.pixels)
            } catch {
                Log.error("a texture's image would not decode: \(error)")
                return nil
            }
        case let .color(colour, size):
            let width = max(Int(size.width), 1), height = max(Int(size.height), 1)
            let pixel: [UInt8] = [colour.red, colour.green, colour.blue, colour.alpha]
                .map { UInt8(max(0, min(1, $0)) * 255) }
            return (width, height, Data(Array(repeating: pixel, count: width * height).joined()))
        case .named, .slice:
            return nil
        }
    }

    /// Stands in for "no texture": a sprite with only a colour still samples
    /// something, so one white pixel keeps the default shader uniform.
    private static let white = SKTexture(color: .white, size: CGSize(width: 1, height: 1))
}
