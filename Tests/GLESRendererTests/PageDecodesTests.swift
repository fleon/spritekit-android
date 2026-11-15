import Foundation
import Testing
@testable import GLESRenderer

/// Pages decoded by `SKTexture.preload` off the frame thread, handed to the
/// frame thread's upload.
@Suite("Page decodes", .timeLimit(.minutes(1)))
struct PageDecodesTests {
    /// Counts each page's loads, which can be held up to catch a decode
    /// part-way.
    nonisolated private final class Loader: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int: Int] = [:]
        private var threads: [Int: Bool] = [:]
        var gate: DispatchSemaphore?
        var started: DispatchSemaphore?
        let side: Int

        init(side: Int = 4) { self.side = side }

        func load(_ page: Int) -> PageDecodes.Page? {
            lock.lock()
            counts[page, default: 0] += 1
            threads[page] = Thread.isMainThread
            lock.unlock()
            started?.signal()
            gate?.wait()
            return PageImage(width: side, height: side, pixels: Data(repeating: UInt8(page), count: side * side * 4))
        }

        func count(_ page: Int) -> Int { lock.lock(); defer { lock.unlock() }; return counts[page, default: 0] }
        func onMain(_ page: Int) -> Bool? { lock.lock(); defer { lock.unlock() }; return threads[page] }
    }

    @Test("A page decoded ahead is uploaded from what was decoded, not decoded again")
    func decodedAheadIsTaken() async {
        let loader = Loader()
        let decodes = PageDecodes(load: loader.load)
        await Task.detached { decodes.decode([3, 4]) }.value
        #expect(loader.count(3) == 1)
        #expect(loader.onMain(3) == false)
        #expect(decodes.isWaiting(3))
        let page = decodes.take(3)
        #expect(page?.pixels.first == 3)
        #expect(loader.count(3) == 1)
        #expect(!decodes.isWaiting(3))
        #expect(decodes.waitingBytes == 4 * 4 * 4)
    }

    @Test("A page never preloaded decodes as it's taken")
    func takenCold() {
        let loader = Loader()
        let decodes = PageDecodes(load: loader.load)
        #expect(decodes.take(7)?.pixels.first == 7)
        #expect(loader.count(7) == 1)
    }

    @Test("A page already uploaded is never decoded ahead again, until the context goes")
    func residentSkipped() {
        let loader = Loader()
        let decodes = PageDecodes(load: loader.load)
        _ = decodes.take(1)
        decodes.decode([1])
        #expect(loader.count(1) == 1)
        #expect(!decodes.isWaiting(1))
        decodes.forgetResident()
        decodes.decode([1])
        #expect(loader.count(1) == 2)
        #expect(decodes.isWaiting(1))
    }

    @Test("Taking a page another thread is decoding waits for that decode")
    func takeWaitsForInFlight() async {
        let loader = Loader()
        let gate = DispatchSemaphore(value: 0)
        loader.gate = gate
        loader.started = DispatchSemaphore(value: 0)
        let decodes = PageDecodes(load: loader.load)
        let preloading = Task.detached { decodes.decode([5]) }
        loader.started?.wait()
        let taking = Task.detached { decodes.take(5) }
        // The taker waits for the decode under way, rather than starting a second.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(loader.count(5) == 1)
        gate.signal()
        await preloading.value
        let page = await taking.value
        #expect(page?.pixels.first == 5)
        #expect(loader.count(5) == 1)
    }

    @Test("Pages decoded and never drawn are dropped, oldest first, past the capacity")
    func capacity() {
        let loader = Loader(side: 4)
        let decodes = PageDecodes(capacity: 3 * 64, load: loader.load)
        decodes.decode([0, 1, 2, 3])
        #expect(!decodes.isWaiting(0))
        #expect(decodes.isWaiting(1) && decodes.isWaiting(2) && decodes.isWaiting(3))
        #expect(decodes.waitingBytes == 3 * 64)
    }

    @Test("Threads preloading and taking at once each page decode once")
    func concurrent() {
        let loader = Loader()
        let decodes = PageDecodes(load: loader.load)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for page in 0 ..< 32 {
                if worker == 0 { _ = decodes.take(page) } else { decodes.decode([page, (page + worker) % 32]) }
            }
        }
        for page in 0 ..< 32 {
            #expect(loader.count(page) == 1)
            #expect(decodes.take(page) != nil)
        }
    }

    @Test("The page decoded longest ago is taken for its upload ahead, and is then resident")
    func takeNextReady() {
        let decodes = PageDecodes(width: 1) { page in PageImage(width: 1, height: 1, pixels: Data([UInt8(page), 0, 0, 255])) }
        decodes.decode([4, 2])
        #expect(decodes.takeNextReady()?.page == 4)
        #expect(decodes.takeNextReady()?.page == 2)
        #expect(decodes.takeNextReady() == nil)
        #expect(decodes.waitingBytes == 0)
        // Resident: preloading it again decodes nothing.
        decodes.decode([4])
        #expect(!decodes.isWaiting(4))
    }

    @Test("Premultiplying and turning a page over at once matches doing each in turn")
    func flippedPremultiply() {
        var random = SystemRandomNumberGenerator()
        let pixels = Data((0 ..< 5 * 3 * 4).map { _ in UInt8.random(in: 0 ... 255, using: &random) })
        #expect(Premultiply.rgbaFlipped(pixels, width: 5, height: 3)
            == Premultiply.flippedRows(Premultiply.rgba(pixels), width: 5, height: 3))
    }

    @Test("A page prefetched as its texture is made is decoded once, and taking it waits for that")
    func prefetch() {
        final class Count: @unchecked Sendable { let lock = NSLock(); var loads = 0 }
        let count = Count()
        let decodes = PageDecodes(width: 1) { page in
            count.lock.lock(); count.loads += 1; count.lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            return PageImage(width: 1, height: 1, pixels: Data([UInt8(page), 0, 0, 255]))
        }
        decodes.prefetch(3)
        decodes.prefetch(3)
        #expect(decodes.take(3)?.pixels.first == 3)
        decodes.prefetch(3)
        count.lock.lock(); defer { count.lock.unlock() }
        #expect(count.loads == 1)
    }

    @Test("Preloading a page another thread is prefetching returns once it's decoded")
    func decodeWaitsForPrefetch() {
        let decodes = PageDecodes(width: 1) { page in
            Thread.sleep(forTimeInterval: 0.1)
            return PageImage(width: 1, height: 1, pixels: Data([UInt8(page), 0, 0, 255]))
        }
        decodes.prefetch(5)
        decodes.decode([5])
        #expect(decodes.isWaiting(5))
    }
}
