import Foundation

// What the runtime's host tests share: scratch defaults, and comparing
// values that come out of arithmetic.

/// A fresh, empty defaults suite named `name` (a new one each call unless
/// given), so no test sees another's keys.
public func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// `scratchDefaults` and the suite's name, `prefix` before a new UUID, for a
/// test that needs the suite by name.
public func scratchSuite(prefix: String = "") -> (defaults: UserDefaults, name: String) {
    let name = prefix + UUID().uuidString
    return (scratchDefaults(name), name)
}

/// Whether two values are within `tolerance` of each other.
public func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1e-6) -> Bool {
    abs(a - b) < tolerance
}

public func near(_ a: Float, _ b: Float, _ tolerance: Float = 1e-6) -> Bool {
    abs(a - b) < tolerance
}

public func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-6) -> Bool {
    near(a.x, b.x, tolerance) && near(a.y, b.y, tolerance)
}

/// Whether `point` is within `tolerance` of (`x`, `y`).
public func near(_ point: CGPoint, _ x: CGFloat, _ y: CGFloat, _ tolerance: CGFloat = 1e-6) -> Bool {
    near(point, CGPoint(x: x, y: y), tolerance)
}

public func near(_ a: CGSize, _ b: CGSize, _ tolerance: CGFloat = 1e-6) -> Bool {
    near(a.width, b.width, tolerance) && near(a.height, b.height, tolerance)
}

public func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 1e-6) -> Bool {
    near(a.origin, b.origin, tolerance) && near(a.size, b.size, tolerance)
}
