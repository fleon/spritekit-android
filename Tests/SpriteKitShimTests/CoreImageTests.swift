import Foundation
import Testing
@testable import SpriteKitShim

// Core Image's gradient and blur filters, pinned to Core Image's own output:
// each case was rendered with `CIContext.createCGImage` on a Mac (macOS 27.2)
// and read back as premultiplied RGBA8, and the numbers expected here are
// what it wrote.

private func pixel(_ image: RasterImage, _ x: Int, _ y: Int) -> [Int] {
    let base = (y * image.width + x) * 4
    return image.pixels[base..<base + 4].map(Int.init)
}

private func close(_ a: [Int], _ b: [Int], _ tolerance: Int = 1) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

private func linear(_ c0: CIColor, _ c1: CIColor, from p0: CGPoint = .zero, to p1: CGPoint = CGPoint(x: 100, y: 0)) -> CIImage {
    let filter = CIFilter(name: "CILinearGradient")!
    filter.setValue(c0, forKey: "inputColor0")
    filter.setValue(c1, forKey: "inputColor1")
    filter.setValue(CIVector(x: p0.x, y: p0.y), forKey: "inputPoint0")
    filter.setValue(CIVector(x: p1.x, y: p1.y), forKey: "inputPoint1")
    return filter.outputImage!
}

@Suite("Core Image: filters")
struct CoreImageTests {
    let context = CIContext()

    @Test("Filters by name, with Core Image's keys and defaults")
    func names() throws {
        #expect(CIFilter(name: "CINoSuchFilter") == nil)
        let gradient = try #require(CIFilter(name: "CILinearGradient"))
        #expect(gradient.inputKeys == ["inputPoint0", "inputPoint1", "inputColor0", "inputColor1"])
        #expect((gradient.value(forKey: "inputPoint1") as? CIVector)?.cgPointValue == CGPoint(x: 200, y: 200))
        let radial = try #require(CIFilter(name: "CIRadialGradient"))
        #expect(radial.inputKeys == ["inputCenter", "inputRadius0", "inputRadius1", "inputColor0", "inputColor1"])
        #expect(radial.value(forKey: "inputRadius1") as? CGFloat == 100)
        let blur = try #require(CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 4]))
        #expect(blur.inputKeys == ["inputImage", "inputRadius"])
        #expect(blur.gaussianBlurRadius == 4)
        #expect(CIFilter(name: "CIGaussianBlur")?.gaussianBlurRadius == 10)
        #expect(gradient.gaussianBlurRadius == nil)
        #expect(gradient.outputImage?.extent == CIImage.infiniteExtent)
    }

    @Test("Colours and vectors keep what they're given")
    func values() {
        let colour = CIColor(color: UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5))
        #expect(colour.red == 0.2 && colour.green == 0.4 && colour.blue == 0.6 && colour.alpha == 0.5)
        #expect(CIColor(red: 0.2, green: 0.4, blue: 0.6).alpha == 1)
        let vector = CIVector(x: 1, y: 2)
        #expect(vector.count == 2 && vector.x == 1 && vector.y == 2 && vector.z == 0 && vector.w == 0)
        #expect(vector.cgPointValue == CGPoint(x: 1, y: 2))
        #expect(CIVector(cgRect: CGRect(x: 1, y: 2, width: 3, height: 4)).cgRectValue == CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    @Test("A linear gradient mixes in linear light, sampled at pixel centres, held past its ends")
    func linearGradient() throws {
        let image = linear(.black, .white)
        let out = try #require(context.createCGImage(image, from: CGRect(x: 0, y: 0, width: 150, height: 1)))
        #expect(out.width == 150 && out.height == 1)
        let measured: [(Int, Int)] = [(0, 16), (1, 33), (10, 91), (25, 138), (50, 188), (75, 225), (99, 254), (100, 255), (149, 255)]
        for (x, grey) in measured {
            #expect(close(pixel(out, x, 0), [grey, grey, grey, 255]), "x \(x)")
        }

        let redToBlue = try #require(context.createCGImage(linear(.red, .blue), from: CGRect(x: 0, y: 0, width: 100, height: 1)))
        for (x, rgb) in [(0, [254, 0, 16]), (25, [224, 0, 138]), (50, [187, 0, 188]), (75, [136, 0, 225]), (99, [16, 0, 254])] {
            #expect(close(pixel(redToBlue, x, 0), rgb + [255]), "x \(x)")
        }
    }

