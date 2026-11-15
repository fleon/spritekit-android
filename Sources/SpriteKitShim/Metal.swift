#if SPRITEKIT_SHIM
import Foundation

// Metal, as far as `SKRenderer` needs it: a device, a queue, command buffers
// that are committed and waited on, a render pass with its attachments, and
// textures. The game reaches this surface in one place, `SolutionFilm`, which
// renders a share film off screen; its `import Metal` resolves to the module
// of that name in `Compat`, which re-exports these.
//
// Nothing here talks to a GPU. A command buffer records the passes
// `SKRenderer` encodes into it — each one a `DrawList`, a value, flattened on
// the thread that encoded it — and `commit()` hands it to whoever registered
// as `MetalExecution.executor`. On Android that is the GLES renderer, which
// draws the passes on the view's own thread and context at the top of its
// next frame and then completes the buffer. `waitUntilCompleted()` blocks
// until it has.

/// Who draws committed command buffers. The GLES renderer registers itself
/// as it starts; with none registered there is no device, as on a machine
/// with no GPU.
public protocol MetalCommandExecutor: AnyObject {
    /// Takes a committed buffer. It must call `complete(error:)` on it once,
    /// from any thread, when its passes have been drawn (or have failed).
    func enqueue(_ commandBuffer: MTLCommandBuffer)
}

public enum MetalExecution {
    public nonisolated(unsafe) static weak var executor: MetalCommandExecutor?
}

public struct MTLClearColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init() { self.init(red: 0, green: 0, blue: 0, alpha: 1) }
}

public enum MTLPixelFormat: Sendable {
    case invalid
    case bgra8Unorm
    case rgba8Unorm
    case depth32Float_stencil8
    case stencil8
}

public struct MTLTextureUsage: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let shaderRead = MTLTextureUsage(rawValue: 1 << 0)
    public static let shaderWrite = MTLTextureUsage(rawValue: 1 << 1)
    public static let renderTarget = MTLTextureUsage(rawValue: 1 << 2)
}

public enum MTLStorageMode: Sendable {
    case shared, managed, `private`, memoryless
}

public enum MTLLoadAction: Sendable {
    case dontCare, load, clear
}

public enum MTLStoreAction: Sendable {
    case dontCare, store, multisampleResolve
}

public final class MTLTextureDescriptor {
    public var pixelFormat: MTLPixelFormat = .rgba8Unorm
    public var width = 1
    public var height = 1
    public var mipmapLevelCount = 1
    public var usage: MTLTextureUsage = .shaderRead
    public var storageMode: MTLStorageMode = .shared

    public init() {}

    public class func texture2DDescriptor(pixelFormat: MTLPixelFormat, width: Int, height: Int, mipmapped: Bool) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.mipmapLevelCount = mipmapped ? Int(log2(Double(max(width, height)))) + 1 : 1
        return descriptor
    }
}

/// A texture: its size and format, and, when it was made over a pixel
/// buffer (`CVMetalTextureCacheCreateTextureFromImage`), the buffer a render
/// into it lands in. One made from a descriptor alone (a depth and stencil
/// attachment) has no pixels anyone reads; the executor brings its own.
public final class MTLTexture: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: MTLPixelFormat
    public let usage: MTLTextureUsage
    /// Where a render into it is written, if anywhere.
    public let pixelBuffer: CVPixelBuffer?

    init(width: Int, height: Int, pixelFormat: MTLPixelFormat, usage: MTLTextureUsage, pixelBuffer: CVPixelBuffer?) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.usage = usage
        self.pixelBuffer = pixelBuffer
    }
}

public final class MTLDevice: @unchecked Sendable {
    public let name = "GLES"

    init() {}

    public func makeCommandQueue() -> MTLCommandQueue? {
        MTLCommandQueue(device: self)
    }

    public func makeTexture(descriptor: MTLTextureDescriptor) -> MTLTexture? {
        guard descriptor.width > 0, descriptor.height > 0 else { return nil }
        return MTLTexture(width: descriptor.width, height: descriptor.height, pixelFormat: descriptor.pixelFormat, usage: descriptor.usage, pixelBuffer: nil)
    }
}

/// The device, while something can draw for it; nil otherwise, as Metal
/// answers on a machine with no GPU.
public func MTLCreateSystemDefaultDevice() -> MTLDevice? {
    MetalExecution.executor == nil ? nil : MTLDevice()
}

public final class MTLCommandQueue: @unchecked Sendable {
    public let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    public func makeCommandBuffer() -> MTLCommandBuffer? {
        MTLCommandBuffer(commandQueue: self)
    }
}

