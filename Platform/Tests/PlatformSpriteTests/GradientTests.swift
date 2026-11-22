import Foundation
import Testing
import SpriteKitShim
@testable import PlatformSprite

struct GradientStopTests {
    @Test func keyNamesEveryColourAndPlace() {
        let stops = [GradientStop(0, hex(0xFF0000)), GradientStop(0.5, hex(0x00FF00).withAlphaComponent(0.5))]
        #expect(stops.cacheKey == "ff0000ff@0.0000;00ff007f@0.5000")
        #expect(stops.cacheKey != [GradientStop(0, hex(0xFF0000)), GradientStop(0.6, hex(0x00FF00).withAlphaComponent(0.5))].cacheKey)
    }
}