    @Test("Colour fading to clear keeps its hue: premultiplied mixing")
    func premultiplied() throws {
        let fading = linear(CIColor(red: 1, green: 0, blue: 0, alpha: 1), CIColor(red: 0, green: 0, blue: 1, alpha: 0))
        let out = try #require(context.createCGImage(fading, from: CGRect(x: 0, y: 0, width: 100, height: 1)))
        for (x, v) in [(0, 254), (25, 190), (50, 126), (75, 62), (99, 1)] {
            #expect(close(pixel(out, x, 0), [v, 0, 0, v]), "x \(x)")
        }
        let half = linear(CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5), CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5))
        let flat = try #require(context.createCGImage(half, from: CGRect(x: 0, y: 0, width: 100, height: 1)))
        #expect(close(pixel(flat, 50, 0), [64, 64, 64, 128]))
    }

    @Test("A vertical gradient, row 0 the top; an offset or fractional rectangle")
    func rectangles() throws {
        let vertical = linear(.black, .white, from: CGPoint(x: 0, y: 10), to: .zero)
        let out = try #require(context.createCGImage(vertical, from: CGRect(x: 0, y: 0, width: 2, height: 10)))
        let measured = [63, 108, 137, 160, 179, 196, 211, 225, 237, 249]
        for (row, grey) in measured.enumerated() {
            #expect(close(pixel(out, 0, row), [grey, grey, grey, 255]), "row \(row)")
        }

        let offset = try #require(context.createCGImage(linear(.black, .white), from: CGRect(x: -50, y: 0, width: 100, height: 1)))
        for (x, grey) in [(0, 0), (49, 0), (50, 16), (75, 138), (99, 187)] {
            #expect(close(pixel(offset, x, 0), [grey, grey, grey, 255]), "x \(x)")
        }

        let fractional = try #require(context.createCGImage(linear(.black, .white), from: CGRect(x: 0.25, y: 0, width: 10.5, height: 1)))
        #expect(fractional.width == 11)
        for (x, expected) in [(0, [21, 21, 21, 255]), (1, [36, 36, 36, 255]), (9, [88, 88, 88, 255]), (10, [46, 46, 46, 128])] {
            #expect(close(pixel(fractional, x, 0), expected), "x \(x)")
        }

        let zero = linear(.red, .blue, from: .zero, to: .zero)
        let flat = try #require(context.createCGImage(zero, from: CGRect(x: -2, y: 0, width: 4, height: 1)))
        for x in 0..<4 { #expect(pixel(flat, x, 0) == [255, 0, 0, 255]) }
    }

    @Test("A radial gradient, inner colour inside the inner radius, outer outside")
    func radialGradient() throws {
        func radial(_ c0: CIColor, _ c1: CIColor, center: CGPoint, r0: CGFloat, r1: CGFloat) -> CIImage {
            let filter = CIFilter(name: "CIRadialGradient")!
            filter.setValue(c0, forKey: "inputColor0")
            filter.setValue(c1, forKey: "inputColor1")
            filter.setValue(CIVector(x: center.x, y: center.y), forKey: "inputCenter")
            filter.setValue(r0, forKey: "inputRadius0")
            filter.setValue(r1, forKey: "inputRadius1")
            return filter.outputImage!
        }
        // A glow: a colour at full alpha in the middle, clear at the edge.
        let glow = radial(CIColor(red: 1, green: 0.5, blue: 0.25, alpha: 1), CIColor(red: 1, green: 0.5, blue: 0.25, alpha: 0),
                          center: CGPoint(x: 10, y: 10), r0: 0, r1: 10)
        #expect(glow.extent == CGRect(x: 0, y: 0, width: 20, height: 20))
        let out = try #require(context.createCGImage(glow, from: CGRect(x: 0, y: 0, width: 20, height: 20)))
        let middle: [(Int, [Int])] = [(0, [12, 6, 3, 12]), (2, [63, 32, 16, 63]), (5, [140, 70, 35, 140]), (8, [215, 107, 54, 215]),
                                      (9, [237, 118, 59, 237]), (10, [237, 118, 59, 237]), (11, [215, 107, 54, 215]),
                                      (15, [114, 57, 29, 114]), (19, [12, 6, 3, 12])]
        for (x, expected) in middle {
            #expect(close(pixel(out, x, 10), expected), "x \(x), row 10")
            #expect(close(pixel(out, x, 9), expected), "x \(x), row 9")
        }
        for (x, expected) in [(0, [0, 0, 0, 0]), (8, [10, 5, 2, 10]), (9, [12, 6, 3, 12]), (15, [0, 0, 0, 0])] {
            #expect(close(pixel(out, x, 0), expected), "x \(x), row 0")
        }

        let ring = radial(.black, .white, center: CGPoint(x: 10, y: 10), r0: 4, r1: 8)
        #expect(ring.extent == CIImage.infiniteExtent)
        let ringOut = try #require(context.createCGImage(ring, from: CGRect(x: 0, y: 0, width: 20, height: 20)))
        for (x, grey) in [(10, 0), (13, 0), (14, 102), (15, 166), (16, 208), (17, 241), (18, 255), (19, 255)] {
            #expect(close(pixel(ringOut, x, 10), [grey, grey, grey, 255]), "x \(x)")
        }

        let inverted = radial(.red, .blue, center: .zero, r0: 8, r1: 4)
        let invertedOut = try #require(context.createCGImage(inverted, from: CGRect(x: 0, y: 0, width: 12, height: 1)))
        let redBlue = [(0, 255), (0, 255), (0, 255), (0, 255), (102, 240), (166, 206), (208, 164), (241, 98), (255, 0), (255, 0), (255, 0), (255, 0)]
        for (x, (r, b)) in redBlue.enumerated() {
            let p = pixel(invertedOut, x, 0)
            #expect(close([p[0], p[2]], [r, b]), "x \(x)")
        }
    }

    @Test("CIGaussianBlur's radius is applyingGaussianBlur's sigma")
    func blur() throws {
        var pixels = [UInt8](repeating: 0, count: 21 * 21 * 4)
        let middle = (10 * 21 + 10) * 4
        pixels[middle..<middle + 4] = [255, 255, 255, 255]
        let image = CIImage(cgImage: RasterImage(width: 21, height: 21, pixels: pixels))
        let filter = try #require(CIFilter(name: "CIGaussianBlur"))
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(2, forKey: kCIInputRadiusKey)
        let output = try #require(filter.outputImage)
        let viaFilter = try #require(context.createCGImage(output, from: image.extent))
        let viaSigma = try #require(context.createCGImage(image.applyingGaussianBlur(sigma: 2), from: image.extent))
        #expect(viaFilter == viaSigma)
        #expect(image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2]).extent == image.extent)
    }
}
