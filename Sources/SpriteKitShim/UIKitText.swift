#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

// A text field, for the one the game types into: the Level Designer's
// friend-code prompt (`CodePromptPopup`), which lays an invisible
// `UITextField` over its boxes and reads every edit through the delegate.
// On Android the keyboard is SDL's text input (`SDL_StartTextInput`), which
// the shell starts and stops as a field becomes and resigns first responder
// (`SystemServices.textInput`) and whose typing it hands back here
// (`UITextField.receive`): each insertion, backspace and Return reaches the
// delegate exactly as UIKit hands them over, so the game's own handling
// decides what the field holds.

/// UIKit's responder, for the keyboard notifications' names.
@MainActor
open class UIResponder {
    public static let keyboardWillChangeFrameNotification = Notification.Name("UIKeyboardWillChangeFrameNotification")
    public static let keyboardWillHideNotification = Notification.Name("UIKeyboardWillHideNotification")
    public static let keyboardWillShowNotification = Notification.Name("UIKeyboardWillShowNotification")
    public static let keyboardFrameEndUserInfoKey = "UIKeyboardFrameEndUserInfoKey"
}

public enum UITextAutocapitalizationType: Int, Sendable { case none, words, sentences, allCharacters }
public enum UITextAutocorrectionType: Int, Sendable { case `default`, no, yes }
public enum UITextSpellCheckingType: Int, Sendable { case `default`, no, yes }
public enum UITextSmartDashesType: Int, Sendable { case `default`, no, yes }
public enum UITextSmartQuotesType: Int, Sendable { case `default`, no, yes }
public enum UITextSmartInsertDeleteType: Int, Sendable { case `default`, no, yes }
public enum UIKeyboardType: Int, Sendable { case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad }
public enum UIReturnKeyType: Int, Sendable { case `default`, go, done, next, search, send }
public enum UITextBorderStyle: Int, Sendable { case none, line, bezel, roundedRect }

/// A position in a field's text: only its end is ever asked for.
public final class UITextPosition: Sendable {
    let offset: Int
    init(offset: Int) { self.offset = offset }
}

public final class UITextRange: Sendable {
    public let start: UITextPosition
    public let end: UITextPosition
    init(start: UITextPosition, end: UITextPosition) {
        self.start = start
        self.end = end
    }
}

@MainActor
public protocol UITextFieldDelegate: AnyObject {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool
    func textFieldShouldReturn(_ textField: UITextField) -> Bool
}

public extension UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool { true }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { true }
}

/// What the shell does for a text field: shows the keyboard over the field's
/// frame in view points, or hides it (nil); and offers the system's Paste at
/// a point in view points, as a long press on a field does on iOS.
public enum TextInput {
    nonisolated(unsafe) public static var show: (CGRect?) -> Void = { _ in }
    nonisolated(unsafe) public static var offerPaste: (CGPoint) -> Void = { _ in }
}

/// The soft keyboard, as UIKit tells a game about it: the shell hands over
/// its frame in view points as Android's insets move it (nil once it has
/// gone), and this posts what UIKit posts — `keyboardWillShow` the first
/// time, `keyboardWillChangeFrame` every time, `keyboardWillHide` as it goes,
/// each with the frame it ends at (`keyboardFrameEndUserInfoKey`, in the
/// screen's coordinates, which are the view's here). A keyboard on its way
/// out ends just below the view, as UIKit's does.
@MainActor
public enum SoftKeyboard {
    public private(set) static var frame: CGRect?

    public static func frameDidChange(_ new: CGRect?) {
        let center = NotificationCenter.default
        let old = frame
        guard new != old else { return }
        frame = new
        if let new {
            if old == nil { center.post(name: UIResponder.keyboardWillShowNotification, object: nil, userInfo: info(new)) }
            center.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: info(new))
        } else if let old {
            let gone = old.offsetBy(dx: 0, dy: old.height)
            center.post(name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: info(gone))
            center.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: info(gone))
        }
    }

    private static func info(_ frame: CGRect) -> [AnyHashable: Any] {
        [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)]
    }
}

public final class UITextField: UIView {
    public weak var delegate: UITextFieldDelegate?
    public var text: String? = ""
    public var autocapitalizationType = UITextAutocapitalizationType.sentences
    public var autocorrectionType = UITextAutocorrectionType.default
    public var spellCheckingType = UITextSpellCheckingType.default
    public var smartDashesType = UITextSmartDashesType.default
    public var smartQuotesType = UITextSmartQuotesType.default
    public var smartInsertDeleteType = UITextSmartInsertDeleteType.default
    public var keyboardType = UIKeyboardType.default
    public var returnKeyType = UIReturnKeyType.default
    public var textColor: UIColor?
    public var tintColor: UIColor?
    public var borderStyle = UITextBorderStyle.none
    public var selectedTextRange: UITextRange?

