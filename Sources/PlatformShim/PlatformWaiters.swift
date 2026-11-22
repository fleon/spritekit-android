import Foundation

// Waiting on Java's answers through the platform channel. Each waiter is
// taken out of its table before it runs, so none is answered twice, and
// whatever still waits when its table goes is answered with the value given
// for that, so none waits for ever. They hold no lock: like the state they
// replace, each is used on the thread Play's answers arrive on (the main
// actor's), and their `async` calls run on the caller's actor.

/// One call many may ask for at once: the first to join starts it (calls
/// into Java), the rest wait with it, and one answer (`finish`) answers
/// them all. The next join after that starts it again.
public final class SharedCall<Value> {
    private var waiting: [(Value) -> Void] = []
    private let abandoned: Value

    /// `abandoned` answers whoever still waits when the call goes.
    public init(ifAbandoned abandoned: Value) {
        self.abandoned = abandoned
    }

    deinit {
        finish(abandoned)
    }

    /// Whether anyone waits for an answer.
    public var isPending: Bool { !waiting.isEmpty }

    /// Waits for the answer, running `start` if nobody else was waiting.
    public func join(start: () -> Void, then answered: @escaping (Value) -> Void) {
        let first = waiting.isEmpty
        waiting.append(answered)
        if first { start() }
    }

    /// Waits for the answer, running `start` if nobody else was waiting.
    public func join(isolation: isolated (any Actor)? = #isolation, start: () -> Void) async -> Value {
        await withCheckedContinuation { continuation in
            join(start: start) { continuation.resume(returning: $0) }
        }
    }

    /// Answers everyone waiting; nothing if nobody is.
    public func finish(_ value: Value) {
        let answered = waiting
        waiting = []
        for waiter in answered { waiter(value) }
    }
}

/// Requests sent with a number each, answered by number: `send` numbers a
/// request and waits, `finish(id:_:)` answers the one with that number,
/// `finishAll` answers every one still waiting (a sign-out), and a timeout
/// answers one Java never did.
public final class RequestTable<Answer> {
    private var next = 1
    private var waiting: [Int: (Answer) -> Void] = [:]
    private let abandoned: Answer
    private let after: (TimeInterval, @escaping () -> Void) -> Void

    /// `abandoned` answers whatever still waits when the table goes;
    /// `after` runs a timeout later on the game's thread (the main queue,
    /// which the shell drains once a frame).
    public init(
        ifAbandoned abandoned: Answer,
        after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.abandoned = abandoned
        self.after = after
    }

    deinit {
        finishAll(abandoned)
    }

    /// The numbers of the requests still waiting, oldest first.
    public var pending: [Int] { waiting.keys.sorted() }

    /// Sends a request under the next number: `start` sends it, returning
    /// an answer when it has one at once (nil to wait for `finish`).
    /// `timeout` answers it if nothing has by then.
    public func send(
        timeout: (seconds: TimeInterval, answer: Answer)? = nil,
        start: (Int) -> Answer?,
        then answered: @escaping (Answer) -> Void
    ) {
        let id = next
        next += 1
        waiting[id] = answered
        if let answer = start(id) {
            finish(id: id, answer)
            return
        }
        guard let timeout, waiting[id] != nil else { return }
        after(timeout.seconds) { [weak self] in self?.finish(id: id, timeout.answer) }
    }

    /// Sends a request under the next number and waits for its answer.
    public func send(
        isolation: isolated (any Actor)? = #isolation,
        timeout: (seconds: TimeInterval, answer: Answer)? = nil,
        start: (Int) -> Answer?
    ) async -> Answer {
        await withCheckedContinuation { continuation in
            send(timeout: timeout, start: start) { continuation.resume(returning: $0) }
        }
    }

    /// Answers the request `id`: false if it isn't waiting (answered
    /// already, or never sent).
    @discardableResult
    public func finish(id: Int, _ answer: Answer) -> Bool {
        guard let waiter = waiting.removeValue(forKey: id) else { return false }
        waiter(answer)
        return true
    }

    /// Answers every request still waiting, oldest first.
    public func finishAll(_ answer: Answer) {
        for id in pending { finish(id: id, answer) }
    }
}
