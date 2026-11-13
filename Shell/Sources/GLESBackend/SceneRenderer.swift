import CAndroidShell
import Foundation
import GLESRenderer
import SpriteKitShim
import ShellCore

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

    /// Pixels for a packed page, by its index in `AssetIndex.pages`.
    private let pageLoader: (Int) -> (width: Int, height: Int, pixels: Data)?

    /// Set once the first frame has been drawn, so the log says it happened
    /// exactly once rather than every frame.
    private var reportedFirstFrame = false

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
        view.presentScene(scene)
    }

    // MARK: Lifecycle

    public func rendererDidStart(_ context: RenderContext) {
        Log.info("GLSL \(context.shadingLanguageVersion)")

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

        let viewport = Viewport(
            drawableSize: frame.size,
            sceneSize: scene.size,
            scaleMode: scene.scaleMode,
            anchorPoint: scene.anchorPoint
        )
        let projection = viewport.projection

        glBindVertexArray(vao)
        draw(passes, projection: projection, time: Float(frame.time))
        glBindVertexArray(0)

        if !reportedFirstFrame {
            reportedFirstFrame = true
            Log.info("first frame: \(passes.reduce(0) { $0 + $1.quadCount }) quads, \(passes.count) passes")
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

            case .label, .shape:
                // Text needs the glyph atlas wired up; shapes need a path
                // rasteriser. Both are carried through the draw list so the
                // order stays right once they arrive.
                break
            }
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

    /// Stands in for "no texture": a sprite with only a colour still samples
    /// something, so one white pixel keeps the default shader uniform.
    private static let white = SKTexture(color: .white, size: CGSize(width: 1, height: 1))
}