    /// The field taking typing now, if any.
    public private(set) static weak var firstResponder: UITextField?

    public convenience init() {
        self.init(frame: .zero)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.frame = frame
    }

    public var endOfDocument: UITextPosition { UITextPosition(offset: (text ?? "").utf16.count) }
    public var beginningOfDocument: UITextPosition { UITextPosition(offset: 0) }

    public func textRange(from: UITextPosition, to: UITextPosition) -> UITextRange? {
        UITextRange(start: from, end: to)
    }

    @discardableResult
    public func becomeFirstResponder() -> Bool {
        Self.firstResponder = self
        TextInput.show(frame)
        return true
    }

    @discardableResult
    public func resignFirstResponder() -> Bool {
        guard Self.firstResponder === self else { return false }
        Self.firstResponder = nil
        TextInput.show(nil)
        return true
    }

    public var isFirstResponder: Bool { Self.firstResponder === self }

    // MARK: - Touches

    /// UIKit's long press: held this long, no further than `pressSlop` from
    /// where it began.
    static let pressDuration: TimeInterval = 0.5
    static let pressSlop: CGFloat = 10
    private static var press: (start: CGPoint, generation: Int)?
    private static var pressGeneration = 0

    /// Whether a touch at `point` (view points) is the field's. On iOS the
    /// field is a view over the game's, so a touch on it never reaches the
    /// scene: the shell asks this first and hands such a touch here.
    public static func takesTouch(at point: CGPoint) -> Bool {
        firstResponder?.frame.contains(point) ?? false
    }

    /// A touch on the field taking typing, in view points. A tap brings the
    /// keyboard back if Android's back put it away; a long press offers the
    /// system's Paste.
    public static func touch(_ phase: UITouchPhase, at point: CGPoint) {
        guard let field = firstResponder else { return }
        switch phase {
        case .began:
            TextInput.show(field.frame)
            pressGeneration += 1
            let generation = pressGeneration
            press = (point, generation)
            DispatchQueue.main.asyncAfter(deadline: .now() + pressDuration) {
                MainActor.assumeIsolated {
                    guard let held = press, held.generation == generation, firstResponder != nil else { return }
                    press = nil
                    TextInput.offerPaste(held.start)
                }
            }
        case .moved:
            if let held = press, hypot(point.x - held.start.x, point.y - held.start.y) > pressSlop { press = nil }
        default:
            press = nil
        }
    }

    /// What the keyboard typed, as the shell reads it from SDL.
    public enum Typing: Equatable, Sendable {
        case insert(String)
        case backspace
        case `return`
    }

    /// Hands typing to the field taking it, through its delegate as UIKit
    /// does: an insertion at the end, a backspace over the last character.
    public static func receive(_ typing: Typing) {
        guard let field = firstResponder else { return }
        let current = field.text ?? ""
        let length = current.utf16.count
        switch typing {
        case let .insert(string):
            let typed = field.autocapitalizationType == .allCharacters ? string.uppercased() : string
            if field.delegate?.textField(field, shouldChangeCharactersIn: NSRange(location: length, length: 0), replacementString: typed) ?? true {
                field.text = current + typed
            }
        case .backspace:
            guard length > 0 else { return }
            if field.delegate?.textField(field, shouldChangeCharactersIn: NSRange(location: length - 1, length: 1), replacementString: "") ?? true {
                field.text = String(current.dropLast())
            }
        case .return:
            _ = field.delegate?.textFieldShouldReturn(field)
        }
    }
}

/// UIKit's coordinate spaces, as far as the code prompt names them: the
/// keyboard's frame comes in the screen's, which on Android is the view's.
@MainActor
public protocol UICoordinateSpace: AnyObject {}

extension UIView: UICoordinateSpace {}
extension UIScreen: UICoordinateSpace {}

public extension UIScreen {
    var coordinateSpace: UICoordinateSpace { self }
}

public extension UIView {
    func convert(_ rect: CGRect, from space: UICoordinateSpace) -> CGRect { rect }
}

// corelibs keeps a rect in an `NSValue` as `NSRect`, which is `CGRect` here.
public extension NSValue {
    convenience init(cgRect: CGRect) { self.init(rect: cgRect) }
    var cgRectValue: CGRect { rectValue }
}
#endif
