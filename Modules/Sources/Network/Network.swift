// Stands in for Network on Android, as far as asking how the device reaches
// the internet goes. The app's platform services ask Android's
// ConnectivityManager (`SystemServices.connection`) whenever the path is
// read.
import Dispatch
import Foundation
import SpriteKitShim

public final class NWPathMonitor: @unchecked Sendable {
    public init() {}

    /// Nothing to watch: the path is asked for as it's read.
    public func start(queue: DispatchQueue) {}

    public var currentPath: NWPath { NWPath(kind: SystemServices.connection()) }
}

public struct NWPath: Sendable {
    public enum Status: Sendable {
        case satisfied, unsatisfied, requiresConnection
    }

    /// `wifi`, `cellular`, `wired`, `other` or `none`; nil where it can't be told.
    private let kind: String?

    init(kind: String?) {
        self.kind = kind
    }

    public var status: Status { kind == "none" ? .unsatisfied : .satisfied }

    public func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool {
        switch type {
        case .wifi: return kind == "wifi"
        case .cellular: return kind == "cellular"
        case .wiredEthernet: return kind == "wired"
        case .loopback, .other: return false
        }
    }
}

public enum NWInterface {
    public enum InterfaceType: Sendable {
        case wifi, cellular, wiredEthernet, loopback, other
    }
}
