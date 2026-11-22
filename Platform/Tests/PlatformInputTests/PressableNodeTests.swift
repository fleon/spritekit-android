import Foundation
import PlatformCore
import SpriteKitShim
import Testing
@testable import PlatformInput

// MARK: The tracker

struct PressTrackerTests {
    @Test func firesOnlyWhenTheTouchLiftsOnTheControl() {
        var tracker = PressTracker()
        #expect(tracker.began(inside: true) == .init(pressed: true))
        #expect(tracker.moved(inside: false) == .init(pressed: false))
        #expect(tracker.moved(inside: false) == .init())
        #expect(tracker.moved(inside: true) == .init(pressed: true))
        #expect(tracker.ended(inside: true) == .init(pressed: false, fires: true))
        #expect(!tracker.isTracking && !tracker.isPressed)

        _ = tracker.began(inside: true)
        _ = tracker.moved(inside: false)
        #expect(tracker.ended(inside: false) == .init())
    }

    @Test func aTouchThatLandsOffTheControlIsNeverFollowed() {
        var tracker = PressTracker()
        #expect(tracker.began(inside: false) == .init())
        #expect(tracker.moved(inside: true) == .init())
        #expect(tracker.ended(inside: true) == .init())
    }

    @Test func cancellingLetsGoWithoutFiring() {
        var tracker = PressTracker()
        _ = tracker.began(inside: true)
        #expect(tracker.cancelled() == .init(pressed: false))
        #expect(tracker.ended(inside: true) == .init())
    }

    @Test func aTouchDownControlFiresAsTheTouchLands() {
        var tracker = PressTracker(trigger: .touchDown)
        #expect(tracker.began(inside: true) == .init(pressed: true, fires: true))
        #expect(tracker.ended(inside: true) == .init(pressed: false))
    }
}

struct PressTrackerLateBeganTests {
    @Test func anEndBeforeItsLandingCompletesTheTapAtOnce() {
        var tracker = PressTracker()
        #expect(tracker.ended(inside: true, at: 10) == .init())
        #expect(tracker.began(inside: true, at: 10.016) == .init(fires: true))
        #expect(!tracker.isTracking && !tracker.isPressed)
        // The next tap is an ordinary one.
        #expect(tracker.began(inside: true, at: 11) == .init(pressed: true))
        #expect(tracker.ended(inside: true, at: 11.1) == .init(pressed: false, fires: true))
    }

    @Test func anEarlyEndOffTheControlCompletesWithoutFiring() {
        var tracker = PressTracker()
        _ = tracker.ended(inside: false, at: 10)
        #expect(tracker.began(inside: true, at: 10.01) == .init())
        #expect(!tracker.isTracking)
    }

    @Test func aLandingLongAfterAnEarlyEndIsATouchOfItsOwn() {
        var tracker = PressTracker()
        _ = tracker.ended(inside: true, at: 10)
        #expect(tracker.began(inside: true, at: 11) == .init(pressed: true))
        #expect(tracker.isTracking)
    }

    @Test func theEndOfATouchThatLandedOffTheControlIsNotEarly() {
        var tracker = PressTracker()
        _ = tracker.began(inside: false, at: 10)
        _ = tracker.ended(inside: true, at: 10.1)
        #expect(tracker.began(inside: true, at: 10.15) == .init(pressed: true))
    }

    @Test func aTouchDownControlFiresForALateLanding() {
        var tracker = PressTracker(trigger: .touchDown)
        _ = tracker.ended(inside: false, at: 10)
        #expect(tracker.began(inside: true, at: 10.01) == .init(fires: true))
    }
}

// MARK: The node, through the shim's touches

/// A 40-point square control centred on its position.
private final class Square: PressableNode {
    var shown: [Bool] = []
    var sources: [PressSource] = []
    /// Each `showTap`'s `pressShown`.
    var tapsShown: [Bool] = []

    override init() {
        super.init()
        addChild(SKSpriteNode(color: .red, size: sz(40, 40)))
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showPressed(_ pressed: Bool) {
        shown.append(pressed)
        super.showPressed(pressed)
    }

    override func playFeedback(_ source: PressSource) {
        sources.append(source)
    }

    override func showTap(_ source: PressSource, pressShown: Bool) {
        tapsShown.append(pressShown)
        super.showTap(source, pressShown: pressShown)
    }
}

// Driven by the shim's `deliverTouch`: Apple has no way to make a touch.
#if SPRITEKIT_SHIM
@MainActor
struct PressableNodeTests {
    private func scene(with control: Square) -> SKScene {
        let scene = SKScene(size: sz(200, 200))
        control.position = pt(100, 100)
        scene.addChild(control)
        return scene
    }

