import Foundation
import PlatformCore
import SpriteKitShim
import Testing
@testable import PlatformInput

// MARK: Focus geometry

struct FocusGeometryTests {
    /// Two rows of three 40-point buttons, 60 apart, in view coordinates.
    private let grid: [CGRect] = (0 ..< 6).map { rect(CGFloat($0 % 3) * 60, CGFloat($0 / 3) * 60, 40, 40) }

    @Test func movesToTheNeighbourThatWay() {
        let middle = grid[1]
        let others = grid.enumerated().filter { $0.offset != 1 }
        let frames = others.map(\.element)
        func target(_ direction: FocusNavigator.Direction) -> Int? {
            FocusNavigator.nearest(from: middle, among: frames, direction).map { others[$0].offset }
        }
        #expect(target(.left) == 0)
        #expect(target(.right) == 2)
        // Straight below beats the nearer-cornered ones beside it.
        #expect(target(.down) == 4)
        #expect(target(.up) == nil)
    }

    @Test func offsetControlsLoseToOnesInLine() {
        let from = rect(0, 0, 40, 40)
        // Farther ahead but in line, against nearer but well off to the side.
        let inLine = rect(140, 0, 40, 40)
        let aside = rect(60, 100, 40, 40)
        #expect(FocusNavigator.nearest(from: from, among: [aside, inLine], .right) == 1)
    }

    @Test func overlapsSettleByTheCentre() {
        let from = rect(0, 0, 100, 40)
        // Both overlap the way down; the one under the middle wins.
        let left = rect(-30, 50, 40, 40)
        let middle = rect(30, 50, 40, 40)
        #expect(FocusNavigator.nearest(from: from, among: [left, middle], .down) == 1)
    }

    @Test func centresWithinTheSlopAreNotThatWay() {
        let from = rect(0, 0, 40, 40)
        let level = rect(0.5, 80, 40, 40)
        #expect(FocusNavigator.nearest(from: from, among: [level], .right) == nil)
        #expect(FocusNavigator.nearest(from: from, among: [level], .down) == 0)
    }

    @Test func controlsReadInRowsThenAcross() {
        // Centres within the row tolerance share a row.
        let frames = [rect(100, 10, 20, 20), rect(0, 0, 20, 20), rect(50, 40, 20, 20), rect(0, 40, 20, 20)]
        let order = SceneControls.ordered(Array(frames.indices)) { frames[$0] }
        #expect(order == [1, 0, 3, 2])
    }
}

// MARK: Focus in a scene

private final class Button: SKSpriteNode, Focusable {
    var focused = false
    var presses = 0
    var canFocus = true
    var focusFrame: CGRect { rect(size).anchor(0.5) }
    func setFocused(_ focused: Bool) { self.focused = focused }
    func activate() -> Bool {
        presses += 1
        return true
    }
}

private final class Popup: SKNode, FocusOverlay, FocusDefaulting {
    var isDismissing = false
    weak var defaultFocus: SKNode?
}

struct FocusNavigatorTests {
    private func button(at position: CGPoint, in parent: SKNode) -> Button {
        let button = Button(color: .red, size: sz(40, 40))
        button.position = position
        parent.addChild(button)
        return button
    }

    @Test func focusMovesPressesAndComesBackFromAPopup() {
        let view = SKView(bounds: rect(200, 200))
        let scene = SKScene(size: sz(200, 200))
        // Scene coordinates: y up. Top row first in reading order.
        let topLeft = button(at: pt(50, 150), in: scene)
        let topRight = button(at: pt(150, 150), in: scene)
        let bottom = button(at: pt(50, 50), in: scene)
        let hidden = button(at: pt(150, 50), in: scene)
        hidden.hidesFocus = true
        view.presentScene(scene)

        let navigator = FocusNavigator(view: view)
        defer { navigator.stop() }
        #expect(FocusNavigator.isDriving)
        navigator.refresh()
        #expect(topLeft.focused)
        #expect(navigator.move(.right))
        #expect(topRight.focused && !topLeft.focused)
        // Nothing lies down from the top right but the hidden one.
        #expect(navigator.move(.down))
        #expect(bottom.focused)
        #expect(navigator.select())
        #expect(bottom.presses == 1)

        let popup = Popup()
        popup.zPosition = 10
        scene.addChild(popup)
        let first = button(at: pt(80, 100), in: popup)
        let second = button(at: pt(120, 100), in: popup)
        popup.defaultFocus = second
        navigator.refresh()
        #expect(second.focused && !bottom.focused && !first.focused)
        popup.isDismissing = true
        navigator.refresh()
        #expect(bottom.focused && !second.focused)

        navigator.stop()
        #expect(!bottom.focused)
        #expect(!FocusNavigator.isDriving)
    }

