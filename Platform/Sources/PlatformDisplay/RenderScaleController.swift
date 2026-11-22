#if !SPRITEKIT_SHIM
import PlatformCore
import QuartzCore
import SpriteKit
import UIKit

/// Sets the frame rate the game view draws at and the share of the screen's
/// pixels it draws, on Apple platforms: what the player picked, else Auto's
/// rate (60, never lower) and the scale `RenderScaleGovernor` chooses once
/// for the device (the rate by `preferredFramesPerSecond`, the scale by the
/// view's `contentScaleFactor`, and the drawable SpriteKit sizes by the
/// screen whatever that says). A frame is late only past the refreshes its
/// rate takes on this screen (`frameBudget`), so an Apple TV 4K on a 50 Hz
/// television keeps 4K.
///
/// It times frames as the view's delegate (handing every frame on to the
/// delegate before it), but only of scenes that measure
/// (`DisplaySettings.Configuration.isMeasured`), until the governor
/// chooses; the device keeps the choice (`DisplaySettings.noteAutoChosen`),
/// and it's drawn from the next scene change on (the game calls `apply` as
/// one starts), so nothing changes under a scene, and never changes again.
/// A setting the player picks applies at once, the scene laid out again
/// round it, and holds. A pinned scale stands, and a simulator draws every
/// pixel unless a setting's picked: the governor runs on none of them
/// (`DisplaySettings.choices`). The view's controller calls `fitDrawable`
/// after every layout and tells `DisplaySettings.screenMaximum` the screen's
/// fastest rate.
public final class RenderScaleController: NSObject, SKViewDelegate {
    public typealias Rung = RenderScaleGovernor.Rung

    /// The view's density changed under `scene` (a new scale, a fold onto
    /// another screen), after the scene has laid out again round it: for
    /// what's baked at a density (blurs, cached textures) to redo.
    public var onDensityChange: ((SKScene) -> Void)?

    private weak var view: SKView?
    private weak var forwarded: (any SKViewDelegate)?
    private var governor: RenderScaleGovernor
    private var governs: Bool
    private var lastFrame: TimeInterval?
    /// What the view draws at now.
    private var applied: Rung?
    private let observers = ObserverBag()

    /// Takes over as `view`'s delegate, handing every frame on to the one
    /// it had.
    public init(view: SKView) {
        self.view = view
        forwarded = view.delegate
        let choices = DisplaySettings.choices
        governor = RenderScaleGovernor(rate: choices.rate, scales: choices.scales, decided: choices.decided)
        governs = choices.governs
        super.init()
        view.delegate = self
        observers.add(DisplaySettings.observeChoices { [weak self] in self?.choicesDidChange() })
        applyRate(governor.rate)
    }

    public func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
        let renders = forwarded?.view?(view, shouldRenderAtTime: time) ?? true
        if renders, governs, !governor.isDecided, DisplaySettings.configuration.isMeasured(view.scene), let applied, let last = lastFrame, time > last,
           governor.add(frame: time - last, budget: DisplaySettings.frameBudget(rate: applied.rate, refresh: view.window?.screen.maximumFramesPerSecond)) {
            // Drawn from the next scene on (`apply`).
            DisplaySettings.noteAutoChosen(governor.rung)
        }
        lastFrame = renders ? time : lastFrame
        return renders
    }

    /// The scale the governor stands at, for the next scene: called as a
    /// scene change starts.
    public func apply() {
        governor.startScene()
        lastFrame = nil
        applyRate(governor.rate)
        guard let view, view.window != nil, governor.scale != applied?.scale else { return }
        applied?.scale = governor.scale
        view.contentScaleFactor = pixels(for: governor.scale)
        fitDrawable()
        DisplaySettings.running = governor.rung
    }

    /// What the governor stands at, under the scene on screen, laid out
    /// again round a new scale.
    private func applyNow() {
        let rescaled = applied?.scale != governor.scale
        applyRate(governor.rate)
        guard rescaled, let view, view.window != nil else { return }
        applied?.scale = governor.scale
        view.contentScaleFactor = pixels(for: governor.scale)
        fitDrawable()
        DisplaySettings.running = governor.rung
        if let scene = view.scene { densityChanged(in: scene) }
    }

    private func applyRate(_ rate: Int) {
        view?.preferredFramesPerSecond = rate
        let scale = applied?.scale ?? DisplaySettings.Graphics.highest.renderScale
        applied = Rung(rate: rate, scale: scale)
        DisplaySettings.running = Rung(rate: rate, scale: scale)
    }

    /// Holds the view's density to its scale of the screen's native pixels,
    /// and its drawable to that: SpriteKit sizes the drawable by the
    /// screen's pixels whatever `contentScaleFactor` says, so it's set here
    /// as the scale changes and again after every layout (a turn, a fold).
    /// UIKit starts the view at the screen's `scale`, which on a screen with
    /// fewer native pixels (an iPhone mini: 2.88 against 3) sized the
    /// drawable for more pixels than SpriteKit draws: the scene cropped at
    /// the right and bottom, black past it. A fold moves the window to
    /// another screen, so the density follows the screen it's on; when it
    /// changes the scene lays out again round it (`onDensityChange`).
    public func fitDrawable() {
        guard let view, let metal = view.layer as? CAMetalLayer else { return }
        if view.window != nil {
            let density = pixels(for: applied?.scale ?? governor.scale)
            if view.contentScaleFactor != density {
                view.contentScaleFactor = density
                if let scene = view.scene { densityChanged(in: scene) }
            }
        }
        let size = CGSize(width: view.bounds.width * view.contentScaleFactor, height: view.bounds.height * view.contentScaleFactor)
        if metal.drawableSize != size { metal.drawableSize = size }
    }

    private func densityChanged(in scene: SKScene) {
        scene.didChangeSize(scene.size)
        onDensityChange?(scene)
    }

    /// The player picked a rate or quality (or Auto), Low Power Mode came or
    /// went, or the screen's fastest rate is known: what's drawn now changes
    /// at once. Auto's scale is the one this device chose at the rate, else
    /// measured afresh at Highest; nothing that leaves the rate and scales
    /// as they were stops a measure under way.
    private func choicesDidChange() {
        let choices = DisplaySettings.choices
        guard choices.rate != governor.rate || choices.scales != governor.scales || choices.governs != governs else { return }
        governor = RenderScaleGovernor(rate: choices.rate, scales: choices.scales, decided: choices.decided)
        governs = choices.governs
        lastFrame = nil
        applyNow()
    }

    /// The view's pixels a point at `scale` of the screen's.
    private func pixels(for scale: Double) -> CGFloat {
        let screen = view?.window?.screen.nativeScale ?? 1
        return max(screen * CGFloat(scale), 1)
    }
}
#endif