    private func touch(_ scene: SKScene, _ phase: UITouchPhase, _ x: CGFloat, _ y: CGFloat, finger: Int = 0) {
        scene.deliverTouch(phase: phase, at: pt(x, y), identifier: finger, timestamp: 0)
    }

    @Test func aTapFiresOnceAsItLifts() {
        let control = Square()
        var taps = 0
        control.onTap = { taps += 1 }
        let scene = scene(with: control)
        touch(scene, .began, 105, 95)
        #expect(control.isPressed && taps == 0)
        touch(scene, .ended, 105, 95)
        #expect(taps == 1 && !control.isPressed)
        #expect(control.shown == [true, false])
        #expect(control.sources == [.touch(pt(5, -5))])
        #expect(control.tapsShown == [true])
        #expect(control.action(forKey: "pressable.flash") == nil)
    }

    @Test func strayingOffLetsGoAndComingBackPressesAgain() {
        let control = Square()
        var taps = 0
        control.onTap = { taps += 1 }
        let scene = scene(with: control)
        touch(scene, .began, 100, 100)
        touch(scene, .moved, 150, 100)
        #expect(!control.isPressed)
        touch(scene, .ended, 150, 100)
        #expect(taps == 0)

        touch(scene, .began, 100, 100)
        touch(scene, .moved, 150, 100)
        touch(scene, .moved, 110, 100)
        touch(scene, .ended, 110, 100)
        #expect(taps == 1)
        #expect(control.shown == [true, false, true, false, true, false])
    }

    @Test func theSlopKeepsANearMissOn() {
        let control = Square()
        control.touchSlop = 10
        var taps = 0
        control.onTap = { taps += 1 }
        let scene = scene(with: control)
        touch(scene, .began, 100, 100)
        // 28 points right: 8 past the edge, within the slop.
        touch(scene, .moved, 128, 100)
        #expect(control.isPressed)
        touch(scene, .ended, 128, 100)
        #expect(taps == 1)
    }

    @Test func aCancelledTouchNeverFires() {
        let control = Square()
        var taps = 0
        control.onTap = { taps += 1 }
        let scene = scene(with: control)
        touch(scene, .began, 100, 100)
        scene.cancelTouches(timestamp: 0)
        #expect(!control.isPressed && taps == 0)
    }

    @Test func aSecondFingerIsIgnored() {
        let control = Square()
        var taps = 0
        control.onTap = { taps += 1 }
        let scene = scene(with: control)
        touch(scene, .began, 100, 100, finger: 0)
        touch(scene, .began, 105, 100, finger: 1)
        touch(scene, .ended, 105, 100, finger: 1)
        #expect(taps == 0 && control.isPressed)
        touch(scene, .ended, 100, 100, finger: 0)
        #expect(taps == 1)
    }

    @Test func aTouchDownControlFiresAsTheTouchLands() {
        let control = Square()
        control.trigger = .touchDown
        var taps = 0
        control.onTap = { taps += 1 }
        let scene = scene(with: control)
        touch(scene, .began, 100, 100)
        #expect(taps == 1)
        touch(scene, .ended, 100, 100)
        #expect(taps == 1 && !control.isPressed)
    }

    @Test func aDisabledControlSwallowsTouchesAndTakesNoFocus() {
        let control = Square()
        var taps = 0
        control.onTap = { taps += 1 }
        let scene = scene(with: control)
        control.isEnabled = false
        #expect(control.alpha == PressableNode.configuration.disabledAlpha)
        #expect(scene.deliverTouch(phase: .began, at: pt(100, 100), timestamp: 0) === control)
        touch(scene, .ended, 100, 100)
        #expect(taps == 0 && control.shown.isEmpty)
        #expect(!control.canFocus)
        #expect(!control.activate())

        control.isEnabled = true
        #expect(control.alpha == 1)
        touch(scene, .began, 100, 100)
        control.isEnabled = false
        #expect(!control.isPressed)
        touch(scene, .ended, 100, 100)
        #expect(taps == 0)
    }

