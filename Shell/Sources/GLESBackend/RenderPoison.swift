import CAndroidShell
import ShellCore

/// `debug.switchlings.poison` (debug builds only), to make a forgiving GPU
/// draw as Adreno's did, comma-separated:
/// - `targets`: every off-screen target's colour and stencil filled with
///   junk before its own clear, so a clear that leaves anything behind shows.
/// - `stream`: the frame's stream keeps its store rather than orphaning it,
///   as a driver that ignores the orphan would, so only the map's own
///   synchronisation keeps the frame from writing over the one in flight.
enum RenderPoison {
    #if DEBUG
    static let flags: Set<Substring> = {
        guard let value = DebugProperty.string("debug.switchlings.poison") else { return [] }
        let flags = Set(value.split(separator: ","))
        Log.info("poison: \(value)")
        return flags
    }()
    static let targets = flags.contains("targets")
    static let stream = flags.contains("stream")
    #else
    static let targets = false
    static let stream = false
    #endif

    /// Fills the bound target with junk, `targets` only.
    static func fillTarget() {
        guard targets else { return }
        glClearColor(1, 0, 1, 1)
        glClearStencil(0x5A)
        glStencilMask(0xFF)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT) | GLbitfield(GL_STENCIL_BUFFER_BIT))
        glClearStencil(0)
    }
}