    @Test func aRequestedControlTakesFocus() {
        let view = SKView(bounds: rect(200, 200))
        let scene = SKScene(size: sz(200, 200))
        let first = button(at: pt(50, 100), in: scene)
        let second = button(at: pt(150, 100), in: scene)
        view.presentScene(scene)
        let navigator = FocusNavigator(view: view)
        defer { navigator.stop() }
        navigator.refresh()
        #expect(first.focused)
        FocusNavigator.request(second)
        navigator.refresh()
        #expect(second.focused)
    }

    @Test func theDriverShowsFocusOnlyOnceAGamepadAsks() {
        let view = SKView(bounds: rect(200, 200))
        let scene = SKScene(size: sz(200, 200))
        let first = button(at: pt(50, 100), in: scene)
        _ = button(at: pt(150, 100), in: scene)
        view.presentScene(scene)
        let driver = FocusDriver(view: view, alwaysOn: false)
        #expect(driver.navigator == nil)
        // The first press only brings focus up.
        #expect(driver.take() == nil)
        #expect(first.focused)
        #expect(driver.take() != nil)
        driver.release()
        #expect(driver.navigator == nil && !first.focused)
    }
}

// MARK: Focus rings

struct FocusRingTests {
    private enum ActionKey: String {
        case ring = "owner.ring"
    }

    @Test func aRingFadesUnderAnEnumKeysRawValue() {
        let ring = SKNode()
        ring.alpha = 0
        ring.fadeFocusRing(true, withKey: ActionKey.ring)
        #expect(ring.hasAction(forKey: "owner.ring"))

        ring.fadeFocusRing(false, withKey: ActionKey.ring)
        #expect(ring.hasAction(forKey: ActionKey.ring))
        ring.removeAction(forKey: "owner.ring")
        #expect(!ring.hasAction(forKey: ActionKey.ring))
    }
}

// MARK: Gamepads

/// A clock the tests move by hand.
private final class ManualClock {
    var now: TimeInterval = 0
    private var pending: [(at: TimeInterval, order: Int, work: () -> Void)] = []
    private var order = 0

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        order += 1
        pending.append((now + delay, order, work))
    }

    func advance(to time: TimeInterval) {
        while let next = pending.filter({ $0.at <= time + 1e-9 }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            pending.removeAll { $0.order == next.order }
            now = next.at
            next.work()
        }
        now = time
    }
}

struct GamepadTests {
    private func pads(_ clock: ManualClock) -> (GamepadPads, () -> [GamepadPads.Event]) {
        var events: [GamepadPads.Event] = []
        let pads = GamepadPads(configuration: GamepadConfiguration(), schedule: clock.schedule)
        pads.emit = { events.append($0) }
        return (pads, { defer { events = [] }; return events })
    }

    @Test func aHeldWayRepeatsAfterTheDelayThenAtTheInterval() {
        let clock = ManualClock()
        let (pads, taken) = pads(clock)
        pads.connect(1)
        pads.dpad(1, x: 0, y: -1)
        #expect(taken() == [.move(.down)])
        clock.advance(to: 0.44)
        #expect(taken().isEmpty)
        clock.advance(to: 0.45)
        #expect(taken() == [.move(.down)])
        clock.advance(to: 0.45 + 0.15 * 3)
        #expect(taken() == Array(repeating: .move(.down), count: 3))
        // Letting go stops it, and a new hold starts its own delay.
        pads.dpad(1, x: 0, y: 0)
        clock.advance(to: 2)
        #expect(taken().isEmpty)
        pads.dpad(1, x: 1, y: 0)
        clock.advance(to: 2.3)
        #expect(taken() == [.move(.right)])
    }