    @Test func focusShowsTheRingAndTheRemotePressesIt() {
        let control = Square()
        var taps = 0
        control.onTap = { taps += 1 }
        let ring = SKSpriteNode(color: .white, size: sz(44, 44))
        control.addChild(ring)
        control.focusRing = ring
        #expect(ring.alpha == 0)
        let view = SKView(frame: rect(200, 200))
        let scene = scene(with: control)
        view.presentScene(scene)

        let navigator = FocusNavigator(view: view)
        defer { navigator.stop() }
        navigator.refresh()
        #expect(control.isFocused)
        #expect(ring.action(forKey: "pressable.focus") != nil)
        #expect(navigator.select())
        #expect(taps == 1)
        #expect(control.sources == [.activation])
        #expect(control.tapsShown == [false])
        #expect(control.shown == [true])
        navigator.stop()
        #expect(!control.isFocused)
    }

    @Test func theHitFrameDefaultsToWhatItsChildrenDraw() {
        let control = Square()
        #expect(control.hitFrame == rect(-20, -20, 40, 40))
        #expect(control.focusFrame == control.hitFrame)
        #expect(PressableNode().hitFrame == .zero)
    }

    @Test func theDefaultPressShrinksTheNamedPart() {
        final class Knobbed: PressableNode {
            let knob = SKSpriteNode(color: .red, size: sz(20, 20))
            override init() {
                super.init()
                addChild(knob)
            }
            required init?(coder aDecoder: NSCoder) { fatalError() }
            override var pressScaleNode: SKNode { knob }
        }
        let control = Knobbed()
        control.pressBegan(at: .zero)
        #expect(control.knob.action(forKey: "pressable.press") != nil)
        #expect(control.action(forKey: "pressable.press") == nil)
    }

    @Test func aFlashLastsTheControlsDurationOrTheConfigurations() {
        let control = Square()
        control.flashPress()
        #expect(control.flashDuration == nil)
        #expect(control.action(forKey: "pressable.flash")?.duration == PressableNode.configuration.flashDuration)
        #expect(control.shown == [true])

        control.flashDuration = 0.5
        control.flashPress()
        #expect(control.action(forKey: "pressable.flash")?.duration == 0.5)
    }

    @Test func aSubclassFlashesItsOwnWay() {
        final class Flashing: PressableNode {
            var flashes = 0
            override init() {
                super.init()
                addChild(SKSpriteNode(color: .red, size: sz(40, 40)))
            }
            required init?(coder aDecoder: NSCoder) { fatalError() }
            override func flashPress() { flashes += 1 }
        }
        let control = Flashing()
        var taps = 0
        control.onTap = { taps += 1 }
        #expect(control.activate())
        #expect(control.flashes == 1 && taps == 1)
        #expect(control.action(forKey: "pressable.flash") == nil)
    }
}

#endif

// MARK: A scene that hands out touches itself

@MainActor
@Suite(.serialized)
struct SceneDispatchTests {
    @Test func aControlCanLeaveItsTouchesToTheScene() {
        let control = Square()
        #expect(control.isUserInteractionEnabled)
        control.handlesTouches = false
        #expect(!control.isUserInteractionEnabled)

        let saved = PressableNode.configuration
        defer { PressableNode.configuration = saved }
        PressableNode.configuration.handlesTouches = false
        let dispatched = Square()
        #expect(!dispatched.handlesTouches && !dispatched.isUserInteractionEnabled)
    }

    @Test func anEndDeliveredBeforeALateBeganStillTapsOnceAndLetsGo() {
        let control = Square()
        control.handlesTouches = false
        var taps = 0
        control.onTap = { taps += 1 }
        control.pressEnded(at: pt(0, 0))
        control.pressBegan(at: pt(0, 0))
        #expect(taps == 1)
        #expect(!control.isPressed)
        // No cancelPress needed: the next tap presses and fires as usual.
        control.pressBegan(at: pt(0, 0))
        #expect(control.isPressed)
        control.pressEnded(at: pt(0, 0))
        #expect(taps == 2 && !control.isPressed)
    }

    @Test func aLateCompletedTapStillShowsItsPress() {
        let control = Square()
        control.handlesTouches = false
        var taps = 0
        control.onTap = { taps += 1 }
        control.pressEnded(at: pt(0, 0))
        control.pressBegan(at: pt(0, 0))
        #expect(taps == 1)
        // Shown once, through the flash, which lets go after flashDuration.
        #expect(control.tapsShown == [false])
        #expect(control.shown == [true])
        #expect(control.action(forKey: "pressable.flash") != nil)
    }

    @Test func aLateTapOnATouchDownControlShowsItsPressToo() {
        let control = Square()
        control.handlesTouches = false
        control.trigger = .touchDown
        control.pressEnded(at: pt(0, 0))
        control.pressBegan(at: pt(0, 0))
        #expect(control.tapsShown == [false])
        #expect(control.shown == [true])
    }
}
