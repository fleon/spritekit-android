import Foundation
import Testing
@testable import GLESRenderer

@Suite("Shader preamble")
struct PreambleTests {
    @Test("Version comes first, and the precision the game's maths needs")
    func version() {
        let out = ShaderTranslator.fragmentShader(from: "void main() { gl_FragColor = vec4(1.0); }")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "#version 300 es")
        #expect(out.contains("precision highp float;"))
    }

    @Test("SpriteKit's built-in varyings and uniforms are declared")
    func builtins() {
        let out = ShaderTranslator.fragmentShader(from: "void main() { gl_FragColor = v_color_mix; }")
        #expect(out.contains("in vec2 v_tex_coord;"))
        #expect(out.contains("in vec4 v_color_mix;"))
        #expect(out.contains("uniform sampler2D u_texture;"))
        #expect(out.contains("uniform float u_time;"))
    }

    @Test("Uniforms from the node's SKUniform list are declared")
    func nodeUniforms() {
        let inputs = ShaderTranslator.Inputs(uniforms: [
            ("u_shape", "vec4"), ("u_crack", "vec4"), ("u_normal", "sampler2D"),
        ])
        let out = ShaderTranslator.fragmentShader(from: "void main() { gl_FragColor = u_shape; }", inputs: inputs)
        #expect(out.contains("uniform vec4 u_shape;"))
        #expect(out.contains("uniform vec4 u_crack;"))
        #expect(out.contains("uniform sampler2D u_normal;"))
    }

    @Test("A uniform the shader already declares is not declared twice")
    func noDuplicateDeclaration() {
        let source = """
        uniform vec4 u_shape;
        void main() { gl_FragColor = u_shape; }
        """
        let inputs = ShaderTranslator.Inputs(uniforms: [("u_shape", "vec4")])
        let out = ShaderTranslator.fragmentShader(from: source, inputs: inputs)
        let count = out.components(separatedBy: "uniform vec4 u_shape;").count - 1
        #expect(count == 1)
    }

    @Test("SKDefaultShading is defined only when the shader calls it")
    func defaultShading() {
        let using = ShaderTranslator.fragmentShader(from: "void main() { gl_FragColor = SKDefaultShading(); }")
        #expect(using.contains("vec4 SKDefaultShading() {"))

        let notUsing = ShaderTranslator.fragmentShader(from: "void main() { gl_FragColor = vec4(1.0); }")
        #expect(!notUsing.contains("vec4 SKDefaultShading() {"))
    }

    @Test("SKDefaultShading tints and fades as an unshaded sprite draws")
    func defaultShadingTintsAndFades() {
        // A Mac's SpriteKit: a white sprite tinted red (colorBlendFactor 1)
        // draws red through SKDefaultShading, and at alpha 0.5 half as bright,
        // nothing multiplied after the shader. A lit signpost's ink arrow and
        // a pressed plate's fading cap depend on it.
        let out = ShaderTranslator.fragmentShader(from: "void main() { gl_FragColor = SKDefaultShading(); }")
        #expect(out.contains("in float v_blend;"))
        #expect(out.contains("mix(texel.rgb, v_color_mix.rgb * texel.a, v_blend)"))
        #expect(out.contains("* v_color_mix.a;"))
        let declared = ShaderTranslator.fragmentShader(from: "varying float v_blend; void main() { gl_FragColor = SKDefaultShading() * v_blend; }")
        #expect(declared.components(separatedBy: "float v_blend;").count - 1 == 1)
    }
}

@Suite("Dialect rewriting")
struct RewriteTests {
    @Test("texture2D becomes texture")
    func textureCall() {
        let out = ShaderTranslator.fragmentShader(
            from: "void main() { gl_FragColor = texture2D(u_texture, v_tex_coord); }"
        )
        #expect(out.contains("texture(u_texture, v_tex_coord)"))
        #expect(!out.contains("texture2D(u_texture"))
    }

