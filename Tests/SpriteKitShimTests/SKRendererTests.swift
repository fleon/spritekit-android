import Foundation
import Testing
@testable import SpriteKitShim

// The off-screen renderer and the Metal and CoreVideo it stands on, which a
// game films a scene through. Nothing here needs a GPU:
// a command buffer records `DrawList`s, and the executor these tests register
// stands in for the GLES renderer that draws them on a device.

/// Completes each buffer at once, filling every colour attachment that has
/// a pixel buffer with one value so a test can see the pass reached it.
private final class FillingExecutor: MetalCommandExecutor {
    var buffers: [MTLCommandBuffer] = []
    var asynchronous = false

    func enqueue(_ commandBuffer: MTLCommandBuffer) {
        buffers.append(commandBuffer)
        let work = {
            for pass in commandBuffer.passes {
                guard let pixels = pass.color?.pixelBuffer else { continue }
                pixels.baseAddress.initializeMemory(as: UInt8.self, repeating: 0x7F, count: pixels.byteCount)
            }
            commandBuffer.complete()
        }
        if asynchronous {
            Thread { Thread.sleep(forTimeInterval: 0.05); work() }.start()
        } else {
            work()
        }
    }
}

@Suite("SKRenderer", .serialized)
struct SKRendererTests {
    @Test("No device while nothing can draw")
    func noDevice() {
        MetalExecution.executor = nil
        #expect(MTLCreateSystemDefaultDevice() == nil)
    }

    @Test("Updates run the scene's actions by the time since the last update, none the first time")
    func updateClock() throws {
        let executor = FillingExecutor()
        MetalExecution.executor = executor
        defer { MetalExecution.executor = nil }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = SKRenderer(device: device)
        let scene = SKScene(size: CGSize(width: 100, height: 100))
        let node = SKNode()
        scene.addChild(node)
        renderer.scene = scene
        node.run(.moveBy(x: 100, y: 0, duration: 1))
        renderer.update(atTime: 1000)
        #expect(node.position.x == 0)
        renderer.update(atTime: 1000.5)
        #expect(abs(node.position.x - 50) < 0.001)
        renderer.update(atTime: 1001)
        #expect(abs(node.position.x - 100) < 0.001)
    }

    @Test("A render records the scene as it stood, and the pass's attachments")
    func recordsPass() throws {
        let executor = FillingExecutor()
        MetalExecution.executor = executor
        defer { MetalExecution.executor = nil }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = SKRenderer(device: device)
        let scene = SKScene(size: CGSize(width: 450, height: 800))
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        scene.scaleMode = .fill
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10))
        scene.addChild(sprite)
        renderer.scene = scene
        renderer.update(atTime: 5)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1080, 1920, kCVPixelFormatType_32BGRA, nil, &buffer)
        var cvTexture: CVMetalTexture?
        let textureCache = try #require(cache)
        let pixels = try #require(buffer)
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixels, nil, .bgra8Unorm, 1080, 1920, 0, &cvTexture)
        let made = try #require(cvTexture)
        let texture = try #require(CVMetalTextureGetTexture(made))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: 1080, height: 1920, mipmapped: false)
        pass.stencilAttachment.texture = device.makeTexture(descriptor: description)

        let commands = try #require(queue.makeCommandBuffer())
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: 1080, height: 1920), commandBuffer: commands, renderPassDescriptor: pass)
        // Moving the sprite after the render doesn't reach what was recorded.
        sprite.position = CGPoint(x: 99, y: 99)
        commands.commit()
        commands.waitUntilCompleted()

        #expect(commands.status == .completed)
        let recorded = try #require(commands.passes.first)
        #expect(recorded.sceneSize == scene.size)
        #expect(recorded.scaleMode == .fill)
        #expect(recorded.time == 5)
        #expect(recorded.hasStencil)
        #expect(recorded.clearColor.blue == 0.6)
        #expect(recorded.color?.pixelBuffer === buffer)
        guard case let .sprite(drawn)? = recorded.list.commands.first else {
            Issue.record("the sprite wasn't recorded")
            return
        }
        #expect(drawn.transform.tx == 0)
        #expect(pixels.baseAddress.load(as: UInt8.self) == 0x7F)
    }

    @Test("Waiting blocks until the executor completes the buffer on another thread")
    func waits() throws {
        let executor = FillingExecutor()
        executor.asynchronous = true
        MetalExecution.executor = executor
        defer { MetalExecution.executor = nil }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let commands = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        var handled = false
        commands.addCompletedHandler { _ in handled = true }
        commands.commit()
        #expect(commands.status == .committed)
        commands.waitUntilCompleted()
        #expect(commands.status == .completed)
        #expect(handled)
    }

    @Test("A commit with nothing to draw it fails rather than hanging")
    func noExecutor() throws {
        let executor = FillingExecutor()
        MetalExecution.executor = executor
        let device = try #require(MTLCreateSystemDefaultDevice())
        MetalExecution.executor = nil
        let commands = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.status == .error)
        #expect(commands.error != nil)
    }

    @Test("A pool hands out a buffer again once nobody holds it")
    func pool() {
        let pool = CVPixelBufferPool(width: 4, height: 2)
        var first: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &first)
        var second: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &second)
        #expect(first !== second)
        let reused = ObjectIdentifier(first!)
        first = nil
        var third: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &third)
        #expect(ObjectIdentifier(third!) == reused)
        #expect(CVPixelBufferGetBytesPerRow(third!) == 16)
    }
}

