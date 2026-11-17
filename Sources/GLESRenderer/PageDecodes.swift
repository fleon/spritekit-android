import Foundation

/// Packed pages decoded ahead of their first draw, off the frame thread.
///
/// SpriteKit's `SKTexture.preload` decodes on a queue of its own, and the
/// a game may lean on it: a loading screen preloading the next scene's art,
/// a paged screen its neighbours'. Here a page used to
/// be read out of the APK, inflated and premultiplied on the frame thread
/// the first time anything on it drew, a 2048-pixel page at a time: a stall
/// the length of several frames on a phone, every time new art came on
/// screen. `decode(_:)` does that work on whichever thread preloads,
/// and the frame thread then only uploads what it finds here (`take`).
///
/// They decode a few at a time. On a Mali-G72 phone that took a loading
/// screen's longest frame from 3.7–4.8 s to 2.6–3.3 s, the next scene
/// arriving about a second sooner. A page decoded and never drawn is
/// dropped, oldest first, once the pages waiting hold more than `capacity`
/// bytes; one already uploaded is never decoded again until the GL context
/// goes (`forgetResident`).
public final class PageDecodes: @unchecked Sendable {
    public typealias Page = PageImage

    private let load: (Int) -> Page?
    private let capacity: Int
    private let condition = NSCondition()
    private var ready: [Int: Page] = [:]
    private var order: [Int] = []
    private var inFlight: Set<Int> = []
    private var resident: Set<Int> = []
    private var bytes = 0

    /// How many pages decode at once: a scene's art spans a dozen pages,
    /// and one thread decoding them in turn kept a loading screen up for
    /// seconds longer than decoding them as they drew had.
    private let width: Int

    /// `load` reads and decodes one page, premultiplied, on the calling
    /// thread. The default capacity holds a whole scene's pages (a paged
    /// screen and its neighbours' art can span about twenty): any less and
    /// the first were dropped before they drew, and decoded again. A phone
    /// with little memory keeps fewer, an eighth of what it has.
    public init(capacity: Int = PageDecodes.defaultCapacity, width: Int = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount - 1)), load: @escaping (Int) -> Page?) {
        self.capacity = capacity
        self.width = width
        self.load = load
    }

    public static var defaultCapacity: Int {
        min(384 << 20, Int(clamping: ProcessInfo.processInfo.physicalMemory / 8))
    }

    /// Decodes each of `pages` not uploaded, waiting or being decoded yet,
    /// a few at a time, and keeps them for `take`; returns once every one of
    /// them is decoded, those another thread was decoding (`prefetch`)
    /// included, so the frame thread never waits for one the preload named.
    public func decode(_ pages: some Sequence<Int>) {
        let pages = Array(pages)
        condition.lock()
        var wanted: [Int] = []
        for page in pages where !resident.contains(page) && ready[page] == nil && !inFlight.contains(page) {
            inFlight.insert(page)
            wanted.append(page)
        }
        condition.unlock()
        let threads = min(width, wanted.count)
        if threads == 1 {
            for page in wanted { finish(page, load(page)) }
        } else if threads > 1 {
            DispatchQueue.concurrentPerform(iterations: threads) { lane in
                for index in stride(from: lane, to: wanted.count, by: threads) {
                    finish(wanted[index], load(wanted[index]))
                }
            }
        }
        condition.lock()
        while pages.contains(where: { inFlight.contains($0) }) { condition.wait() }
        condition.unlock()
    }

    /// Starts decoding `page` on a queue of its own unless it's uploaded,
    /// waiting or being decoded, returning at once: a page a texture was
    /// just made on, which may well draw next frame (`take` waits for it
    /// then, rather than decoding it again).
    public func prefetch(_ page: Int) {
        condition.lock()
        guard !resident.contains(page), ready[page] == nil, !inFlight.contains(page) else {
            condition.unlock()
            return
        }
        inFlight.insert(page)
        condition.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            finish(page, load(page))
        }
    }

    private func finish(_ page: Int, _ decoded: Page?) {
        condition.lock()
        inFlight.remove(page)
        if let decoded, !resident.contains(page) {
            ready[page] = decoded
            order.append(page)
            bytes += decoded.byteCount
            while bytes > capacity, let oldest = order.first {
                order.removeFirst()
                bytes -= ready.removeValue(forKey: oldest)?.byteCount ?? 0
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    /// The page's pixels for its upload, marking it resident: decoded ahead
    /// if it was, waited for if another thread is decoding it now, else
    /// decoded here and now.
    public func take(_ page: Int) -> Page? {
        condition.lock()
        while inFlight.contains(page) { condition.wait() }
        resident.insert(page)
        let decoded = ready.removeValue(forKey: page)
        if let decoded {
            order.removeAll { $0 == page }
            bytes -= decoded.byteCount
        }
        condition.unlock()
        return decoded ?? load(page)
    }

    /// The page decoded longest ago and not drawn yet, for its upload ahead
    /// of its first draw (`ResourceCache.uploadAhead`), marking it resident.
    public func takeNextReady() -> (page: Int, image: Page)? {
        condition.lock()
        defer { condition.unlock() }
        guard !order.isEmpty else { return nil }
        let page = order.removeFirst()
        guard let decoded = ready.removeValue(forKey: page) else { return nil }
        bytes -= decoded.byteCount
        resident.insert(page)
        return (page, decoded)
    }

    /// Every upload went with the GL context: pages decode again on demand.
    public func forgetResident() {
        condition.lock()
        resident.removeAll()
        condition.unlock()
    }

    /// Bytes decoded and waiting for their upload.
    public var waitingBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return bytes
    }

    /// Whether `page` is decoded and waiting.
    public func isWaiting(_ page: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return ready[page] != nil
    }
}