    @Test("gl_FragColor becomes a declared out")
    func fragColor() {
        let out = ShaderTranslator.fragmentShader(from: "void main() { gl_FragColor = vec4(1.0); }")
        #expect(out.contains("out vec4 sk_fragColor;"))
        #expect(out.contains("sk_fragColor = vec4(1.0);"))
        #expect(!out.contains("gl_FragColor"))
    }

    @Test("gl_FragCoord and discard are ES 3.0 already and left alone")
    func untouched() {
        let source = """
        void main() {
            if (gl_FragCoord.x < 0.5) { discard; }
            gl_FragColor = vec4(1.0);
        }
        """
        let out = ShaderTranslator.fragmentShader(from: source)
        #expect(out.contains("gl_FragCoord.x"))
        #expect(out.contains("discard;"))
    }

    @Test("Only whole identifiers are rewritten")
    func wordBoundaries() {
        // A helper whose name merely contains `texture2D` must survive.
        let source = """
        vec4 my_texture2D_helper(vec2 p) { return texture2D(u_texture, p); }
        void main() { gl_FragColor = my_texture2D_helper(v_tex_coord); }
        """
        let out = ShaderTranslator.fragmentShader(from: source)
        #expect(out.contains("my_texture2D_helper"))
        #expect(out.contains("return texture(u_texture, p);"))
    }

    /// Found on a device, not in review: the driver rejects it with a bare
    /// "ERROR: 0:14: 'sample' : syntax error" and says nothing about why.
    @Test("Words ES 3.0 reserved but ES 1.0 allowed are renamed")
    func reservedWords() {
        // Exactly what CrumbleNode composes when a world lights its cracks.
        let source = """
        void main() {
            vec4 sample = texture2D(u_normal, v_tex_coord);
            gl_FragColor = vec4(sample.rgb, 1.0);
        }
        """
        let out = ShaderTranslator.fragmentShader(from: source)
        #expect(out.contains("vec4 sample_ = texture(u_normal, v_tex_coord);"))
        #expect(out.contains("sample_.rgb"))
        // The bare word must be gone, or the driver rejects the whole shader.
        #expect(!out.contains(" sample "))
        #expect(!out.contains("sample."))
    }

    @Test("A reserved word inside a longer identifier is left alone")
    func reservedWordBoundaries() {
        let out = ShaderTranslator.fragmentShader(
            from: "void main() { gl_FragColor = vec4(sampleCount, resample, 0.0, 1.0); }"
        )
        #expect(out.contains("sampleCount"))
        #expect(out.contains("resample"))
        #expect(!out.contains("sampleCount_"))
    }

    @Test("Identifier replacement respects both edges")
    func replacementEdges() {
        let r = ShaderTranslator.replacingIdentifier("a", with: "b", in: "a ab ba a_b a")
        #expect(r == "b ab ba a_b b")
    }
}

@Suite("Real game shaders")
struct RealShaderTests {
    /// Verbatim from Source/Game/Components/Board/HedgeNode.swift — the light
    /// pillars. Helper functions, nested calls, early returns, `fract`.
    static let hedge = """
    float sq(float x) { return x * x; }

    float roundRect(vec2 p, float b, float r) {
        vec2 q = abs(p) - vec2(b - r);
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    vec2 around(float u, float b, float r) {
        float s = b - r;
        float side = 2.0 * s + 1.5707963 * r;
        float d = fract(u) * 4.0 * side;
        float q = floor(d / side);
        float t = d - q * side;
        vec2 l = t < 2.0 * s
            ? vec2(t - s, -b)
            : vec2(s + r * sin((t - 2.0 * s) / max(r, 0.0001)), -s - r * cos((t - 2.0 * s) / max(r, 0.0001)));
        if (q < 0.5) { return l; }
        if (q < 1.5) { return vec2(-l.y, l.x); }
        if (q < 2.5) { return -l; }
        return vec2(l.y, -l.x);
    }

    void main() {
        vec2 p = v_tex_coord - 0.5;
        float d = roundRect(p, 0.4, 0.1);
        float glow = smoothstep(0.02, 0.0, abs(d));
        vec4 color = texture2D(u_texture, v_tex_coord);
        gl_FragColor = vec4(color.rgb + glow, 1.0) * v_color_mix.a;
    }
    """

