import Foundation
import Testing
@testable import PlatformSync

@MainActor
struct SyncUpdatesTests {
    @Test func readsTheKeysAsPostedOrAsASet() {
        let posted = Notification(name: ICloudSyncManager.didUpdateLocalData, object: nil,
                                  userInfo: [ICloudSyncManager.updatedKeysUserInfoKey: ["a", "b", "a"]])
        #expect(ICloudSyncManager.updatedKeys(in: posted) == ["a", "b"])
        let asSet = Notification(name: ICloudSyncManager.didUpdateLocalData, object: nil,
                                 userInfo: [ICloudSyncManager.updatedKeysUserInfoKey: Set(["c"])])
        #expect(ICloudSyncManager.updatedKeys(in: asSet) == ["c"])
        #expect(ICloudSyncManager.updatedKeys(in: Notification(name: .init("other"))).isEmpty)
    }

    @Test func observersHearEachUpdateUntilRemoved() async {
        var heard: [Set<String>] = []
        let token = ICloudSyncManager.observeUpdates { heard.append($0) }
        func post(_ keys: [String]) {
            NotificationCenter.default.post(name: ICloudSyncManager.didUpdateLocalData, object: nil,
                                            userInfo: [ICloudSyncManager.updatedKeysUserInfoKey: keys])
        }
        post(["settings.sound"])
        // The observer runs on the main queue: let it.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        NotificationCenter.default.removeObserver(token)
        post(["settings.music"])
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(heard == [["settings.sound"]])
    }
}
