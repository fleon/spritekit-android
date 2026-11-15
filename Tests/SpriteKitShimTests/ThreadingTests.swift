import Foundation
import Testing
@testable import SpriteKitShim

/// What the shim promises the game's work off the main thread: scenes,
/// world pages, backdrop floors and share films are all built on threads of
/// their own while the main one draws, as they are on Apple.
@Suite("Threads", .serialized, .timeLimit(.minutes(1)))
struct ThreadingTests {
    nonisolated private static func solid(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> UIImage {
        UIImage(cgImage: RasterImage(width: 1, height: 1, pixels: [red, green, blue, 255]))
    }

    nonisolated private static func render(_ image: UIImage, _ during: () -> Void = {}) -> [UInt8]? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { _ in
            during()
            image.draw(in: CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return drawn.cgImage.map { Array($0.pixels.prefix(4)) }
    }

    @Test("An image drawn while another thread renders lands in this thread's renderer")
    func contextStackIsPerThread() async {
        // Another thread opens its renderer inside this one's and holds it
        // open while this one draws: with one stack for every thread, this
        // thread's red went into the other's bitmap.
        let opened = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var other: Task<[UInt8]?, Never>?
        let here = Self.render(Self.solid(255, 0, 0)) {
            other = Task.detached {
                Self.render(Self.solid(0, 0, 255)) {
                    opened.signal()
                    release.wait()
                }
            }
            opened.wait()
        }
        release.signal()
        let there = await other?.value
        #expect(here == [255, 0, 0, 255])
        #expect(there == [0, 0, 255, 255])
    }

    @Test("Many threads rendering at once each get their own image")
    func manyRenderers() {
        let count = 16
        let results = Results(count: count)
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let shade = UInt8(index * 15)
            for _ in 0 ..< 20 {
                results.set(index, Self.render(Self.solid(shade, 255 - shade, 7)))
            }
        }
        for index in 0 ..< count {
            let shade = UInt8(index * 15)
            #expect(results.get(index) == [shade, 255 - shade, 7, 255])
        }
    }

    nonisolated private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[UInt8]?]
        init(count: Int) { values = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: [UInt8]?) { lock.lock(); values[index] = value; lock.unlock() }
        func get(_ index: Int) -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return values[index] }
    }

    // MARK: Preloading

    nonisolated private static let index = try! AssetIndex(json: Data("""
    {
     "version": 1, "scale": 3,
     "pages": [
      { "file": "atlas-000.png", "width": 64, "height": 64 },
      { "file": "atlas-001.png", "width": 64, "height": 64 },
      { "file": "atlas-002.png", "width": 64, "height": 64 }
     ],
     "assets": {
      "A": { "page": 0, "rect": [0, 0, 6, 6], "size": [2, 2] },
      "B": { "page": 1, "rect": [0, 0, 6, 6], "size": [2, 2] },
      "C": { "page": 1, "rect": [6, 0, 6, 6], "size": [2, 2] }
     }
    }
    """.utf8))

    nonisolated private final class Decodes: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(pages: Set<Int>, onMain: Bool)] = []
        func record(_ pages: Set<Int>) {
            lock.lock()
            calls.append((pages, Thread.isMainThread))
            lock.unlock()
        }
        var snapshot: [(pages: Set<Int>, onMain: Bool)] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    nonisolated private static func textures(_ names: String...) -> [SKTexture] {
        names.map { SKTexture(imageNamed: $0, in: index) } + [SKTexture(color: .white, size: CGSize(width: 1, height: 1))]
    }

    @Test("Preloading off the main thread decodes the textures' pages there, then calls back")
    func preloadsOffMain() async {
        let decodes = Decodes()
        SKTexture.pageDecoder = { decodes.record($0) }
        defer { SKTexture.pageDecoder = nil }
        let textures = Self.textures("A", "B", "C")
        let order = await Task.detached { () -> [String] in
            var order: [String] = []
            SKTexture.preload(textures) { order.append("done") }
            order.append("returned")
            return order
        }.value
        // As `WorldTextures.preloadNow` needs: decoded before it returns.
        #expect(order == ["done", "returned"])
        let calls = decodes.snapshot
        #expect(calls.count == 1)
        #expect(calls.first?.pages == [0, 1])
        #expect(calls.first?.onMain == false)
    }

    @Test("Preloading from the main thread decodes on a queue of its own")
    func preloadsFromMain() async {
        let decodes = Decodes()
        SKTexture.pageDecoder = { decodes.record($0) }
        defer { SKTexture.pageDecoder = nil }
        let textures = Self.textures("B")
        #expect(Thread.isMainThread)
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            SKTexture.preload(textures) { finished.resume() }
        }
        let calls = decodes.snapshot
        #expect(calls.count == 1)
        #expect(calls.first?.pages == [1])
        #expect(calls.first?.onMain == false)
    }

    @Test("Textures on no page call back without decoding anything")
    func preloadsNothing() {
        let decodes = Decodes()
        SKTexture.pageDecoder = { decodes.record($0) }
        defer { SKTexture.pageDecoder = nil }
        var done = false
        SKTexture.preload([SKTexture(color: .white, size: CGSize(width: 1, height: 1))]) { done = true }
        #expect(done)
        #expect(decodes.snapshot.isEmpty)
    }

    // MARK: The clock

    @Test("The media clock starts once, whichever thread reads it first")
    func clockStartsOnce() {
        let readings = Results(count: 8)
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let first = MediaTime.defaultSource()
            let second = MediaTime.defaultSource()
            readings.set(index, second >= first && first >= 0 ? [1] : [0])
        }
        for index in 0 ..< 8 { #expect(readings.get(index) == [1]) }
    }

    @Test("Preloading on a building thread hands over the shaders that thread made, and only those")
    func shadersHandedOver() async {
        final class Box: @unchecked Sendable { var handed: [[SKShader]] = [] }
        let box = Box()
        let lock = NSLock()
        SKShader.programWarmer = { shaders in lock.lock(); box.handed.append(shaders); lock.unlock() }
        defer { SKShader.programWarmer = nil }
        let made: [SKShader] = await withCheckedContinuation { done in
            Thread {
                let shaders = [SKShader(source: "a"), SKShader(source: "b")]
                SKTexture.preload([]) { done.resume(returning: shaders) }
            }.start()
        }
        lock.lock()
        defer { lock.unlock() }
        #expect(box.handed.count == 1)
        #expect(box.handed.first?.map(ObjectIdentifier.init) == made.map(ObjectIdentifier.init))
    }
}
