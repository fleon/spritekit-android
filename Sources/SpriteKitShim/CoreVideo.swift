#if SPRITEKIT_SHIM
import Foundation

// CoreVideo, as filming a scene through `SKRenderer` uses it: pixel buffers
// a frame is rendered into and handed to the video writer (or read back for
// a picture), the writer's pool of them, and the texture cache that puts a
// Metal texture over a buffer. A game's `import CoreVideo` resolves to the
// module of that name in `Modules`, which re-exports these.
//
// A buffer is plain memory here, in the format it says it is in: the film
// asks for 32-bit BGRA, so that is what the GLES renderer reads its frames
// back as, what the picture's `CGContext` reads them as, and what the video
// writer converts to YUV for the encoder.

#if !canImport(Darwin)
public typealias OSType = UInt32
/// `[String: Any] as CFDictionary`, as the game writes its attributes.
public typealias CFDictionary = [String: Any]
public typealias CFAllocator = AnyObject
#endif

public typealias CVReturn = Int32
public let kCVReturnSuccess: CVReturn = 0
public let kCVReturnError: CVReturn = -6660
public let kCVReturnInvalidArgument: CVReturn = -6661

public let kCVPixelFormatType_32BGRA: OSType = 0x4247_5241 // 'BGRA'
public let kCVPixelFormatType_32RGBA: OSType = 0x5247_4241 // 'RGBA'

public let kCVPixelBufferPixelFormatTypeKey = "PixelFormatType"
public let kCVPixelBufferWidthKey = "Width"
public let kCVPixelBufferHeightKey = "Height"
public let kCVPixelBufferMetalCompatibilityKey = "MetalCompatibility"
public let kCVPixelBufferIOSurfacePropertiesKey = "IOSurfaceProperties"

public struct CVPixelBufferLockFlags: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let readOnly = CVPixelBufferLockFlags(rawValue: 1)
}

/// A frame's pixels: `height` rows of `bytesPerRow` bytes, top row first.
public final class CVPixelBuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: OSType
    public let baseAddress: UnsafeMutableRawPointer

    public init(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        bytesPerRow = width * 4
        baseAddress = .allocate(byteCount: max(1, bytesPerRow * height), alignment: 64)
        baseAddress.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerRow * height)
    }

    deinit {
        baseAddress.deallocate()
    }

    public var byteCount: Int { bytesPerRow * height }
}

/// Buffers of one size, as an asset writer's adaptor hands them out.
public final class CVPixelBufferPool: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: OSType
    private let lock = NSLock()
    private var free: [CVPixelBuffer] = []

    public init(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    /// A buffer nobody else holds, else a new one.
    func take() -> CVPixelBuffer {
        lock.withLock {
            if let index = free.indices.first(where: { isKnownUniquelyReferenced(&free[$0]) }) {
                return free[index]
            }
            let buffer = CVPixelBuffer(width: width, height: height, pixelFormat: pixelFormat)
            if free.count < 4 { free.append(buffer) }
            return buffer
        }
    }
}

@discardableResult
public func CVPixelBufferCreate(_ allocator: CFAllocator?, _ width: Int, _ height: Int, _ pixelFormatType: OSType, _ pixelBufferAttributes: CFDictionary?, _ pixelBufferOut: UnsafeMutablePointer<CVPixelBuffer?>) -> CVReturn {
    guard width > 0, height > 0 else { return kCVReturnInvalidArgument }
    pixelBufferOut.pointee = CVPixelBuffer(width: width, height: height, pixelFormat: pixelFormatType)
    return kCVReturnSuccess
}

@discardableResult
public func CVPixelBufferPoolCreatePixelBuffer(_ allocator: CFAllocator?, _ pool: CVPixelBufferPool, _ pixelBufferOut: UnsafeMutablePointer<CVPixelBuffer?>) -> CVReturn {
    pixelBufferOut.pointee = pool.take()
    return kCVReturnSuccess
}

@discardableResult
public func CVPixelBufferLockBaseAddress(_ pixelBuffer: CVPixelBuffer, _ lockFlags: CVPixelBufferLockFlags) -> CVReturn { kCVReturnSuccess }

@discardableResult
public func CVPixelBufferUnlockBaseAddress(_ pixelBuffer: CVPixelBuffer, _ unlockFlags: CVPixelBufferLockFlags) -> CVReturn { kCVReturnSuccess }

public func CVPixelBufferGetBaseAddress(_ pixelBuffer: CVPixelBuffer) -> UnsafeMutableRawPointer? { pixelBuffer.baseAddress }
public func CVPixelBufferGetWidth(_ pixelBuffer: CVPixelBuffer) -> Int { pixelBuffer.width }
public func CVPixelBufferGetHeight(_ pixelBuffer: CVPixelBuffer) -> Int { pixelBuffer.height }
public func CVPixelBufferGetBytesPerRow(_ pixelBuffer: CVPixelBuffer) -> Int { pixelBuffer.bytesPerRow }
public func CVPixelBufferGetPixelFormatType(_ pixelBuffer: CVPixelBuffer) -> OSType { pixelBuffer.pixelFormat }

/// Puts Metal textures over pixel buffers, so a render lands in the buffer.
public final class CVMetalTextureCache: @unchecked Sendable {
    public let device: MTLDevice
    init(device: MTLDevice) { self.device = device }
}

/// A texture over a pixel buffer, keeping the buffer alive while it's used.
public final class CVMetalTexture: @unchecked Sendable {
    public let texture: MTLTexture
    init(texture: MTLTexture) { self.texture = texture }
}

@discardableResult
public func CVMetalTextureCacheCreate(_ allocator: CFAllocator?, _ cacheAttributes: CFDictionary?, _ metalDevice: MTLDevice, _ textureAttributes: CFDictionary?, _ cacheOut: UnsafeMutablePointer<CVMetalTextureCache?>) -> CVReturn {
    cacheOut.pointee = CVMetalTextureCache(device: metalDevice)
    return kCVReturnSuccess
}

@discardableResult
public func CVMetalTextureCacheCreateTextureFromImage(_ allocator: CFAllocator?, _ textureCache: CVMetalTextureCache, _ sourceImage: CVPixelBuffer, _ textureAttributes: CFDictionary?, _ pixelFormat: MTLPixelFormat, _ width: Int, _ height: Int, _ planeIndex: Int, _ textureOut: UnsafeMutablePointer<CVMetalTexture?>) -> CVReturn {
    guard planeIndex == 0, width == sourceImage.width, height == sourceImage.height,
          pixelFormat == .bgra8Unorm || pixelFormat == .rgba8Unorm else { return kCVReturnInvalidArgument }
    let texture = MTLTexture(width: width, height: height, pixelFormat: pixelFormat, usage: [.renderTarget, .shaderRead], pixelBuffer: sourceImage)
    textureOut.pointee = CVMetalTexture(texture: texture)
    return kCVReturnSuccess
}

public func CVMetalTextureGetTexture(_ image: CVMetalTexture) -> MTLTexture? { image.texture }
#endif
