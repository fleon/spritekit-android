import Foundation
import Testing
@testable import PlatformSync

/// The shared manager's cloud: a game kept off the platform's cloud sets its
/// own before anything reads it, and the platform's is then never made
/// (making iCloud's store starts it syncing).
@Suite("The shared manager's cloud", .serialized)
struct SharedCloudTests {
    @Test("A cloud set first is the one used, and the platform's own is never made")
    func setFirst() {
        var made = 0
        ICloudSyncManager.makeDefaultCloud = {
            made += 1
            return LocalOnlyCloud()
        }
        let own = MemoryCloud()
        ICloudSyncManager.cloud = own
        #expect(ICloudSyncManager.cloud === own)
        _ = ICloudSyncManager.shared
        #expect(made == 0)
    }
}
