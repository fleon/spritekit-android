import Foundation
import PlatformShim
import Testing

/// `-SafeAreaInsets`, which a parity run gives the emulator so it lays the
/// game out within an iPhone's safe area.
@Suite struct SafeAreaOverrideTests {
    @Test func fourPointsInUIEdgeInsetsOrder() {
        #expect(SafeAreaOverride.parse("62,0,34,0") == SafeAreaOverride(top: 62, left: 0, bottom: 34, right: 0))
        #expect(SafeAreaOverride.parse(" 0, 62 ,21,62") == SafeAreaOverride(top: 0, left: 62, bottom: 21, right: 62))
        #expect(SafeAreaOverride.parse("0,0,0,0.5") == SafeAreaOverride(top: 0, left: 0, bottom: 0, right: 0.5))
    }

    @Test func anythingElseIsNoOverride() {
        for text in [nil, "", "62,0,34", "62,0,34,0,1", "a,b,c,d", "62,-1,34,0", "62;0;34;0"] as [String?] {
            #expect(SafeAreaOverride.parse(text) == nil, "\(text ?? "nil")")
        }
    }
}
