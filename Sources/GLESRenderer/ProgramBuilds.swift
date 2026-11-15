import Foundation

/// Programs built on a thread of their own, in a GL context that shares the
/// frame thread's objects (`GLBuilderThread`), by the shader source and inputs
/// they were translated from (`ResourceCache.programKey`).
///
/// A phone's driver takes up to a fifth of a second to link one of the game's
/// bigger shaders the first time it meets it (a Galaxy M31's Mali-G72, before
/// its shader cache has it), and a scene holds dozens: built as each first
/// drew, they froze the loading screen's warm-up draw for seconds, and built
/// a few a frame they still dropped its frames. A scene's build hands its
/// shaders over as it finishes (`SKShader.programWarmer`), they're linked
/// here while the loading screen plays on, and the frame thread takes each
/// finished program as the shader first draws (`take`), waiting only for one
/// still being linked.
public final class ProgramBuilds: @unchecked Sendable {
    private enum State {
        case waiting
        case done(UInt32)
    }

    private let condition = NSCondition()
    private var states: [String: State] = [:]
    /// Keys whose programs the frame thread has, built here or there.
    private var held: Set<String> = []
    private var queue: [(key: String, vertex: String, fragment: String)] = []
    private var isScheduled = false
    private let schedule: (@escaping @Sendable () -> Void) -> Void
    private let build: (_ vertex: String, _ fragment: String) -> UInt32

    /// `schedule` runs work on the building thread; `build` compiles and
    /// links there, returning 0 on failure, and returns once the program is
    /// complete for the other context to use (`glFinish`).
    public init(
        schedule: @escaping (@escaping @Sendable () -> Void) -> Void,
        build: @escaping (_ vertex: String, _ fragment: String) -> UInt32
    ) {
        self.schedule = schedule
        self.build = build
    }

    /// Builds the program unless it's built, being built or waiting: from any thread.
    public func submit(key: String, vertex: String, fragment: String) {
        condition.lock()
        guard states[key] == nil, !held.contains(key) else {
            condition.unlock()
            return
        }
        states[key] = .waiting
        queue.append((key, vertex, fragment))
        let start = !isScheduled
        isScheduled = true
        condition.unlock()
        if start { schedule { [self] in drain() } }
    }

    /// Told how long `take` waited for a program still being built, in seconds.
    public var waited: ((TimeInterval) -> Void)?

    /// Whether `key` is built, being built or waiting.
    public func knows(_ key: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return states[key] != nil || held.contains(key)
    }

    /// The frame thread has a program for `key`, built there: none is built here.
    public func hold(_ key: String) {
        condition.lock()
        held.insert(key)
        condition.unlock()
    }

    private func drain() {
        while true {
            condition.lock()
            guard !queue.isEmpty else {
                isScheduled = false
                condition.unlock()
                return
            }
            let next = queue.removeFirst()
            condition.unlock()
            let name = build(next.vertex, next.fragment)
            condition.lock()
            if states[next.key] != nil { states[next.key] = .done(name) }
            condition.broadcast()
            condition.unlock()
        }
    }

    /// The program built for `key`, waiting for it if it's still being built;
    /// nil if it was never submitted or failed to build. The caller owns it.
    public func take(_ key: String) -> UInt32? {
        condition.lock()
        defer { condition.unlock() }
        var waitedSince: DispatchTime?
        defer {
            if let waitedSince {
                waited?(Double(DispatchTime.now().uptimeNanoseconds - waitedSince.uptimeNanoseconds) / 1_000_000_000)
            }
        }
        while true {
            switch states[key] {
            case nil:
                return nil
            case .waiting:
                if waitedSince == nil { waitedSince = .now() }
                condition.wait()
            case let .done(name):
                states.removeValue(forKey: key)
                if name != 0 { held.insert(key) }
                return name == 0 ? nil : name
            }
        }
    }

    /// Forgets everything: the context they were built in has gone. Returns
    /// the programs built and never taken, for deleting while it's still there.
    @discardableResult
    public func removeAll() -> [UInt32] {
        condition.lock()
        defer { condition.unlock() }
        queue.removeAll()
        var built: [UInt32] = []
        for case let .done(name) in states.values where name != 0 { built.append(name) }
        states.removeAll()
        held.removeAll()
        condition.broadcast()
        return built
    }
}
