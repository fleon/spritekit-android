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
        for _ in 0 ..< 200 where heard.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        NotificationCenter.default.removeObserver(token)
        post(["settings.music"])
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(heard == [["settings.sound"]])
    }
}
