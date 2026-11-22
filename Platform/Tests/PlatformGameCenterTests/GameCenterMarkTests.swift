import CoreGraphics
import Foundation
import Testing
@testable import PlatformGameCenter

@Suite("Game Center mark")
@MainActor
struct GameCenterMarkTests {
    @Test("Its four bubbles sit on the 24-unit grid, centred on it")
    func bubbles() {
        let bounds = GameCenterMark.drawnBounds
        #expect(GameCenterMark.bubbles.count == 4)
        #expect(bounds.minX > 0 && bounds.maxX < GameCenterMark.grid && bounds.minY > 0 && bounds.maxY < GameCenterMark.grid)
        #expect(abs(bounds.midX - GameCenterMark.centre.x) < 0.05 && abs(bounds.midY - GameCenterMark.centre.y) < 0.05)
        #expect(GameCenterMark.bubbles.allSatisfy { $0.colors.count == $0.locations.count })
    }

    @Test("Its sprite is the bubbles' bounds at the asked size, anchored on the grid's centre")
    func spriteSize() {
        let size = GameCenterMark.spriteSize(size: 48)
        #expect(abs(size.width - GameCenterMark.drawnBounds.width * 2) < 1e-9)
        #expect(abs(size.height - GameCenterMark.drawnBounds.height * 2) < 1e-9)
        let anchor = GameCenterMark.anchorPoint
        #expect(abs(anchor.x - 0.5) < 0.01 && abs(anchor.y - 0.5) < 0.01)
    }

    @Test("It draws each bubble in its colours, and nothing outside them")
    func draws() throws {
        let side = 96
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // UIKit's renderer: y down.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        let bounds = GameCenterMark.drawnBounds
        let rect = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side) * bounds.height / bounds.width)
        GameCenterMark.draw(in: context, rect: rect)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let scale = rect.width / bounds.width
        func pixel(_ point: CGPoint) -> (r: Int, g: Int, b: Int, a: Int) {
            let x = Int((point.x - bounds.minX) * scale), y = Int((point.y - bounds.minY) * scale)
            let i = (y * side + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
        }
        // The blue bubble alone, left of the others: blue, translucent.
        let blue = pixel(CGPoint(x: 3, y: 10))
        #expect(blue.b > blue.r && blue.b > 150 && (190 ... 215).contains(blue.a))
        // The yellow bubble alone, top right.
        let yellow = pixel(CGPoint(x: 20, y: 3))
        #expect(yellow.r > 150 && yellow.g > 130 && yellow.b < 60)
        // The pink bubble alone, bottom right.
        let pink = pixel(CGPoint(x: 21, y: 18))
        #expect(pink.r > 150 && pink.g < 120)
        // The corners between the bubbles stay clear.
        #expect(pixel(CGPoint(x: bounds.minX + 0.3, y: bounds.maxY - 0.3)).a == 0)
        #expect(pixel(CGPoint(x: bounds.maxX - 0.3, y: bounds.minY + 0.3)).a == 0)
    }

    @Test("The service's mark is Game Center's on Apple platforms and Play Games' on the shim")
    func serviceMark() {
        #if SPRITEKIT_SHIM
        #expect(GameServiceMark.nodeName == PlayGamesMark.nodeName)
        #else
        #expect(GameServiceMark.nodeName == GameCenterMark.nodeName)
        #endif
    }
}
