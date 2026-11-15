import Foundation
import ShellCore

/// The packed pages a launch's first seconds drew (the splash's and the
/// first loading screen's), kept for the next launch to start decoding as it
/// starts (`PageDecodes.prefetch`). The loading screen is made on the main
/// thread and draws at once, so its pages were decoded as it first showed: a
/// 0.3 s stall on a Galaxy M31 even when they started decoding as their
/// textures were made. The splash shows for longer than they take.
nonisolated final class LaunchPages: @unchecked Sendable {
    /// How long into a launch the pages drawn count.
    static let window: TimeInterval = 4

    private let lock = NSLock()
    private var drawn: [Int] = []
    private var isWritten = false
    private let url: URL?

    init() {
        url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("launch-pages.json")
    }

    /// The pages the last launch drew in its first seconds.
    var remembered: [Int] {
        guard let url, let data = try? Data(contentsOf: url),
              let pages = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
        return pages
    }

    /// Notes a page taken for its upload `elapsed` seconds into the launch.
    func note(_ page: Int, at elapsed: TimeInterval) {
        guard elapsed < Self.window else { return }
        lock.lock()
        if !drawn.contains(page) { drawn.append(page) }
        lock.unlock()
    }

    /// Writes what this launch drew, once its window has passed.
    func writeIfDue(at elapsed: TimeInterval) {
        guard elapsed >= Self.window else { return }
        lock.lock()
        guard !isWritten else {
            lock.unlock()
            return
        }
        isWritten = true
        let pages = drawn
        lock.unlock()
        guard let url, let data = try? JSONEncoder().encode(pages) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.warning("couldn't keep the launch's pages: \(error)")
        }
    }
}
