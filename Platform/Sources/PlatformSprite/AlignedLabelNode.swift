import Foundation
import SpriteKitShim

/// A label whose font band stays aligned at its `position`, whatever is
/// done to it afterwards: `position` is the alignment point (the band's
/// middle for `.center`, its top or bottom for `.top` and `.bottom`), so
/// it can be set, read back or moved by actions at any time; the label
/// scales and turns about that point; and a change of font or size moves
/// the text to stay aligned, while a change of text never moves it.
/// `label(... .vAlign(.center))` makes one.
///
/// Its text draws in a child label set on its baseline, offset by the
/// font's metrics (`TextBand`) and SpriteKit's `baselinePadding`, so
/// SpriteKit's `.center`, `.top` and `.bottom`, which align the string's
/// ink, are never used:
/// `verticalAlignmentMode` here names the band's alignment, and `.baseline`
/// sets the baseline at `position`. The text's properties (`text`,
/// `fontName`, `fontSize`, `fontColor`, `color`, `colorBlendFactor`, …)
/// are the child's, and `frame` is the text's. An action that changes a
/// label's colour (`colorize`) doesn't reach the text: set `fontColor`.
public final class AlignedLabelNode: SKLabelNode {
    /// The child the text draws in, on its baseline.
    let textNode = SKLabelNode()
    private var alignment: SKLabelVerticalAlignmentMode = .center

    /// The band aligned at `position`; nil follows `Typography.textBand`,
    /// read whenever the font changes.
    public var band: TextBand? {
        didSet { realign() }
    }

    /// The band aligned `mode` at `position`.
    public init(_ mode: SKLabelVerticalAlignmentMode = .center, band: TextBand? = nil) {
        super.init()
        textNode.verticalAlignmentMode = .baseline
        addChild(textNode)
        alignment = mode
        self.band = band
        realign()
    }

    public override convenience init() {
        self.init(.center)
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// How the band is aligned at `position`, by the font's metrics.
    public override var verticalAlignmentMode: SKLabelVerticalAlignmentMode {
        get { alignment }
        set {
            alignment = newValue
            realign()
        }
    }

    public override var text: String? {
        get { textNode.text }
        set { textNode.text = newValue }
    }

    public override var attributedText: NSAttributedString? {
        get { textNode.attributedText }
        set { textNode.attributedText = newValue }
    }

    public override var fontName: String? {
        get { textNode.fontName }
        set {
            textNode.fontName = newValue
            realign()
        }
    }

    public override var fontSize: CGFloat {
        get { textNode.fontSize }
        set {
            textNode.fontSize = newValue
            realign()
        }
    }

    public override var fontColor: SKColor? {
        get { textNode.fontColor }
        set { textNode.fontColor = newValue }
    }

    public override var color: SKColor? {
        get { textNode.color }
        set { textNode.color = newValue }
    }

    public override var colorBlendFactor: CGFloat {
        get { textNode.colorBlendFactor }
        set { textNode.colorBlendFactor = newValue }
    }

    public override var blendMode: SKBlendMode {
        get { textNode.blendMode }
        set { textNode.blendMode = newValue }
    }

    public override var horizontalAlignmentMode: SKLabelHorizontalAlignmentMode {
        get { textNode.horizontalAlignmentMode }
        set { textNode.horizontalAlignmentMode = newValue }
    }

    public override var numberOfLines: Int {
        get { textNode.numberOfLines }
        set { textNode.numberOfLines = newValue }
    }

    public override var preferredMaxLayoutWidth: CGFloat {
        get { textNode.preferredMaxLayoutWidth }
        set { textNode.preferredMaxLayoutWidth = newValue }
    }

    #if SPRITEKIT_SHIM && canImport(Darwin)
    public override var lineBreakMode: Int {
        get { textNode.lineBreakMode }
        set { textNode.lineBreakMode = newValue }
    }
    #else
    public override var lineBreakMode: NSLineBreakMode {
        get { textNode.lineBreakMode }
        set { textNode.lineBreakMode = newValue }
    }
    #endif

    /// The text's frame, in the parent's space.
    public override var frame: CGRect {
        let transform = CGAffineTransform(translationX: position.x, y: position.y)
            .rotated(by: zRotation)
            .scaledBy(x: xScale, y: yScale)
        return textNode.frame.applying(transform)
    }

    /// Sets the text's baseline so the band sits `alignment` at the origin,
    /// the child taking off SpriteKit's `baselinePadding`.
    private func realign() {
        let metrics = FontBandMetrics(fontNamed: textNode.fontName, size: textNode.fontSize)
        textNode.position = pt(0, metrics.labelY(alignment, at: 0, band: band ?? Typography.textBand()) * textNode.yScale)
    }
}