public enum MTLCommandBufferStatus: Sendable {
    case notEnqueued, enqueued, committed, scheduled, completed, error
}

public struct MTLCommandBufferError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A pass `SKRenderer` encoded: the scene flattened into a `DrawList` as it
/// stood, how the scene maps onto the viewport, and the attachments it draws
/// into.
public struct RecordedRenderPass {
    public let list: DrawList
    /// The viewport, in the target's pixels.
    public let viewport: CGRect
    public let sceneSize: CGSize
    public let anchorPoint: CGPoint
    public let scaleMode: SKSceneScaleMode
    /// The time the renderer was last updated to, which the scene's shaders
    /// take as `u_time`.
    public let time: TimeInterval
    public let color: MTLTexture?
    public let loadAction: MTLLoadAction
    public let clearColor: MTLClearColor
    /// Whether the pass has a stencil to clip with: SpriteKit's crop nodes
    /// draw through it.
    public let hasStencil: Bool
}

public final class MTLCommandBuffer: @unchecked Sendable {
    public let commandQueue: MTLCommandQueue
    public var device: MTLDevice { commandQueue.device }
    public var label: String?

    private let lock = NSCondition()
    private var _status: MTLCommandBufferStatus = .notEnqueued
    private var _error: Error?
    private var handlers: [(MTLCommandBuffer) -> Void] = []
    /// Set once the completed handlers have run: a wait ends only then, so
    /// whatever a handler wrote is there for the waiter to read.
    private var isFinished = false
    public private(set) var passes: [RecordedRenderPass] = []

    init(commandQueue: MTLCommandQueue) {
        self.commandQueue = commandQueue
    }

    public var status: MTLCommandBufferStatus { lock.withLock { _status } }
    public var error: Error? { lock.withLock { _error } }

    /// Where `SKRenderer` puts what it encodes.
    public func record(_ pass: RecordedRenderPass) {
        passes.append(pass)
    }

    public func addCompletedHandler(_ handler: @escaping (MTLCommandBuffer) -> Void) {
        lock.withLock { handlers.append(handler) }
    }

    public func enqueue() {
        lock.withLock { if _status == .notEnqueued { _status = .enqueued } }
    }

    public func commit() {
        lock.withLock { _status = .committed }
        guard let executor = MetalExecution.executor else {
            return complete(error: MTLCommandBufferError("nothing draws for Metal: no executor is registered"))
        }
        executor.enqueue(self)
    }

    /// Called by the executor once its passes are drawn.
    public func complete(error: Error? = nil) {
        let handlers: [(MTLCommandBuffer) -> Void] = lock.withLock {
            _error = error
            _status = error == nil ? .completed : .error
            defer { self.handlers = [] }
            return self.handlers
        }
        for handler in handlers { handler(self) }
        lock.withLock {
            isFinished = true
            lock.broadcast()
        }
    }

    public func waitUntilScheduled() {}

    public func waitUntilCompleted() {
        lock.lock()
        while !isFinished {
            if _status == .notEnqueued || _status == .enqueued { break }
            lock.wait()
        }
        lock.unlock()
    }
}

public final class MTLRenderPassAttachmentDescriptor {
    public var texture: MTLTexture?
    public var loadAction: MTLLoadAction = .dontCare
    public var storeAction: MTLStoreAction = .dontCare
    public init() {}
}

public final class MTLRenderPassColorAttachmentDescriptor {
    public var texture: MTLTexture?
    public var loadAction: MTLLoadAction = .dontCare
    public var storeAction: MTLStoreAction = .store
    public var clearColor = MTLClearColor()
    public init() {}
}

public final class MTLRenderPassColorAttachmentDescriptorArray {
    private var attachments: [Int: MTLRenderPassColorAttachmentDescriptor] = [:]

    public subscript(index: Int) -> MTLRenderPassColorAttachmentDescriptor! {
        get {
            if let attachment = attachments[index] { return attachment }
            let attachment = MTLRenderPassColorAttachmentDescriptor()
            attachments[index] = attachment
            return attachment
        }
        set { attachments[index] = newValue }
    }
}

public final class MTLRenderPassDescriptor {
    public let colorAttachments = MTLRenderPassColorAttachmentDescriptorArray()
    public var depthAttachment: MTLRenderPassAttachmentDescriptor! = MTLRenderPassAttachmentDescriptor()
    public var stencilAttachment: MTLRenderPassAttachmentDescriptor! = MTLRenderPassAttachmentDescriptor()

    public init() {}
}
#endif
