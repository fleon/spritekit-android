import Foundation

/// `-SafeAreaInsets top,left,bottom,right`, in points: a debug launch
/// argument of the Android port's alone, which has the game laid out within
/// those insets instead of the device's (`AndroidGameController.layout`), so
/// a parity run can give the emulator an iPhone's safe area as well as its
/// screen (`Tools/Capture/parity.js`). Release builds never read it.
public struct SafeAreaOverride: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let argument = "SafeAreaInsets"

    /// Four numbers, none negative, separated by commas; anything else is
    /// no override.
    public static func parse(_ text: String?) -> SafeAreaOverride? {
        guard let text else { return nil }
        let values = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 4, values.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let points = values.compactMap { $0 }.map { CGFloat($0) }
        return SafeAreaOverride(top: points[0], left: points[1], bottom: points[2], right: points[3])
    }
}
