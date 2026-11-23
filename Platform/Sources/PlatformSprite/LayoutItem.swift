import Foundation
import SpriteKitShim

/// A small rect-based layout: rows and columns with gaps, grids, overlays
/// and insets, over the rects `SceneLayout` gives. Items state their own
/// size (design tokens, a label's measured text) rather than being measured,
/// and placing a tree sets each leaf's resting position once, on load and
/// when the layout changes, never per frame. It leaves running actions
/// alone.
///
/// Horizontal placement is by reading order: rows run from the leading
/// edge, grids fill from it, and `leading`/`trailing` alignment and insets
/// mirror in a right-to-left language (`LayoutDirection.current`). A subtree
/// that shows a physical direction keeps its own with `direction(_:)`.
///
///     LayoutItem.overlay([
///         .node(back, size: buttonSize).aligned(.leading, .top),
///         .node(settings, size: buttonSize).aligned(.trailing, .top),
///         .column([.label(title, height: titleHeight), .grid(coins, columns: 5, gap: sz(12))], gap: 24),
///     ])
///     .aligned(.fill, .fill)
///     .place(in: layout.contentRect)
///
/// No flexible sizing or wrapping: a row wider than the rect it's given
/// runs past it.
public struct LayoutItem {
    /// Where an item stands across the rect it's given. `fill` takes the
    /// rect's whole width.
    public enum HAlign: Equatable { case leading, center, trailing, fill }
    /// Where an item stands up and down the rect it's given. `fill` takes
    /// the rect's whole height.
    public enum VAlign: Equatable { case top, center, bottom, fill }

    /// Insets by reading order: `leading` is the left in a left-to-right
    /// language and the right in a right-to-left one.
    public struct Insets: Equatable {
        public var top: CGFloat
        public var leading: CGFloat
        public var bottom: CGFloat
        public var trailing: CGFloat

        public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
            self.top = top
            self.leading = leading
            self.bottom = bottom
            self.trailing = trailing
        }

        public init(_ all: CGFloat) {
            self.init(top: all, leading: all, bottom: all, trailing: all)
        }

        public init(horizontal: CGFloat = 0, vertical: CGFloat = 0) {
            self.init(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
        }

        /// `rect` inset, the leading and trailing insets on the sides
        /// `direction` puts them.
        public func inset(_ rect: CGRect, direction: LayoutDirection) -> CGRect {
            let left = direction.isRightToLeft ? trailing : leading
            let right = direction.isRightToLeft ? leading : trailing
            return CGRect(x: rect.minX + left, y: rect.minY + bottom, width: rect.width - left - right, height: rect.height - top - bottom)
        }
    }

    /// Where a leaf landed: its frame in the parent's space, and the
    /// direction it was laid out in.
    public struct Placement {
        public let frame: CGRect
        public let direction: LayoutDirection
    }

    private indirect enum Content {
        case leaf((Placement) -> Void)
        case row([LayoutItem], gap: CGFloat, align: VAlign)
        case column([LayoutItem], gap: CGFloat, align: HAlign)
        case grid([LayoutItem], columns: Int, gap: CGSize, cell: CGSize)
        case overlay([LayoutItem])
        case inset(LayoutItem, Insets)
    }

    private let content: Content
    /// The size the item asks for.
    public private(set) var size: CGSize
    private var hAlign: HAlign?
    private var vAlign: VAlign?
    private var fixedDirection: LayoutDirection?

    private init(_ content: Content, size: CGSize) {
        self.content = content
        self.size = size
    }

    // MARK: Leaves

    /// A leaf of `size`; `place` hears where it landed.
    public static func leaf(_ size: CGSize, place: @escaping (Placement) -> Void) -> LayoutItem {
        LayoutItem(.leaf(place), size: size)
    }

    /// Empty space of `size`.
    public static func space(_ size: CGSize) -> LayoutItem {
        leaf(size) { _ in }
    }

    /// Empty space `width` wide (in a row) or `height` tall (in a column).
    public static func space(width: CGFloat = 0, height: CGFloat = 0) -> LayoutItem {
        space(CGSize(width: width, height: height))
    }

