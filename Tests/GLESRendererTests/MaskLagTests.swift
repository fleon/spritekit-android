import Testing
@testable import GLESRenderer

@Suite("Mask lag")
struct MaskLagTests {
    @Test("A shape appearing gets its mask at once; one already drawn draws its last while the new one is made")
    func firstNowThenPrevious() {
        var lag = MaskLag<Int, String>()
        var ready: Set<Int> = []
        // Appearing: nothing to stand in.
        #expect(lag.resolve(owner: "ants", key: 1, isReady: ready.contains) == (.now, nil))
        ready.insert(1)
        lag.drewNow(owner: "ants", key: 1)
        // Same path next frame: ready.
        #expect(lag.resolve(owner: "ants", key: 1, isReady: ready.contains) == (.ready(1), nil))
        // A new path: last frame's mask, and key 2 made on a worker.
        #expect(lag.resolve(owner: "ants", key: 2, isReady: ready.contains) == (.previous(1), 2))
        // Made: ready from then on.
        ready.insert(2)
        #expect(lag.finished(owner: "ants", key: 2) == nil)
        #expect(lag.resolve(owner: "ants", key: 2, isReady: ready.contains) == (.ready(2), nil))
    }

    @Test("One job at a time: paths asked for meanwhile are skipped to the latest")
    func latestOnly() {
        var lag = MaskLag<Int, String>()
        var ready: Set<Int> = [1]
        lag.drewNow(owner: "ants", key: 1)
        #expect(lag.resolve(owner: "ants", key: 2, isReady: ready.contains) == (.previous(1), 2))
        // While 2 is made, 3 and then 4 are asked for: no new job.
        #expect(lag.resolve(owner: "ants", key: 3, isReady: ready.contains) == (.previous(1), nil))
        #expect(lag.resolve(owner: "ants", key: 4, isReady: ready.contains) == (.previous(1), nil))
        // 2 lands: 4, the latest, is next; 3 never is.
        ready.insert(2)
        #expect(lag.finished(owner: "ants", key: 2) == 4)
        // Waiting on 4, asked for 5, it draws 2: the newest made.
        #expect(lag.resolve(owner: "ants", key: 5, isReady: ready.contains) == (.previous(2), nil))
        ready.insert(4)
        #expect(lag.finished(owner: "ants", key: 4) == 5)
    }

    @Test("Each shape is its own; a shape gone for long enough is forgotten")
    func ownersAndForgetting() {
        var lag = MaskLag<Int, String>()
        let ready: Set<Int> = [1]
        lag.drewNow(owner: "a", key: 1)
        #expect(lag.resolve(owner: "b", key: 2, isReady: ready.contains) == (.now, nil))
        #expect(lag.resolve(owner: "a", key: 2, isReady: ready.contains) == (.previous(1), 2))
        _ = lag.finished(owner: "a", key: 2)
        for _ in 0 ..< 600 { lag.beginFrame() }
        #expect(lag.count == 0)
        // Forgotten, it appears afresh: at once.
        #expect(lag.resolve(owner: "a", key: 3, isReady: ready.contains) == (.now, nil))
    }
}
