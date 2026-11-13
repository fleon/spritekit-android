import CAndroidShell
import Foundation
import GLESRenderer
import SpriteKitShim
import ShellCore

/// `RenderDevice` over GLES 3.
///
/// Every GL call in the port lives in this module. `GLESRenderer` next door
/// stays free of them, which is why its batching, shader translation and
/// projection can be tested on a Mac with no context at all.
public final class GLDevice: RenderDevice {

    public init() {}

    // MARK: Textures

    public func createTexture(width: Int, height: Int, pixels: Data?) -> UInt32 {
        var name: GLuint = 0
        glGenTextures(1, &name)
        guard name != 0 else {
            Log.error("glGenTextures gave 0")
            return 0
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), name)

        // The art is premultiplied RGBA8 at 3x. Clamp, because an atlas page
        // holds many images and repeat would bleed one into the next; the
        // packer leaves a gutter for the same reason. Pages that must tile —
        // the backdrop grounds — are packed whole and get repeat below.
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)

        // Rows are tightly packed RGBA8, so one byte alignment rather than
        // the default four: a page whose width is not a multiple of four
        // would otherwise be read with a skew that grows down the image.
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)

        // GL_RGBA8 rather than GL_RGBA. ES 3.0 treats the unsized form as a
        // hint and the driver may pick its own channel order for it — on the
        // emulator's ANGLE/SwiftShader it hands back BGRA, which turns the
        // cream bricks cyan. The sized format is unambiguous.
        if let pixels, !pixels.isEmpty {
            // PNG stores the top row first; GL takes the first row as v = 0,
            // which is the *bottom* of the texture. The asset index already
            // reports textureRect with a bottom-left origin, so uploading the
            // rows as they come would flip the page a second time and every
            // quad would sample a mirrored patch of the atlas — plausible
            // looking art, from the wrong asset.
            let upright = Self.flippedVertically(pixels, width: width, height: height)
            upright.withUnsafeBytes { raw in
                glTexImage2D(
                    GLenum(GL_TEXTURE_2D), 0, GL_RGBA8,
                    GLsizei(width), GLsizei(height), 0,
                    GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), raw.baseAddress
                )
            }
        } else {
            glTexImage2D(
                GLenum(GL_TEXTURE_2D), 0, GL_RGBA8,
                GLsizei(width), GLsizei(height), 0,
                GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil
            )
        }

        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        return name
    }

    /// Reverses the row order of an RGBA8 image, turning PNG's top-row-first
    /// layout into the bottom-row-first one GL expects.
    static func flippedVertically(_ pixels: Data, width: Int, height: Int) -> Data {
        let stride = width * 4
        guard stride > 0, height > 0, pixels.count >= stride * height else { return pixels }
        var out = Data(count: stride * height)
        pixels.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { destination in
                guard let from = source.baseAddress, let to = destination.baseAddress else { return }
                for row in 0 ..< height {
                    memcpy(
                        to.advanced(by: (height - 1 - row) * stride),
                        from.advanced(by: row * stride),
                        stride
                    )
                }
            }
        }
        return out
    }

    /// Switches a page to repeat wrapping. The asset index marks the pages
    /// that hold one whole tiling image; an atlas page must never be set this
    /// way or its neighbours bleed in.
    public func setRepeats(_ name: UInt32) {
        glBindTexture(GLenum(GL_TEXTURE_2D), name)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_REPEAT)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_REPEAT)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
    }

    public func deleteTexture(_ name: UInt32) {
        var name = name
        glDeleteTextures(1, &name)
    }

    // MARK: Render targets

    /// Read once: GLES 3.0 guarantees 2048, and an effect node covering a
    /// tablet's whole backdrop wants more than that.
    public lazy var maximumTextureSide: Int = {
        var value: GLint = 0
        glGetIntegerv(GLenum(GL_MAX_TEXTURE_SIZE), &value)
        return value > 0 ? Int(value) : 2048
    }()

    public func createRenderTarget(width: Int, height: Int, stencil: Bool) -> RenderTargetHandle? {
        guard width > 0, height > 0 else { return nil }

        var texture: GLuint = 0
        glGenTextures(1, &texture)
        guard texture != 0 else {
            Log.error("render target: glGenTextures gave 0")
            return nil
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        // Linear, because an effect's texture is sampled by the composite and
        // by whatever the game points at it; clamped, because sampling past
        // the edge of an effect's own bounds must fade out rather than wrap
        // the far side in.
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glTexImage2D(
            GLenum(GL_TEXTURE_2D), 0, GL_RGBA8,
            GLsizei(width), GLsizei(height), 0,
            GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil
        )
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        var framebuffer: GLuint = 0
        glGenFramebuffers(1, &framebuffer)
        guard framebuffer != 0 else {
            Log.error("render target: glGenFramebuffers gave 0")
            glDeleteTextures(1, &texture)
            return nil
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(
            GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_TEXTURE_2D), texture, 0
        )

        var stencilBuffer: GLuint = 0
        if stencil {
            glGenRenderbuffers(1, &stencilBuffer)
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), stencilBuffer)
            // GL_STENCIL_INDEX8 is the only stencil-only format ES 3.0 makes
            // renderable; depth-stencil would cost a depth buffer the whole
            // port has no use for (the draw order is the z order).
            glRenderbufferStorage(
                GLenum(GL_RENDERBUFFER), GLenum(GL_STENCIL_INDEX8),
                GLsizei(width), GLsizei(height)
            )
            glFramebufferRenderbuffer(
                GLenum(GL_FRAMEBUFFER), GLenum(GL_STENCIL_ATTACHMENT),
                GLenum(GL_RENDERBUFFER), stencilBuffer
            )
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), 0)
        }

        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            Log.error("render target \(width)x\(height) incomplete: 0x\(String(status, radix: 16))")
            glDeleteFramebuffers(1, &framebuffer)
            glDeleteTextures(1, &texture)
            if stencilBuffer != 0 { glDeleteRenderbuffers(1, &stencilBuffer) }
            return nil
        }

        return RenderTargetHandle(
            framebuffer: framebuffer, texture: texture, stencil: stencilBuffer,
            width: width, height: height
        )
    }

    public func deleteRenderTarget(_ target: RenderTargetHandle) {
        var framebuffer = target.framebuffer
        var texture = target.texture
        var stencil = target.stencil
        if framebuffer != 0 { glDeleteFramebuffers(1, &framebuffer) }
        if texture != 0 { glDeleteTextures(1, &texture) }
        if stencil != 0 { glDeleteRenderbuffers(1, &stencil) }
    }

    // MARK: Programs

    public func createProgram(vertex: String, fragment: String) -> UInt32 {
        guard let vs = compile(vertex, kind: GLenum(GL_VERTEX_SHADER), label: "vertex") else { return 0 }
        defer { glDeleteShader(vs) }
        guard let fs = compile(fragment, kind: GLenum(GL_FRAGMENT_SHADER), label: "fragment") else { return 0 }
        defer { glDeleteShader(fs) }

        let program = glCreateProgram()
        guard program != 0 else {
            Log.error("glCreateProgram gave 0")
            return 0
        }
        glAttachShader(program, vs)
        glAttachShader(program, fs)

        // Fixed locations, so the batcher's vertex layout needs no lookup and
        // every program shares one vertex array setup.
        glBindAttribLocation(program, Attribute.position, "a_position")
        glBindAttribLocation(program, Attribute.texCoord, "a_tex_coord")
        glBindAttribLocation(program, Attribute.colorMix, "a_color_mix")
        glBindAttribLocation(program, Attribute.blend, "a_blend")

        glLinkProgram(program)

        var linked: GLint = 0
        glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linked)
        guard linked == GL_TRUE else {
            Log.error("link failed: \(programLog(program))")
            glDeleteProgram(program)
            return 0
        }
        return program
    }

    public func deleteProgram(_ name: UInt32) {
        glDeleteProgram(name)
    }

    private func compile(_ source: String, kind: GLenum, label: String) -> GLuint? {
        let shader = glCreateShader(kind)
        guard shader != 0 else {
            Log.error("glCreateShader(\(label)) gave 0")
            return nil
        }
        var bytes = Array(source.utf8CString)
        var length = GLint(bytes.count - 1)
        bytes.withUnsafeMutableBufferPointer { buffer in
            var pointer: UnsafePointer<GLchar>? = UnsafePointer(buffer.baseAddress)
            glShaderSource(shader, 1, &pointer, &length)
        }
        glCompileShader(shader)

        var compiled: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &compiled)
        guard compiled == GL_TRUE else {
            // The translated source goes to logcat with the error: the game's
            // shaders are assembled at run time, so the text that failed is
            // not in any file to go and read.
            Log.error("\(label) shader failed: \(shaderLog(shader))")
            Log.error("source was:\n\(source)")
            glDeleteShader(shader)
            return nil
        }
        return shader
    }

    private func shaderLog(_ shader: GLuint) -> String {
        var length: GLint = 0
        glGetShaderiv(shader, GLenum(GL_INFO_LOG_LENGTH), &length)
        guard length > 0 else { return "(no log)" }
        var buffer = [GLchar](repeating: 0, count: Int(length))
        glGetShaderInfoLog(shader, length, nil, &buffer)
        return String(cString: buffer)
    }

    private func programLog(_ program: GLuint) -> String {
        var length: GLint = 0
        glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), &length)
        guard length > 0 else { return "(no log)" }
        var buffer = [GLchar](repeating: 0, count: Int(length))
        glGetProgramInfoLog(program, length, nil, &buffer)
        return String(cString: buffer)
    }

    /// Fixed vertex attribute slots, matching the batcher's interleaving and
    /// the names `ShaderTranslator.spriteVertexShader` declares.
    public enum Attribute {
        public static let position: GLuint = 0
        public static let texCoord: GLuint = 1
        public static let colorMix: GLuint = 2
        public static let blend: GLuint = 3
    }
}
