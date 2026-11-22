import Foundation
import PlatformServices
import Testing

struct LockedTests {
    @Test func everyWriteFromEveryThreadLands() {
        let counter = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in counter.withLock { $0 += 1 } }
        #expect(counter.withLock { $0 } == 10_000)
    }

    @Test func handsBackWhatTheBodyReturnsAndUnlocksWhenItThrows() {
        struct Refused: Error {}
        let names = Locked(["a"])
        #expect(throws: Refused.self) {
            try names.withLock { names in
                names.append("b")
                throw Refused()
            }
        }
        // Unlocked again: a second call doesn't wait for ever.
        #expect(names.withLock { $0 } == ["a", "b"])
    }

    @Test func aPlainLockRunsItsBodyHeld() {
        let lock = NSLock()
        var total = 0
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in lock.withLock { total += 1 } }
        #expect(lock.withLock { total } == 1_000)
        #expect(lock.try())
        lock.unlock()
    }
}
