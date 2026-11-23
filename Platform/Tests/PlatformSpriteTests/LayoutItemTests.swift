import Foundation
import Testing
import SpriteKitShim
@testable import PlatformSprite

/// The layout's arithmetic, in both directions: a right-to-left layout is
/// the left-to-right one mirrored about the rect's middle, except where a
/// subtree keeps its own direction.
struct LayoutItemTests {
    /// Leaves that write their frames into `frames` under their names.
    private final class Frames {
        var frames: [String: CGRect] = [:]

        func leaf(_ name: String, _ width: CGFloat, _ height: CGFloat) -> LayoutItem {
            .leaf(CGSize(width: width, height: height)) { [unowned self] in frames[name] = $0.frame }
        }
    }

    private static let screen = CGRect(x: -200, y: -400, width: 400, height: 800)

    private func mirrored(_ frame: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + rect.maxX - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
    }

    @Test func rowRunsFromTheLeadingEdge() {
        let f = Frames()
        let row = LayoutItem.row([f.leaf("a", 40, 20), f.leaf("b", 60, 40)], gap: 10, align: .top)
        #expect(row.size == CGSize(width: 110, height: 40))
        row.aligned(.leading, .top).place(in: Self.screen, direction: .leftToRight)
        #expect(f.frames["a"] == CGRect(x: -200, y: 380, width: 40, height: 20))
        #expect(f.frames["b"] == CGRect(x: -150, y: 360, width: 60, height: 40))
        row.aligned(.leading, .top).place(in: Self.screen, direction: .rightToLeft)
        #expect(f.frames["a"] == CGRect(x: 160, y: 380, width: 40, height: 20))
        #expect(f.frames["b"] == CGRect(x: 90, y: 360, width: 60, height: 40))
    }

    @Test func columnRunsTopDownAndAlignsByReadingOrder() {
        let f = Frames()
        let column = LayoutItem.column([f.leaf("a", 40, 20), f.leaf("b", 100, 30).aligned(.center)], gap: 5, align: .leading)
        #expect(column.size == CGSize(width: 100, height: 55))
        column.place(in: Self.screen, direction: .leftToRight)
        #expect(f.frames["a"] == CGRect(x: -50, y: 7.5, width: 40, height: 20))
        #expect(f.frames["b"] == CGRect(x: -50, y: -27.5, width: 100, height: 30))
        column.place(in: Self.screen, direction: .rightToLeft)
        #expect(f.frames["a"] == CGRect(x: 10, y: 7.5, width: 40, height: 20))
        #expect(f.frames["b"] == CGRect(x: -50, y: -27.5, width: 100, height: 30))
    }

    @Test func gridFillsRowsFromTheLeadingEdge() {
        let f = Frames()
        let items = (0 ..< 5).map { f.leaf("\($0)", 20, 20) }
        let grid = LayoutItem.grid(items, columns: 3, gap: CGSize(width: 10, height: 4), cell: CGSize(width: 30, height: 30))
        #expect(grid.size == CGSize(width: 110, height: 64))
        let rect = CGRect(x: 0, y: 0, width: 110, height: 64)
        grid.place(in: rect, direction: .leftToRight)
        #expect(f.frames["0"] == CGRect(x: 5, y: 39, width: 20, height: 20))
        #expect(f.frames["2"] == CGRect(x: 85, y: 39, width: 20, height: 20))
        #expect(f.frames["3"] == CGRect(x: 5, y: 5, width: 20, height: 20))
        let leftToRight = f.frames
        grid.place(in: rect, direction: .rightToLeft)
        for (name, frame) in leftToRight {
            #expect(f.frames[name] == mirrored(frame, in: rect), "\(name)")
        }
    }

    @Test func overlayCornersAndFill() {
        let f = Frames()
        let screen = LayoutItem.overlay([
            f.leaf("back", 44, 44).aligned(.leading, .top),
            f.leaf("settings", 44, 44).aligned(.trailing, .top),
            f.leaf("shade", 0, 0).aligned(.fill, .fill),
        ]).aligned(.fill, .fill)
        screen.place(in: Self.screen, direction: .leftToRight)
        #expect(f.frames["back"] == CGRect(x: -200, y: 356, width: 44, height: 44))
        #expect(f.frames["settings"] == CGRect(x: 156, y: 356, width: 44, height: 44))
        #expect(f.frames["shade"] == Self.screen)
        screen.place(in: Self.screen, direction: .rightToLeft)
        #expect(f.frames["back"] == CGRect(x: 156, y: 356, width: 44, height: 44))
        #expect(f.frames["settings"] == CGRect(x: -200, y: 356, width: 44, height: 44))
    }

    @Test func insetsByReadingOrder() {
        let f = Frames()
        let panel = LayoutItem.overlay([
            f.leaf("face", 0, 0).aligned(.fill, .fill),
            f.leaf("text", 100, 20).inset(LayoutItem.Insets(top: 10, leading: 30, bottom: 6, trailing: 12)),
        ])
        #expect(panel.size == CGSize(width: 142, height: 36))
        let rect = CGRect(x: 0, y: 0, width: 142, height: 36)
        panel.place(in: rect, direction: .leftToRight)
        #expect(f.frames["face"] == rect)
        #expect(f.frames["text"] == CGRect(x: 30, y: 6, width: 100, height: 20))
        panel.place(in: rect, direction: .rightToLeft)
        #expect(f.frames["text"] == CGRect(x: 12, y: 6, width: 100, height: 20))
    }

