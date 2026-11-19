import Foundation

/// Rewrites SpriteKit's GLSL into GLSL ES 3.0 for Android.
///
/// SpriteKit accepts a bare fragment body in GLSL ES 1.0 and supplies the
/// preamble itself: no `#version`, no precision qualifier, no declarations
/// for `v_tex_coord`, `v_color_mix`, `u_texture` or `u_time`, and uniforms
/// injected from the node's `SKUniform` list. GLSL ES 3.0 requires all of
/// that to be written out, and renames two built-ins.
///
/// Doing it here, at upload, rather than in a game's source files matters
/// for a second reason: a game may assemble shaders at run time, prepending
/// a function to a source, replacing parts of it, or splicing GLSL into the
/// middle of a string. There is often no literal to edit.
public enum ShaderTranslator {

    /// What the fragment shader needs declared for it.
    public struct Inputs {
        /// Uniform names with their GLSL types, from the node's SKUniform list.
        public var uniforms: [(name: String, type: String)]
        /// Per-node attribute names with their GLSL types, from SKAttribute.
        public var attributes: [(name: String, type: String)]

        public init(
            uniforms: [(name: String, type: String)] = [],
            attributes: [(name: String, type: String)] = []
        ) {
            self.uniforms = uniforms
            self.attributes = attributes
        }
    }

    /// The name `gl_FragColor` becomes. Leading underscores are reserved in
    /// GLSL, so this is a name the game's own shaders will not collide with.
    static let fragColor = "sk_fragColor"

    /// What `gl_FragCoord` becomes: a call, so a swizzle still reads
    /// (`sk_fragCoord().xy`) and nothing has to be hoisted into `main`.
    static let fragCoord = "sk_fragCoord"

    /// The uniform carrying the fragment-coordinate map, set per draw.
    public static let fragCoordUniform = "u_sk_frag"

    /// The two divergences between SpriteKit's fragment coordinate and
    /// GLES's, both fixed here rather than in every file that reads it.
    ///
    ///  - SpriteKit runs on Metal, where the coordinate counts **down from
    ///    the top left**; GLES counts up from the bottom left. A game may
    ///    depend on Metal's: a shader handed `(visible.minX, visible.maxY,
    ///    pixelsPerPoint, 0)` that recovers a scene point as `u_fragment.xy +
    ///    gl_FragCoord.xy * u_fragment.zw` only lands on it if y runs down,
    ///    and one writing `vec2(gl_FragCoord.x, -gl_FragCoord.y)` does so for
    ///    the same reason. Left alone, every such shader would be mirrored
    ///    top to bottom.
    ///  - It counts the pixels of the target being drawn into: an
    ///    `SKEffectNode`'s texture for what the node holds, the screen (or
    ///    an enclosing effect's texture) for the effect's own shader as it
    ///    composites. The renderer sets `u_sk_frag` from the bound target,
    ///    so one uniform covers both.
    ///
    /// ES 3.0 will not let a macro or a variable be named `gl_…`, so the
    /// identifier is rewritten to a function instead.
    private static let fragCoordFunction = """
    uniform vec4 \(fragCoordUniform);

    vec4 \(fragCoord)() {
        return vec4(
            \(fragCoordUniform).x + gl_FragCoord.x * \(fragCoordUniform).z,
            \(fragCoordUniform).y + gl_FragCoord.y * \(fragCoordUniform).w,
            gl_FragCoord.z,
            gl_FragCoord.w
        );
    }
    """

    /// SpriteKit's built-in varyings and uniforms, always available.
    private static let builtinVaryings = [
        ("v_tex_coord", "vec2"),
        ("v_color_mix", "vec4"),
    ]

    private static let builtinUniforms = [
        ("u_texture", "sampler2D"),
        ("u_time", "float"),
    ]

