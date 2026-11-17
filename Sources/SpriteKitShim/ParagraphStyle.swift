#if SPRITEKIT_SHIM && !canImport(Darwin)
import Foundation

// UIKit's paragraph style and the text enums that go with it, which corelibs
// Foundation leaves to the UI frameworks. Values measured on a Mac (iOS has
// the same): NSTextAlignment left 0, center 1, right 2, justified 3, natural 4;
// a new paragraph style is natural alignment, word wrapping, no spacing;
// SKLabelNode's lineBreakMode starts at byTruncatingTail.

public enum NSTextAlignment: Int, Sendable {
    case left = 0, center = 1, right = 2, justified = 3, natural = 4
}

public enum NSLineBreakMode: Int, Sendable {
    case byWordWrapping = 0, byCharWrapping, byClipping, byTruncatingHead, byTruncatingTail, byTruncatingMiddle
}

open class NSParagraphStyle: NSObject, @unchecked Sendable {
    open class var `default`: NSParagraphStyle { NSParagraphStyle() }

    public internal(set) var alignment: NSTextAlignment = .natural
    public internal(set) var lineBreakMode: NSLineBreakMode = .byWordWrapping
    public internal(set) var lineSpacing: CGFloat = 0
    public internal(set) var paragraphSpacing: CGFloat = 0
    public internal(set) var lineHeightMultiple: CGFloat = 0
    public internal(set) var minimumLineHeight: CGFloat = 0
    public internal(set) var maximumLineHeight: CGFloat = 0

    public override init() {}
}

open class NSMutableParagraphStyle: NSParagraphStyle, @unchecked Sendable {
    public override var alignment: NSTextAlignment {
        get { super.alignment }
        set { super.alignment = newValue }
    }

    public override var lineBreakMode: NSLineBreakMode {
        get { super.lineBreakMode }
        set { super.lineBreakMode = newValue }
    }

    public override var lineSpacing: CGFloat {
        get { super.lineSpacing }
        set { super.lineSpacing = newValue }
    }

    public override var paragraphSpacing: CGFloat {
        get { super.paragraphSpacing }
        set { super.paragraphSpacing = newValue }
    }

    public override var lineHeightMultiple: CGFloat {
        get { super.lineHeightMultiple }
        set { super.lineHeightMultiple = newValue }
    }

    public override var minimumLineHeight: CGFloat {
        get { super.minimumLineHeight }
        set { super.minimumLineHeight = newValue }
    }

    public override var maximumLineHeight: CGFloat {
        get { super.maximumLineHeight }
        set { super.maximumLineHeight = newValue }
    }
}

extension NSAttributedString.Key {
    /// UIKit's `NSParagraphStyleAttributeName`: an `NSParagraphStyle`.
    public static let paragraphStyle = NSAttributedString.Key("NSParagraphStyle")
    /// UIKit's `NSBaselineOffsetAttributeName`: points above the baseline.
    public static let baselineOffset = NSAttributedString.Key("NSBaselineOffset")
}
#endif
