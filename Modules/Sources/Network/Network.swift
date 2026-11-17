// Stands in for Network on Android, for the one file that imports it: the
// beta's solve log (`PlaytestLog`), which records how the device reaches
// the internet as TestFlight's feedback does. The platform services ask
// Android's ConnectivityManager (`SystemServices.connection`,
// `DeviceServices.java`) whenever the path is read. Comes out with the
// solve log.
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
