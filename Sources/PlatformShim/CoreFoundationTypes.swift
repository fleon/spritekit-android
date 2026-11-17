#if !canImport(Darwin)
import Foundation

// Two CoreFoundation calls, which corelibs keeps to itself: code writing
// canonical JSON tells a JSON `true` from a `1` by asking whether an
// `NSNumber` is a `CFBoolean`, so it writes `true` as Apple's does.

public typealias CFTypeID = UInt

/// The id `CFGetTypeID` gives a boolean (CoreFoundation's own number for it).
public func CFBooleanGetTypeID() -> CFTypeID { 21 }

/// `CFBooleanGetTypeID()` for an `NSNumber` holding a boolean, else 0. In
/// corelibs, as on Apple, a boolean `NSNumber` is one of two shared
/// `CFBoolean`s (`__NSCFBoolean`), whatever made it (`NSNumber(value:)`,
/// `JSONSerialization`, a bridged `Bool`), while a number of 1 is not.
public func CFGetTypeID(_ object: AnyObject?) -> CFTypeID {
    guard let number = object as? NSNumber else { return 0 }
    return isBoolean(number) ? CFBooleanGetTypeID() : 0
}

private let booleans = (NSNumber(value: true), NSNumber(value: false))

private func isBoolean(_ number: NSNumber) -> Bool {
    number === booleans.0 || number === booleans.1 || String(describing: type(of: number)) == "__NSCFBoolean"
}
#endif