    /// `node`, `size` big, its position the point `anchor` names in its
    /// frame ((0.5, 0.5) its middle, (0, 0) its bottom left: the node's own
    /// anchor, which doesn't mirror).
    public static func node(_ node: SKNode, size: CGSize, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> LayoutItem {
        leaf(size) { placement in
            let frame = placement.frame
            node.position = CGPoint(x: frame.minX + frame.width * anchor.x, y: frame.minY + frame.height * anchor.y)
        }
    }

    /// A one-line label as wide as its text and `height` tall (a line's
    /// band), positioned by its own horizontal alignment and centred up and
    /// down, as a label built with `.vAlign(.center)` keeps its band.
    public static func label(_ label: SKLabelNode, height: CGFloat) -> LayoutItem {
        let anchorX: CGFloat
        switch label.horizontalAlignmentMode {
        case .left: anchorX = 0
        case .right: anchorX = 1
        default: anchorX = 0.5
        }
        return node(label, size: CGSize(width: label.frame.width, height: height), anchor: CGPoint(x: anchorX, y: 0.5))
    }

    // MARK: Containers

    /// `items` side by side from the leading edge, `gap` apart, each
    /// standing `align` in the row's height unless it says otherwise.
    public static func row(_ items: [LayoutItem], gap: CGFloat = 0, align: VAlign = .center) -> LayoutItem {
        let width = items.reduce(0) { $0 + $1.size.width } + gap * CGFloat(max(items.count - 1, 0))
        let height = items.map(\.size.height).max() ?? 0
        return LayoutItem(.row(items, gap: gap, align: align), size: CGSize(width: width, height: height))
    }

    /// `items` top to bottom, `gap` apart, each standing `align` across the
    /// column's width unless it says otherwise.
    public static func column(_ items: [LayoutItem], gap: CGFloat = 0, align: HAlign = .center) -> LayoutItem {
        let width = items.map(\.size.width).max() ?? 0
        let height = items.reduce(0) { $0 + $1.size.height } + gap * CGFloat(max(items.count - 1, 0))
        return LayoutItem(.column(items, gap: gap, align: align), size: CGSize(width: width, height: height))
    }

    /// `items` in a grid `columns` wide, filled a row at a time from the
    /// leading edge, top row first. Every cell is `cell` big (the largest
    /// item's size by default), each item centred in its own unless it says
    /// otherwise.
    public static func grid(_ items: [LayoutItem], columns: Int, gap: CGSize = .zero, cell: CGSize? = nil) -> LayoutItem {
        let columns = max(columns, 1)
        let cell = cell ?? CGSize(width: items.map(\.size.width).max() ?? 0, height: items.map(\.size.height).max() ?? 0)
        let across = min(columns, items.count)
        let rows = (items.count + columns - 1) / columns
        let size = CGSize(
            width: cell.width * CGFloat(across) + gap.width * CGFloat(max(across - 1, 0)),
            height: cell.height * CGFloat(rows) + gap.height * CGFloat(max(rows - 1, 0))
        )
        return LayoutItem(.grid(items, columns: columns, gap: gap, cell: cell), size: size)
    }

    /// `items` over one another, each in the whole of the overlay's frame
    /// by its own alignment: as big as the biggest.
    public static func overlay(_ items: [LayoutItem]) -> LayoutItem {
        let size = CGSize(width: items.map(\.size.width).max() ?? 0, height: items.map(\.size.height).max() ?? 0)
        return LayoutItem(.overlay(items), size: size)
    }

    // MARK: Modifiers

    /// This item inside `insets`: as big as it is plus them, and laid out
    /// in its frame less them.
    public func inset(_ insets: Insets) -> LayoutItem {
        let size = CGSize(width: self.size.width + insets.leading + insets.trailing, height: self.size.height + insets.top + insets.bottom)
        return LayoutItem(.inset(self, insets), size: size)
    }

    /// This item standing `horizontal` and `vertical` in the rect it's given.
    public func aligned(_ horizontal: HAlign? = nil, _ vertical: VAlign? = nil) -> LayoutItem {
        var item = self
        if let horizontal { item.hAlign = horizontal }
        if let vertical { item.vAlign = vertical }
        return item
    }

    /// This item asking for `width` and `height` rather than its own size
    /// (what it holds lays out in that frame).
    public func sized(width: CGFloat? = nil, height: CGFloat? = nil) -> LayoutItem {
        var item = self
        item.size = CGSize(width: width ?? size.width, height: height ?? size.height)
        return item
    }

    /// This item and everything in it laid out in `direction` whatever the
    /// language: for what shows a physical direction (a board, a track).
    public func direction(_ direction: LayoutDirection) -> LayoutItem {
        var item = self
        item.fixedDirection = direction
        return item
    }

    // MARK: Placing

    /// Places the tree in `rect`: this item stands in it by its alignment
    /// (centred unless it says otherwise) and every leaf hears its frame.
    public func place(in rect: CGRect, direction: LayoutDirection = .current) {
        place(in: rect, direction: direction, hDefault: .center, vDefault: .center)
    }

    /// The frame this item takes in `rect`, standing by its alignment.
    public func frame(in rect: CGRect, direction: LayoutDirection = .current) -> CGRect {
        frame(in: rect, direction: fixedDirection ?? direction, h: hAlign ?? .center, v: vAlign ?? .center)
    }

    private func frame(in rect: CGRect, direction: LayoutDirection, h: HAlign, v: VAlign) -> CGRect {
        let width = h == .fill ? rect.width : size.width
        let height = v == .fill ? rect.height : size.height
        let x: CGFloat
        switch h {
        case .fill: x = rect.minX
        case .center: x = rect.midX - width / 2
        case .leading, .trailing:
            let edge: HorizontalEdge = h == .leading ? .leading : .trailing
            x = direction.side(edge) < 0 ? rect.minX : rect.maxX - width
        }
        let y: CGFloat
        switch v {
        case .fill, .bottom: y = rect.minY
        case .center: y = rect.midY - height / 2
        case .top: y = rect.maxY - height
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func place(in rect: CGRect, direction inherited: LayoutDirection, hDefault: HAlign, vDefault: VAlign) {
        let direction = fixedDirection ?? inherited
        let frame = frame(in: rect, direction: direction, h: hAlign ?? hDefault, v: vAlign ?? vDefault)
        let rightToLeft = direction.isRightToLeft
        switch content {
        case .leaf(let place):
            place(Placement(frame: frame, direction: direction))
        case let .row(items, gap, align):
            var cursor = rightToLeft ? frame.maxX : frame.minX
            for item in items {
                let width = item.size.width
                let x = rightToLeft ? cursor - width : cursor
                item.place(in: CGRect(x: x, y: frame.minY, width: width, height: frame.height), direction: direction, hDefault: .center, vDefault: align)
                cursor += (rightToLeft ? -1 : 1) * (width + gap)
            }
        case let .column(items, gap, align):
            var top = frame.maxY
            for item in items {
                let height = item.size.height
                item.place(in: CGRect(x: frame.minX, y: top - height, width: frame.width, height: height), direction: direction, hDefault: align, vDefault: .center)
                top -= height + gap
            }
        case let .grid(items, columns, gap, cell):
            for (index, item) in items.enumerated() {
                let column = CGFloat(index % columns)
                let row = CGFloat(index / columns)
                let offset = column * (cell.width + gap.width)
                let x = rightToLeft ? frame.maxX - offset - cell.width : frame.minX + offset
                let y = frame.maxY - row * (cell.height + gap.height) - cell.height
                item.place(in: CGRect(x: x, y: y, width: cell.width, height: cell.height), direction: direction, hDefault: .center, vDefault: .center)
            }
        case .overlay(let items):
            for item in items {
                item.place(in: frame, direction: direction, hDefault: .center, vDefault: .center)
            }
        case let .inset(item, insets):
            item.place(in: insets.inset(frame, direction: direction), direction: direction, hDefault: .fill, vDefault: .fill)
        }
    }
}
