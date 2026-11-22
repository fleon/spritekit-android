import Foundation
import Testing
@testable import PlatformShim

/// Timeouts that run only when a test says so.
private final class Later {
    var due: [(seconds: TimeInterval, work: () -> Void)] = []
    var after: (TimeInterval, @escaping () -> Void) -> Void {
        { [unowned self] seconds, work in due.append((seconds, work)) }
    }

    func runAll() {
        let work = due
        due = []
        for item in work { item.work() }
    }
}

@MainActor
struct SharedCallTests {
    @Test func theFirstJoinStartsItAndOneAnswerAnswersEveryone() {
        let call = SharedCall<Int>(ifAbandoned: -1)
        var starts = 0
        var answers: [Int] = []
        for _ in 0 ..< 3 { call.join(start: { starts += 1 }, then: { answers.append($0) }) }
        #expect(starts == 1)
        #expect(call.isPending)
        call.finish(7)
        #expect(answers == [7, 7, 7])
        #expect(!call.isPending)
    }

    @Test func aSecondFinishAnswersNobodyAgain() {
        let call = SharedCall<Int>(ifAbandoned: -1)
        var answers: [Int] = []
        call.join(start: {}, then: { answers.append($0) })
        call.finish(1)
        call.finish(2)
        #expect(answers == [1])
    }

    @Test func aJoinAfterAnAnswerStartsItAgain() {
        let call = SharedCall<Int>(ifAbandoned: -1)
        var starts = 0
        call.join(start: { starts += 1 }, then: { _ in })
        call.finish(1)
        call.join(start: { starts += 1 }, then: { _ in })
        #expect(starts == 2)
    }

    @Test func whoeverStillWaitsWhenItGoesIsAnswered() {
        var answers: [Int] = []
        var call: SharedCall<Int>? = SharedCall(ifAbandoned: -1)
        call?.join(start: {}, then: { answers.append($0) })
        call = nil
        #expect(answers == [-1])
    }

    @Test func awaitingCallersShareTheAnswer() async {
        let call = SharedCall<String>(ifAbandoned: "")
        var starts = 0
        // Both on the main actor, as the backends' callers are.
        let first = Task { await call.join { starts += 1 } }
        let second = Task { await call.join { starts += 1 } }
        while starts == 0 { await Task.yield() }
        await Task.yield()
        call.finish("ok")
        #expect(await [first.value, second.value] == ["ok", "ok"])
        #expect(starts == 1)
    }
}

@MainActor
struct RequestTableTests {
    @Test func eachRequestHasItsOwnNumberAndAnswer() {
        let table = RequestTable<String>(ifAbandoned: "gone")
        var sent: [Int] = []
        var answers: [String] = []
        for _ in 0 ..< 2 {
            table.send(start: { sent.append($0); return nil }, then: { answers.append($0) })
        }
        #expect(sent == [1, 2])
        #expect(table.pending == [1, 2])
        #expect(table.finish(id: 2, "second"))
        #expect(table.pending == [1])
        #expect(answers == ["second"])
    }

    @Test func anAnswerComesOnceAndAnUnknownNumberIsIgnored() {
        let table = RequestTable<Int>(ifAbandoned: 0)
        var answers: [Int] = []
        table.send(start: { _ in nil }, then: { answers.append($0) })
        #expect(table.finish(id: 1, 5))
        #expect(!table.finish(id: 1, 6))
        #expect(!table.finish(id: 9, 7))
        #expect(answers == [5])
    }

    @Test func anAnswerAtOnceNeedsNoFinish() {
        let later = Later()
        let table = RequestTable<Bool>(ifAbandoned: false, after: later.after)
        var answers: [Bool] = []
        table.send(timeout: (30, false), start: { _ in true }, then: { answers.append($0) })
        #expect(answers == [true])
        #expect(table.pending.isEmpty)
        #expect(later.due.isEmpty)
    }

    @Test func aTimeoutAnswersWhatJavaNeverDid() {
        let later = Later()
        let table = RequestTable<String>(ifAbandoned: "gone", after: later.after)
        var answers: [String] = []
        table.send(timeout: (30, "late"), start: { _ in nil }, then: { answers.append($0) })
        table.send(timeout: (30, "late"), start: { _ in nil }, then: { answers.append($0) })
        #expect(later.due.map(\.seconds) == [30, 30])
        table.finish(id: 1, "answered")
        later.runAll()
        #expect(answers == ["answered", "late"])
    }

    @Test func finishAllAnswersEveryoneOldestFirst() {
        let table = RequestTable<String>(ifAbandoned: "gone")
        var answers: [String] = []
        for index in 0 ..< 3 { table.send(start: { _ in nil }, then: { answers.append("\(index) \($0)") }) }
        table.finishAll("signed out")
        table.finishAll("again")
        #expect(answers == ["0 signed out", "1 signed out", "2 signed out"])
    }

    @Test func whatStillWaitsWhenTheTableGoesIsAnswered() {
        var answers: [String] = []
        var table: RequestTable<String>? = RequestTable(ifAbandoned: "gone")
        table?.send(start: { _ in nil }, then: { answers.append($0) })
        table = nil
        #expect(answers == ["gone"])
    }

    @Test func anAwaitedRequestResumesWithItsAnswer() async {
        let table = RequestTable<Int>(ifAbandoned: 0)
        let answer = Task { await table.send { _ in nil } }
        while table.pending.isEmpty { await Task.yield() }
        table.finish(id: 1, 42)
        #expect(await answer.value == 42)
    }
}