    /// Keywords GLSL ES 3.0 reserves that ES 1.0 did not, so a shader
    /// SpriteKit compiles happily is rejected by an ES 3.0 driver. Only the
    /// ones plausible as a variable name in this game's shaders are listed:
    /// renaming more would be noise, and a word nothing uses costs nothing
    /// to leave out.
    static let reservedInES3 = [
        "sample", "input", "output", "buffer", "shared", "common",
        "active", "patch", "resource", "filter", "partition",
        "coherent", "volatile", "restrict", "readonly", "writeonly",
        "precise", "flat", "smooth", "centroid",
    ]

    /// Translates a SpriteKit fragment shader body into a complete ES 3.0
    /// fragment shader.
    public static func fragmentShader(from source: String, inputs: Inputs = Inputs()) -> String {
        var body = source

        // texture2D/textureCube -> texture, but only as whole words, so an
        // identifier such as `my_texture2D_helper` is left alone.
        body = replacingIdentifier("texture2D", with: "texture", in: body)
        body = replacingIdentifier("texture2DLod", with: "textureLod", in: body)
        body = replacingIdentifier("textureCube", with: "texture", in: body)

        // gl_FragColor is not a thing in ES 3.0; it becomes a declared out.
        body = replacingIdentifier("gl_FragColor", with: fragColor, in: body)

        // gl_FragCoord means something different here than it does on Metal
        // — see `fragCoordFunction`. Rewriting it to a call keeps every
        // swizzle the game writes working unchanged.
        let readsFragCoord = usesIdentifier("gl_FragCoord", in: body)
        if readsFragCoord {
            body = replacingIdentifier("gl_FragCoord", with: "\(fragCoord)()", in: body)
        }

        // ES 1.0 varying/attribute spellings, in case a composed snippet uses
        // them. In a fragment shader both become `in`.
        body = replacingIdentifier("varying", with: "in", in: body)

        // Words ES 3.0 reserved that ES 1.0 let you use as identifiers. The
        // shaders really do use `sample` — `vec4 sample =
        // texture2D(u_normal, at)`, say — and the driver rejects it
        // with a bare "syntax error" that says nothing about why.
        for word in reservedInES3 where usesIdentifier(word, in: body) {
            body = replacingIdentifier(word, with: "\(word)_", in: body)
        }

        var lines: [String] = [
            "#version 300 es",
            "",
            // Shaders do maths on scene positions and time; medium precision
            // visibly steps anything that scrolls or animates with them.
            "precision highp float;",
            "precision highp sampler2D;",
            "",
        ]

        for (name, type) in builtinVaryings where !declares(name, in: body) {
            lines.append("in \(type) \(name);")
        }
        // A node's own attributes are constant across its sprite (SpriteKit
        // sets them per node, and the batcher never merges a sprite that
        // carries them), so they are uniforms of the fragment stage rather
        // than vertex attributes passed through as varyings. A mesh sprite's
        // twelve vec4s as varyings drop whole triangles on a Mali-G72, and
        // interpolating twelve constants per pixel was never free.
        for (name, type) in inputs.attributes where !declares(name, in: body) {
            lines.append("uniform \(type) \(name);")
        }
        lines.append("")

        for (name, type) in builtinUniforms where !declares(name, in: body) {
            lines.append("uniform \(type) \(name);")
        }
        for (name, type) in inputs.uniforms
        where !declares(name, in: body) && !builtinUniforms.contains(where: { $0.0 == name }) {
            lines.append("uniform \(type) \(name);")
        }
        lines.append("")

        lines.append("out vec4 \(fragColor);")
        lines.append("")

        if readsFragCoord {
            lines.append(fragCoordFunction)
            lines.append("")
        }

        // SpriteKit's helper: what the sprite would draw with no shader of its
        // own (`defaultFragmentShader`), its texture multiplied by its tint
        // (`v_color_mix`), as SpriteKit measures. Declared only when the
        // shader uses it.
        let usesDefaultShading = usesIdentifier("SKDefaultShading", in: body)
        if usesDefaultShading {
            lines.append("vec4 SKDefaultShading() {")
            lines.append("    return texture(u_texture, v_tex_coord) * v_color_mix;")
            lines.append("}")
            lines.append("")
        }

        lines.append(body)
        return lines.joined(separator: "\n")
    }

