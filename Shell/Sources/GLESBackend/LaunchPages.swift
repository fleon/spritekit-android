import Foundation
import PlatformServices
import ShellCore

/// The packed pages a launch's first seconds drew (a splash's and the first
/// scene's), kept for the next launch to start decoding as it starts
/// (`PageDecodes.prefetch`). A first scene made on the main thread draws at
/// once, so its pages were decoded as it first showed: a 0.3 s stall on a
/// Mali-G72 phone even when they started decoding as their textures were
/// made. A splash shows for longer than they take.
nonisolated final class LaunchPages: @unchecked Sendable {
    /// How long into a launch the pages drawn count.
    static let window: TimeInterval = 4

    private let state = Locked<(drawn: [Int], isWritten: Bool)>(([], false))
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
        state.withLock { state in
            if !state.drawn.contains(page) { state.drawn.append(page) }
        }
    }

    /// Writes what this launch drew, once its window has passed.
    func writeIfDue(at elapsed: TimeInterval) {
        guard elapsed >= Self.window else { return }
        let pages: [Int]? = state.withLock { state in
            guard !state.isWritten else { return nil }
            state.isWritten = true
            return state.drawn
        }
        guard let pages, let url, let data = try? JSONEncoder().encode(pages) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.warning("couldn't keep the launch's pages: \(error)")
        }
    }
}
