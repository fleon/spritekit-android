import CAndroidShell
import GLESRenderer
import SpriteKitShim

/// The GL state the renderer last set, so a draw sets only what changed.
///
/// A frame of the game is a few hundred draws, and before this each set the
/// program, the projection, the fragment map, `u_time`, every uniform, the
/// blend and its textures again, most of them to what they already were: on
/// a Mali driver every one of those is a call that validates state.
///
/// Programs keep their uniforms, so what a program holds is remembered per
/// program and survives frames; the rest is the context's. Everything is
/// forgotten with the context (`forgetAll`).
struct GLStateCache {
    /// What nothing has set yet: the next call sets it whatever it is.
    static let unknown = GLuint.max

    /// Texture units remembered: 0 is the sprite's own, the rest a shader's
    /// sampler uniforms.
    static let units = 16

    var program: GLuint = unknown
    var vertexArray: GLuint = unknown
    var activeUnit: Int = -1
    var blend: Blend?
    /// What each unit holds. Unit 0 is set by every draw (uploads land on
    /// it, as the active unit, and leave it unbound), so only the others
    /// are trusted across draws.
    var textures: [GLuint] = Array(repeating: unknown, count: units)
    private var programs: [GLuint: ProgramUniforms] = [:]

    struct Blend: Equatable {
        var enabled: Bool
        var equation: GLenum
        var source: GLenum
        var destination: GLenum
    }

    /// What a program's uniforms hold, as this renderer last set them. A
    /// class, so a draw looks it up once and writes it in place: a struct
    /// in the dictionary was copied, arrays and all, on every read.
    final class ProgramUniforms {
        var projection: [Float] = []
        var fragSpace: FragCoordSpace?
        var time: Float = .nan
        var samplerSet = false
        /// The shader whose uniforms the program holds, the revision of its
        /// uniform list and each uniform's generation then: while all three
        /// stand, its values are still in the program.
        var shader: SKShader?
        var shaderRevision = -1
        var generations: [UInt32] = []
        /// Where each of that shader's uniforms sits, in its order.
        var locations: [GLint] = []

        /// Whether `shader`'s uniforms are what the program holds already.
        func holds(_ shader: SKShader) -> Bool {
            guard self.shader === shader, shaderRevision == shader.revision else { return false }
            let uniforms = shader.uniforms
            guard generations.count == uniforms.count else { return false }
            for index in uniforms.indices where generations[index] != uniforms[index].generation {
                return false
            }
            return true
        }
    }

    /// What `program` holds, made the first time it's asked for.
    mutating func uniforms(of program: GLuint) -> ProgramUniforms {
        if let held = programs[program] { return held }
        let held = ProgramUniforms()
        programs[program] = held
        return held
    }

    mutating func forgetAll() {
        self = GLStateCache()
    }

    /// Texture bindings: at the start of a frame, and after anything that may
    /// have deleted a texture a unit held (GL then unbinds it, and a new
    /// texture may come back under its name).
    mutating func forgetTextures() {
        for unit in textures.indices { textures[unit] = Self.unknown }
    }
}