    @Test("A real shader keeps its helper functions and control flow")
    func hedgeShader() {
        let out = ShaderTranslator.fragmentShader(
            from: Self.hedge,
            inputs: ShaderTranslator.Inputs(uniforms: [("u_colour", "vec4")])
        )
        // Helpers survive untouched.
        #expect(out.contains("float sq(float x) { return x * x; }"))
        #expect(out.contains("float roundRect(vec2 p, float b, float r) {"))
        #expect(out.contains("vec2 around(float u, float b, float r) {"))
        // Control flow and built-in maths survive.
        #expect(out.contains("if (q < 2.5) { return -l; }"))
        #expect(out.contains("fract(u)"))
        #expect(out.contains("smoothstep(0.02, 0.0, abs(d))"))
        // The dialect is rewritten.
        #expect(out.contains("texture(u_texture, v_tex_coord)"))
        #expect(out.contains("sk_fragColor = vec4(color.rgb + glow, 1.0) * v_color_mix.a;"))
        #expect(!out.contains("gl_FragColor"))
        #expect(!out.contains("texture2D"))
    }

    /// The game composes shaders at run time: a world's light function is
    /// prepended and a line is swapped in by string replacement (see
    /// CrumbleNode.source(light:)). Translation must work on the result.
    @Test("A composed shader translates as a whole")
    func composed() {
        let lightFunction = """
        vec3 lit(vec3 base, float a, vec3 n) {
            return base * max(dot(n, vec3(0.0, 0.0, 1.0)), 0.2) * a;
        }
        """
        let body = """
        void main() {
            vec4 color = texture2D(u_texture, v_tex_coord);
            gl_FragColor = color * v_color_mix.a;
        }
        """
        let spliced = body.replacingOccurrences(
            of: "gl_FragColor = color * v_color_mix.a;",
            with: "{ vec4 sample = texture2D(u_normal, v_tex_coord); color.rgb = lit(color.rgb, color.a, sample.xyz); }\n    gl_FragColor = color * v_color_mix.a;"
        )
        let out = ShaderTranslator.fragmentShader(
            from: lightFunction + "\n" + spliced,
            inputs: ShaderTranslator.Inputs(uniforms: [("u_normal", "sampler2D")])
        )
        #expect(out.contains("vec3 lit(vec3 base, float a, vec3 n) {"))
        #expect(out.contains("uniform sampler2D u_normal;"))
        #expect(out.contains("texture(u_normal, v_tex_coord)"))
        #expect(!out.contains("texture2D"))
        #expect(!out.contains("gl_FragColor"))
    }
}

@Suite("Vertex shader")
struct VertexTests {
    @Test("The sprite vertex shader declares the standard inputs and varyings")
    func standard() {
        let out = ShaderTranslator.spriteVertexShader()
        #expect(out.hasPrefix("#version 300 es"))
        #expect(out.contains("in vec2 a_position;"))
        #expect(out.contains("out vec2 v_tex_coord;"))
        #expect(out.contains("out vec4 v_color_mix;"))
        #expect(out.contains("gl_Position = u_projection * vec4(a_position, 0.0, 1.0);"))
    }

    @Test("Per-node SKAttributes are passed through to the fragment stage")
    func attributes() {
        // RigMeshNode's triangle runs ride on an attribute like this.
        let out = ShaderTranslator.spriteVertexShader(attributes: [("a_run", "vec4")])
        #expect(out.contains("in vec4 a_a_run;"))
        #expect(out.contains("out vec4 a_run;"))
        #expect(out.contains("a_run = a_a_run;"))
    }
}