    /// The vertex shader every sprite quad uses. SpriteKit has no equivalent
    /// to translate — it owns its vertex stage — so this is the renderer's.
    public static func spriteVertexShader() -> String {
        [
            "#version 300 es",
            "",
            "precision highp float;",
            "",
            "in vec2 a_position;",
            "in vec2 a_tex_coord;",
            "in vec4 a_color_mix;",
            "in float a_blend;",
            "",
            "uniform mat4 u_projection;",
            "",
            "out vec2 v_tex_coord;",
            "out vec4 v_color_mix;",
            "out float v_blend;",
            "",
            "void main() {",
            "    v_tex_coord = a_tex_coord;",
            // SpriteKit's tint, as a device's measures (Tools/TintProbe):
            // the colour mixed from white by the blend factor, premultiplied
            // by the alpha, which carries the node's alpha and the colour's
            // own mixed in by the same factor (folded in by the batcher).
            // What a shader reads as `v_color_mix`, and what the texel is
            // multiplied by.
            "    v_color_mix = vec4(mix(vec3(1.0), a_color_mix.rgb, a_blend) * a_color_mix.a, a_color_mix.a);",
            "    v_blend = a_blend;",
            "    gl_Position = u_projection * vec4(a_position, 0.0, 1.0);",
            "}",
        ].joined(separator: "\n")
    }

    /// What a sprite with no shader of its own is drawn with.
    ///
    /// SpriteKit's own default, in the terms this layer carries: sample the
    /// node's texture, mix toward its colour by `colorBlendFactor`, and
    /// multiply through by the node's composited alpha. The art is
    /// premultiplied, so the tint is scaled by the sample's alpha — tinting
    /// a transparent pixel must leave it transparent, not paint it.
    ///
    /// Half precision for the colour maths (Mali runs `mediump` at about
    /// twice the rate), full for the texture coordinate: a big page's texel
    /// is finer than half floats step near 1, so a `mediump` coordinate
    /// would wobble the art.
    public static let defaultFragmentShader = """
    #version 300 es

    precision mediump float;

    in highp vec2 v_tex_coord;
    in vec4 v_color_mix;
    in float v_blend;

    uniform sampler2D u_texture;

    out vec4 \(fragColor);

    void main() {
        \(fragColor) = texture(u_texture, v_tex_coord) * v_color_mix;
    }
    """

    /// What a glyph or a rasterised shape mask is drawn with.
    ///
    /// Both are single-channel coverage, not colour: the glyph atlas hands
    /// out 8-bit pages and the path rasteriser makes 8-bit masks, so the
    /// texture says *how much* of the pixel is covered and the node says
    /// what colour to put there. The sprite shader cannot stand in — it
    /// samples rgba and would draw every glyph as a black box.
    ///
    /// The output is premultiplied, because that is the blend the rest of
    /// the renderer is set up for.
    public static let coverageFragmentShader = """
    #version 300 es

    precision mediump float;

    in vec2 v_tex_coord;
    in vec4 v_color_mix;
    in float v_blend;

    uniform sampler2D u_texture;

    out vec4 \(fragColor);

    void main() {
        \(fragColor) = v_color_mix * texture(u_texture, v_tex_coord).r;
    }
    """

    /// Colour glyphs (emoji) off an RGBA page: premultiplied, drawn as
    /// they are, at the label's opacity (the vertex colour's alpha).
    public static let colourGlyphFragmentShader = """
    #version 300 es

    precision mediump float;

    in vec2 v_tex_coord;
    in vec4 v_color_mix;
    in float v_blend;

    uniform sampler2D u_texture;

    out vec4 \(fragColor);

    void main() {
        \(fragColor) = texture(u_texture, v_tex_coord) * v_color_mix.a;
    }
    """

