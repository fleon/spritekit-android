#if SPRITEKIT_SHIM
import Foundation

/// SpriteKit's off-screen renderer: a scene with no view, updated to a time
/// of the caller's choosing and drawn into a texture the caller hands it.
/// The game's one user is `SolutionFilm`, which films a level's solution on
/// a thread of its own.
///
/// It is the view's pipeline with the view taken out. `update(atTime:)`
/// does what `SKView.tick` does to a scene — its `update`, then its actions
/// by the time since the last update (none the first time, as SpriteKit) —
/// and `render(…)` flattens it into a `DrawList`, the same value a view
/// frame is, recorded into the command buffer. The GLES renderer draws it
/// once the buffer is committed (`MetalExecution`), through the same
/// batcher, programs and texture cache it draws the screen with.
open class SKRenderer {
    public let device: MTLDevice
    open var scene: SKScene?
    /// Always true in effect: the draw list orders the whole scene by z.
    open var ignoresSiblingOrder = false
    open var shouldCullNonVisibleNodes = true

    /// The time of the last update, which the next one counts from.
    private var lastUpdate: TimeInterval?
    /// What shaders take as `u_time` when this scene is drawn.
    private var time: TimeInterval = 0

    public init(device: MTLDevice) {
        self.device = device
    }

    open func update(atTime currentTime: TimeInterval) {
        guard let scene else { return }
        let delta = lastUpdate.map { max(0, currentTime - $0) } ?? 0
        lastUpdate = currentTime
        time = currentTime
        // On the film's own thread, as SpriteKit's renderer runs there.
        mainActorUnchecked {
            scene.update(currentTime)
            scene.tickActions(delta)
            scene.applyConstraints()
            scene.didApplyConstraints()
        }
    }

    /// Records drawing the scene as it stands into the pass's colour
    /// attachment, at `viewport` (in the attachment's pixels).
    open func render(withViewport viewport: CGRect, commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor) {
        guard let scene else { return }
        let color = renderPassDescriptor.colorAttachments[0]
        let (list, size, anchor, mode) = mainActorUnchecked { (DrawList(scene: scene), scene.size, scene.anchorPoint, scene.scaleMode) }
        commandBuffer.record(RecordedRenderPass(
            list: list,
            viewport: viewport,
            sceneSize: size,
            anchorPoint: anchor,
            scaleMode: mode,
            time: time,
            color: color?.texture,
            loadAction: color?.loadAction ?? .dontCare,
            clearColor: color?.clearColor ?? MTLClearColor(),
            hasStencil: renderPassDescriptor.stencilAttachment?.texture != nil
        ))
    }
}
#endif