    @Test func onlyAWaysFirstMoveIsAHold() {
        let clock = ManualClock()
        let (pads, taken) = pads(clock)
        var holds: [FocusNavigator.Direction] = []
        pads.onHold = { holds.append($0) }
        pads.connect(1)
        pads.dpad(1, x: 0, y: 1)
        clock.advance(to: 1)
        #expect(taken().count == 5)
        #expect(holds == [.up])
    }

    @Test func theStickHasPressAndReleaseThresholds() {
        let clock = ManualClock()
        let (pads, taken) = pads(clock)
        pads.connect(1)
        pads.stick(1, x: 0.4, y: 0)
        #expect(taken().isEmpty)
        pads.stick(1, x: 0.6, y: 0.2)
        #expect(taken() == [.move(.right)])
        // Coming back below the press threshold but past the release one holds.
        pads.stick(1, x: 0.35, y: 0)
        clock.advance(to: 0.45)
        #expect(taken() == [.move(.right)])
        pads.stick(1, x: 0.2, y: 0)
        clock.advance(to: 2)
        #expect(taken().isEmpty)
    }

    @Test func anotherPadLettingGoLeavesTheHold() {
        let clock = ManualClock()
        let (pads, taken) = pads(clock)
        pads.connect(1)
        pads.connect(2)
        pads.dpad(1, x: -1, y: 0)
        pads.dpad(2, x: 0, y: 0)
        clock.advance(to: 0.45)
        #expect(taken() == [.move(.left), .move(.left)])
        // The holding pad going lets the way go.
        pads.disconnect(1)
        clock.advance(to: 2)
        #expect(taken().isEmpty)
    }

    @Test func buttonsPressOnceAsTheyGoDown() {
        let clock = ManualClock()
        let (pads, taken) = pads(clock)
        var gone = 0
        pads.onDisconnectAll = { gone += 1 }
        pads.connect(7)
        pads.button(7, .a, pressed: true)
        pads.button(7, .a, pressed: true)
        #expect(pads.holds(.a))
        pads.button(7, .a, pressed: false)
        pads.button(7, .menu, pressed: true)
        // An unknown pad's presses are ignored.
        pads.button(8, .b, pressed: true)
        #expect(taken() == [.press(.a), .press(.menu)])
        pads.disconnect(7)
        #expect(gone == 1 && !pads.isConnected)
    }

    @Test func theShellsEventsDriveTheInput() {
        let clock = ManualClock()
        let input = GamepadInput(schedule: clock.schedule)
        var actions: [GamepadInput.Action] = []
        var gone = false
        input.onAction = { actions.append($0) }
        input.onDisconnectAll = { gone = true }
        GamepadEvents.post(.connected(id: 3))
        #expect(GamepadInput.isConnected)
        GamepadEvents.post(.dpad(id: 3, x: 0, y: 1))
        GamepadEvents.post(.button(id: 3, .x, pressed: true))
        clock.advance(to: 0.45)
        #expect(actions == [.move(.up), .press(.x), .move(.up)])
        GamepadEvents.post(.disconnected(id: 3))
        #expect(gone && !GamepadInput.isConnected)
    }

    @Test func scriptsParseIntoSteps() {
        let steps = GamepadScript.parse(["down", "wait", "stickleft:2", "lb", "connect", "disconnect"], pressDuration: 0.1)
        #expect(steps == [
            .press(.dpad(.down), seconds: 0.1), nil, .press(.stick(.left), seconds: 2),
            .press(.button(.leftShoulder), seconds: 0.1), .connect, .disconnect,
        ])
    }

    @Test func aScriptPlaysOnAPretendPad() {
        let clock = ManualClock()
        let input = GamepadInput(schedule: clock.schedule)
        var actions: [GamepadInput.Action] = []
        input.onAction = { actions.append($0) }
        input.playScript(["right", "a", "disconnect"], delay: 1, interval: 1, pressDuration: 0.2)
        clock.advance(to: 3.5)
        #expect(actions == [.move(.right), .press(.a)])
        #expect(!GamepadInput.isConnected)
    }
}