    @Test func aFixedDirectionKeepsItsSubtree() {
        let f = Frames()
        let row = LayoutItem.row([
            f.leaf("label", 50, 20),
            LayoutItem.row([f.leaf("first", 20, 20), f.leaf("second", 20, 20)], gap: 4).direction(.leftToRight),
        ], gap: 10)
        row.place(in: CGRect(x: 0, y: 0, width: 104, height: 20), direction: .rightToLeft)
        #expect(f.frames["label"] == CGRect(x: 54, y: 0, width: 50, height: 20))
        #expect(f.frames["first"] == CGRect(x: 0, y: 0, width: 20, height: 20))
        #expect(f.frames["second"] == CGRect(x: 24, y: 0, width: 20, height: 20))
    }

    @Test func aFixedDirectionItemStandsByItsParents() {
        let f = Frames()
        let column = LayoutItem.column([
            f.leaf("title", 40, 20),
            LayoutItem.row([f.leaf("start", 20, 10), f.leaf("end", 20, 10)]).direction(.leftToRight),
        ], align: .leading)
        column.aligned(.leading, .top).place(in: CGRect(x: 0, y: 0, width: 100, height: 30), direction: .rightToLeft)
        #expect(f.frames["title"] == CGRect(x: 60, y: 10, width: 40, height: 20))
        #expect(f.frames["start"] == CGRect(x: 60, y: 0, width: 20, height: 10))
        #expect(f.frames["end"] == CGRect(x: 80, y: 0, width: 20, height: 10))
        let board = f.leaf("board", 30, 30).direction(.leftToRight).aligned(.leading, .top)
        LayoutItem.overlay([board]).aligned(.fill, .fill).place(in: CGRect(x: 0, y: 0, width: 100, height: 100), direction: .rightToLeft)
        #expect(f.frames["board"] == CGRect(x: 70, y: 70, width: 30, height: 30))
        #expect(board.frame(in: CGRect(x: 0, y: 0, width: 100, height: 100), direction: .rightToLeft).minX == 70)
    }

    @Test func sizedHoldsItsContentInTheLargerFrame() {
        let f = Frames()
        let cell = f.leaf("dot", 10, 10).aligned(.trailing, .bottom)
        let item = LayoutItem.overlay([cell]).sized(width: 40, height: 30)
        #expect(item.size == CGSize(width: 40, height: 30))
        item.place(in: CGRect(x: 0, y: 0, width: 40, height: 30), direction: .leftToRight)
        #expect(f.frames["dot"] == CGRect(x: 30, y: 0, width: 10, height: 10))
    }

    @Test func nodesStandAtTheirAnchor() {
        let node = SKNode()
        let item = LayoutItem.node(node, size: CGSize(width: 40, height: 20), anchor: CGPoint(x: 0, y: 0.5))
        item.aligned(.leading, .bottom).place(in: CGRect(x: 0, y: 0, width: 100, height: 100), direction: .rightToLeft)
        #expect(node.position == CGPoint(x: 60, y: 10))
    }

    @Test func emptyContainersAskForNothing() {
        #expect(LayoutItem.row([], gap: 10).size == .zero)
        #expect(LayoutItem.column([], gap: 10).size == .zero)
        #expect(LayoutItem.grid([], columns: 3, gap: CGSize(width: 5, height: 5)).size == .zero)
    }
}

struct LayoutDirectionTests {
    @Test func languagesReadTheirWay() {
        for code in ["ar", "ar-SA", "he", "fa_IR", "ur", "ku-Arab"] {
            #expect(LayoutDirection.of(language: code) == .rightToLeft, "\(code)")
        }
        for code in ["en", "pt-BR", "zh-Hans", "th", "ku", "ja"] {
            #expect(LayoutDirection.of(language: code) == .leftToRight, "\(code)")
        }
    }

    @Test func edgesFallOnTheirSides() {
        #expect(LayoutDirection.leftToRight.side(.leading) == -1)
        #expect(LayoutDirection.rightToLeft.side(.leading) == 1)
        #expect(LayoutDirection.rightToLeft.side(.trailing) == -1)
        let rect = CGRect(x: -10, y: 0, width: 30, height: 5)
        #expect(LayoutDirection.rightToLeft.x(.leading, of: rect) == 20)
        #expect(LayoutDirection.leftToRight.labelAlignment(.leading) == .left)
        #expect(LayoutDirection.rightToLeft.labelAlignment(.leading) == .right)
        #expect(LayoutDirection.rightToLeft.mirrorScale == -1)
    }

    @Test func forcedWinsOverTheLanguage() {
        let resolve = LayoutDirection.resolve
        defer {
            LayoutDirection.resolve = resolve
            LayoutDirection.forced = nil
        }
        LayoutDirection.resolve = { .leftToRight }
        #expect(LayoutDirection.current == .leftToRight)
        LayoutDirection.forced = .rightToLeft
        #expect(LayoutDirection.current == .rightToLeft)
    }

    @Test func cornerButtonsByReadingOrder() {
        let phone = CGRect(x: -201, y: -437, width: 402, height: 874)
        let layout = SceneLayout(visibleRect: phone, safeRect: phone)
        #expect(layout.cornerButtonCenter(.leading, end: 1, size: 44, direction: .rightToLeft) == layout.cornerButtonCenter(side: 1, end: 1, size: 44))
        #expect(layout.cornerButtonCenter(.leading, end: 1, size: 44, direction: .leftToRight) == layout.cornerButtonCenter(side: -1, end: 1, size: 44))
        #expect(layout.edgeButtonX(.trailing, size: 44, clearsHousing: true, direction: .rightToLeft) == layout.edgeButtonX(side: -1, size: 44, clearsHousing: true))
    }
}
