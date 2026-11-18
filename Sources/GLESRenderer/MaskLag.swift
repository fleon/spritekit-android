import Foundation

/// Which coverage mask a shape draws while its path keeps changing.
///
/// A shape whose path is rebuilt every frame (an outline with marching
/// ants, a ring drawing itself round) needs a new mask every frame, and a
/// large one costs the frame thread milliseconds to rasterise on a phone.
/// So when a shape that drew a mask last frame asks for one that isn't
/// ready, it draws the mask it drew before, one frame behind, while the new
/// one is rasterised on a worker; the frame thread only uploads it. A shape
/// with nothing drawn before (one appearing) gets its mask at once, as
/// before, so nothing pops in a frame late.
///
/// One job per shape at a time: a path asked for while one is being made is
/// noted, and only the latest noted is made next, so a shape that changes
/// faster than masks can be made skips frames rather than falling ever
/// further behind.
///
/// Generic over the mask's key and the shape's identity so the decisions
/// test on the Mac; `ShapeMasks` (the shell) does the GL.
public struct MaskLag<Key: Hashable, Owner: Hashable> {
    public enum Decision: Equatable {
        /// The mask asked for is ready: draw it.
        case ready(Key)
        /// Nothing drawn before to stand in: make it now, on this thread.
        case now
        /// Draw this one, drawn before, while the new one is made.
        case previous(Key)
    }

    private struct State {
        var shown: Key?
        var making: Key?
        var wanted: Key?
        var seen: Int
    }

    private var owners: [Owner: State] = [:]
    private var frame = 0

    public init() {}

    /// What `owner` draws for `key` this frame, and the key to start making
    /// on a worker, if any. `isReady` says whether a key's mask is made.
    public mutating func resolve(owner: Owner, key: Key, isReady: (Key) -> Bool) -> (decision: Decision, start: Key?) {
        var state = owners[owner] ?? State(seen: frame)
        state.seen = frame
        defer { owners[owner] = state }
        if isReady(key) {
            state.shown = key
            state.wanted = nil
            return (.ready(key), nil)
        }
        guard let previous = state.shown, isReady(previous) else {
            return (.now, nil)
        }
        state.wanted = key
        guard state.making == nil else { return (.previous(previous), nil) }
        state.making = key
        return (.previous(previous), key)
    }

    /// `owner` drew `key`, made on this thread.
    public mutating func drewNow(owner: Owner, key: Key) {
        owners[owner, default: State(seen: frame)].shown = key
    }

    /// A worker finished `key` for `owner`: the next key to start, if the
    /// owner has asked for a newer one meanwhile.
    public mutating func finished(owner: Owner, key: Key) -> Key? {
        guard var state = owners[owner] else { return nil }
        defer { owners[owner] = state }
        state.making = nil
        state.shown = key
        guard let wanted = state.wanted, wanted != key else {
            state.wanted = nil
            return nil
        }
        state.making = wanted
        return wanted
    }

    /// A new frame; shapes not seen for `forgetAfter` frames are forgotten.
    public mutating func beginFrame(forgetAfter: Int = 600) {
        frame += 1
        guard frame % forgetAfter == 0 else { return }
        owners = owners.filter { frame - $0.value.seen < forgetAfter || $0.value.making != nil }
    }

    /// How many shapes it is keeping track of (tests).
    var count: Int { owners.count }
}
