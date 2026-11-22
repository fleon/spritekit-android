/// Stepping through a `CaseIterable` type's cases in `allCases` order: a
/// picker's segments, a setting that cycles, a mode rail.
extension CaseIterable where Self: Equatable {
    /// Where this case stands in `allCases`.
    public var index: Int {
        Array(Self.allCases).firstIndex(of: self) ?? 0
    }

    /// The case at `index` in `allCases`, nil past either end.
    public static func at(_ index: Int) -> Self? {
        let cases = Array(allCases)
        return cases.indices.contains(index) ? cases[index] : nil
    }

    /// The case after this one: the first after the last, or with
    /// `wrapping: false` the last again.
    public func next(wrapping: Bool = true) -> Self {
        step(1, wrapping: wrapping)
    }

    /// The case before this one: the last before the first, or with
    /// `wrapping: false` the first again.
    public func previous(wrapping: Bool = true) -> Self {
        step(-1, wrapping: wrapping)
    }

    private func step(_ offset: Int, wrapping: Bool) -> Self {
        let cases = Array(Self.allCases)
        guard !cases.isEmpty else { return self }
        let target = index + offset
        let landed = wrapping ? (target % cases.count + cases.count) % cases.count : min(max(target, 0), cases.count - 1)
        return cases[landed]
    }
}
