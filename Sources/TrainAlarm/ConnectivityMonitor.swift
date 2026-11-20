import Foundation
import Observation
import SwiftUI
import TrainAlarmKit

/// Probes the internet on the schedule `ConnectivityMachine` dictates and publishes the state.
@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var state: Connectivity = .online

    @ObservationIgnored private var machine = ConnectivityMachine()
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// - Parameter onRecovered: called when the connection is back to fully online.
    init(onRecovered: @escaping @MainActor () -> Void) {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let success = await ConnectivityProbe.check()
                guard let self else { return }
                let wasOnline = self.state == .online
                let delay = self.machine.record(success: success, at: .now)
                self.state = self.machine.state
                if !wasOnline && self.state == .online { onRecovered() }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }
}

extension Connectivity {
    /// Status item symbol while the connection is degraded; `nil` when online.
    var symbol: String? {
        switch self {
        case .online: nil
        case .offline: "wifi.slash"
        case .recovering: "wifi.exclamationmark"
        }
    }

    var tint: Color {
        if case .offline = self { .red } else { .orange }
    }

    var label: String? {
        switch self {
        case .online: nil
        case .offline(let since): "Offline since \(since.clockTime)"
        case .recovering: "Connection recovering"
        }
    }
}
