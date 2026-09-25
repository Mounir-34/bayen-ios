import Foundation
import Network
import Observation

@MainActor
protocol NetworkStatusProviding: AnyObject {
    var isConnected: Bool { get }
}

/// Reachability via `NWPathMonitor`. `onReconnect` fires when the device goes from offline to online.
@MainActor
@Observable
final class NetworkMonitor: NetworkStatusProviding {
    private(set) var isConnected = true
    private(set) var isExpensive = false
    private(set) var isConstrained = false

    @ObservationIgnored var onReconnect: (() -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "ma.bayen.network-monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = connected
                self.isExpensive = expensive
                self.isConstrained = constrained
                if connected && !wasConnected { self.onReconnect?() }
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

/// Test double.
final class StaticNetworkStatus: NetworkStatusProviding {
    var isConnected: Bool
    init(isConnected: Bool = true) { self.isConnected = isConnected }
}