    /// What an `SKCropNode`'s mask is drawn with while the stencil is being
    /// written.
    ///
    /// Not the coverage shader above, although both are about a mask: that
    /// one reads an 8-bit page a glyph or a rasterised path was drawn into,
    /// and this one reads the mask node's own art, which is ordinary rgba.
    /// SpriteKit clips by that art's alpha, so a fragment the mask does not
    /// cover must leave the stencil alone rather than write it — hence the
    /// discard. Colour writes are off for this pass, so the output value
    /// never reaches the framebuffer; it is here only because ES 3.0 wants
    /// a fragment output declared.
    ///
    /// The mask's own shader, if it has one, is deliberately not run: a
    /// shader that moved alpha around would change the mask's shape, and
    /// nothing in this game masks with one. The renderer logs it if it ever
    /// meets one rather than silently clipping to the wrong shape.
    /// A composited crop (`CropCompositing`): its contents, drawn into a
    /// target of their own, times its mask's coverage, drawn into another.
    /// The mask is read four times, three quarters of a texel apart: a hard
    /// edge comes out as a ramp about 2.5 pixels wide, the average of the
    /// soft edge SpriteKit gives a shape mask (measured at 3x); its own
    /// per-pixel scatter, an offscreen mask resampled, is not matched.
    public static let cropCompositeFragmentShader = """
    #version 300 es

    precision mediump float;

    in highp vec2 v_tex_coord;
    in vec4 v_color_mix;
    in float v_blend;

    uniform sampler2D u_texture;
    uniform sampler2D u_mask;
    uniform highp vec2 u_mask_texel;

    out vec4 \(fragColor);

    void main() {
        highp vec2 d = u_mask_texel * 0.75;
        float mask = 0.25 * (
            texture(u_mask, v_tex_coord + vec2(-d.x, -d.y)).a +
            texture(u_mask, v_tex_coord + vec2(d.x, -d.y)).a +
            texture(u_mask, v_tex_coord + vec2(-d.x, d.y)).a +
            texture(u_mask, v_tex_coord + vec2(d.x, d.y)).a);
        \(fragColor) = texture(u_texture, v_tex_coord) * mask * v_color_mix.a;
    }
    """

    public static let maskFragmentShader = """
    #version 300 es

    precision mediump float;

    in highp vec2 v_tex_coord;
    in vec4 v_color_mix;
    in float v_blend;

    uniform sampler2D u_texture;

    out vec4 \(fragColor);

    void main() {
        float coverage = texture(u_texture, v_tex_coord).a * v_color_mix.a;
        if (coverage < 0.05) { discard; }
        \(fragColor) = vec4(1.0);
    }
    """

    /// What a shape mask (`SKShapeNode` as an `SKCropNode`'s mask, as the
    /// game's scroll areas clip with) is drawn with while the stencil is
    /// written: its rasterised coverage, which is single-channel like the
    /// coverage shader's, cut where the shape does not reach.
    /// A shape's fill or stroke with a texture (`SKShapeNode.fillTexture`,
    /// `strokeTexture`): the mask's coverage, the texture stretched over the
    /// path's bounds (`u_fill_map` takes the mask's 0…1 to the texture's),
    /// and the colour tinting it, as SpriteKit multiplies the two.
    public static let texturedCoverageFragmentShader = """
    #version 300 es

    precision mediump float;

    in highp vec2 v_tex_coord;
    in vec4 v_color_mix;
    in float v_blend;

    uniform sampler2D u_texture;
    uniform sampler2D u_fill;
    uniform highp vec4 u_fill_map;

    out vec4 \(fragColor);

    void main() {
        vec4 fill = texture(u_fill, u_fill_map.xy + v_tex_coord * u_fill_map.zw);
        \(fragColor) = fill * v_color_mix * texture(u_texture, v_tex_coord).r;
    }
    """

