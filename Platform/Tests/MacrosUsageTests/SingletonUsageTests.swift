import Foundation
import Macros
import Testing

// `@Singleton` as the compiler expands and type-checks it, under Swift 5
// with main-actor default isolation: a main-actor type, a `nonisolated` one,
// one with its own `init()`, and an `NSObject` subclass.

@Singleton
final class TallyStore {
    var count = 0
}

@Singleton
nonisolated final class Clock {
    let started = 42
}

@Singleton
final class Warmed {
    let values: [Int]
    private init() {
        values = [1, 2, 3]
    }
}

@Singleton
nonisolated final class Observer: NSObject {}

struct SingletonUsageTests {
    @Test func eachTypeHasOneInstance() {
        TallyStore.shared.count += 1
        #expect(TallyStore.shared === TallyStore.shared)
        #expect(TallyStore.shared.count == 1)
        #expect(Warmed.shared.values == [1, 2, 3])
        #expect(Observer.shared === Observer.shared)
    }

    @Test nonisolated func aNonisolatedTypesInstanceIsReadOffTheMainActor() {
        #expect(Clock.shared.started == 42)
    }
}