@Suite("A film's picture")
struct FilmPictureTests {
    @Test("A BGRA buffer read through CGContext comes out RGBA, as CoreGraphics reads it")
    func bgra() throws {
        let buffer = CVPixelBuffer(width: 2, height: 1)
        let bytes = buffer.baseAddress.assumingMemoryBound(to: UInt8.self)
        // Blue, then red, as BGRA.
        for (i, value) in [255, 0, 0, 255, 0, 0, 255, 255].enumerated() { bytes[i] = UInt8(value) }
        // A film's: premultiplied first (2), 32-bit little-endian (1 << 13).
        #expect(BitmapContext.isBGRA(bitmapInfo: 2 | 1 << 13))
        #expect(!BitmapContext.isBGRA(bitmapInfo: 1))
        let context = try #require(BitmapContext(wrapping: buffer.baseAddress, width: 2, height: 1, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)))
        context.storesBGRA = true
        let image = try #require(context.makeImage())
        #expect(image.pixels == [0, 0, 255, 255, 255, 0, 0, 255])
    }

    @Test("A picture's PNG is a valid PNG with the image's size, unpremultiplied")
    func png() throws {
        let image = RasterImage(width: 2, height: 2, pixels: [255, 0, 0, 255, 0, 128, 0, 128, 0, 0, 0, 0, 10, 20, 30, 255])
        let data = try #require(UIImage(cgImage: image).pngData())
        #expect(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        #expect(UIImage.pngSize(data) == CGSize(width: 2, height: 2))
        // Stored deflate: the raw rows follow the zlib header and a block header.
        let idat = try #require(data.range(of: Data("IDAT".utf8)))
        let rows = Array(data[idat.upperBound + 2 + 5 ..< idat.upperBound + 2 + 5 + 18])
        #expect(rows == [0, 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 0, 0, 0, 10, 20, 30, 255])
        #expect(PNGEncoder.crc32(Data("IEND".utf8)) == 0xAE42_6082)
    }

    @Test("Drawing an image draws into the renderer's context while it renders")
    func drawsIntoCurrent() {
        let red = UIImage(cgImage: RasterImage(width: 1, height: 1, pixels: [255, 0, 0, 255]))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { _ in
            red.draw(in: CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        #expect(drawn.cgImage?.pixels.prefix(4) == [255, 0, 0, 255])
    }
}