    public static let coverageMaskFragmentShader = """
    #version 300 es

    precision mediump float;

    in highp vec2 v_tex_coord;
    in vec4 v_color_mix;
    in float v_blend;

    uniform sampler2D u_texture;

    out vec4 \(fragColor);

    void main() {
        float coverage = texture(u_texture, v_tex_coord).r * v_color_mix.a;
        if (coverage < 0.5) { discard; }
        \(fragColor) = vec4(1.0);
    }
    """

    // MARK: Word-boundary text work
    //
    // Done by hand rather than with NSRegularExpression: this runs for every
    // shader at load, and corelibs-foundation's regex is markedly slower than
    // Darwin's. It also keeps the behaviour identical on both platforms.
    // Over UTF-8 bytes, not `Character`s: GLSL is ASCII, and breaking a
    // shader into graphemes for each of the thirty or so words checked took
    // tens of milliseconds a shader on a phone, on the frame thread. Any
    // byte past ASCII counts as part of a word, as a letter would.

    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    static func isWordByte(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "_"), 0x80...:
            return true
        default:
            return false
        }
    }

    /// Where `needle` stands as a whole identifier in `bytes`, in order.
    static func identifierOffsets(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> [Int] {
        guard let first = needle.first, needle.count <= bytes.count else { return [] }
        var found: [Int] = []
        var i = 0
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == first, (i == 0 || !isWordByte(bytes[i - 1])) {
                var matches = true
                for k in 1 ..< needle.count where bytes[i + k] != needle[k] {
                    matches = false
                    break
                }
                let after = i + needle.count
                if matches, after == bytes.count || !isWordByte(bytes[after]) {
                    found.append(i)
                    i = after
                    continue
                }
            }
            i += 1
        }
        return found
    }

    /// Replaces `needle` only where it stands as a whole identifier.
    static func replacingIdentifier(
        _ needle: String,
        with replacement: String,
        in source: String
    ) -> String {
        guard !needle.isEmpty else { return source }
        var source = source
        return source.withUTF8 { bytes in
            let offsets = identifierOffsets(Array(needle.utf8), in: bytes)
            guard !offsets.isEmpty else { return String(decoding: bytes, as: UTF8.self) }
            let width = needle.utf8.count
            var result: [UInt8] = []
            result.reserveCapacity(bytes.count + offsets.count * max(0, replacement.utf8.count - width))
            var from = 0
            for offset in offsets {
                result.append(contentsOf: bytes[from ..< offset])
                result.append(contentsOf: replacement.utf8)
                from = offset + width
            }
            result.append(contentsOf: bytes[from...])
            return String(decoding: result, as: UTF8.self)
        }
    }

    static func usesIdentifier(_ needle: String, in source: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var source = source
        return source.withUTF8 { !identifierOffsets(Array(needle.utf8), in: $0).isEmpty }
    }

    private static let declarationPrefixes = ["uniform ", "in ", "attribute ", "varying "].map { Array($0.utf8) }

    /// Whether the source already declares `name` itself, so the preamble
    /// does not declare it twice. A composed shader (a light function
    /// spliced in) may bring its own.
    static func declares(_ name: String, in source: String) -> Bool {
        guard !name.isEmpty else { return false }
        let needle = Array(name.utf8)
        var source = source
        return source.withUTF8 { bytes in
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
                var lead = start
                while lead < end, bytes[lead] == UInt8(ascii: " ") || bytes[lead] == UInt8(ascii: "\t") { lead += 1 }
                let line = UnsafeBufferPointer(rebasing: bytes[lead ..< end])
                if declarationPrefixes.contains(where: { line.starts(with: $0) }),
                   !identifierOffsets(needle, in: line).isEmpty {
                    return true
                }
                start = end + 1
            }
            return false
        }
    }
}
