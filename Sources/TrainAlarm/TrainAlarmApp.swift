import SwiftUI
import TrainAlarmKit

@main
struct TrainAlarmApp: App {
    @State private var store: RideStore
    @State private var connectivity: ConnectivityMonitor

    init() {
        #if DEBUG
        Snapshot.renderIfRequested()
        #endif
        let store = RideStore()
        _store = State(initialValue: store)
        // Data fetched while offline is stale or missing; catch up once the connection is solid.
        _connectivity = State(initialValue: ConnectivityMonitor { Task { await store.refresh() } })
        // Menu bar only, also when launched outside an app bundle (`swift run`).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store, connectivity: connectivity.state)
        } label: {
            MenuBarLabel(ride: store.ride, connectivity: connectivity.state, now: store.now)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Train icon, plus a countdown while a departure or arrival is coming up.
/// While the connection is down or recovering, its symbol replaces the icon.
struct MenuBarLabel: View {
    let ride: Ride?
    let connectivity: Connectivity
    let now: Date

    // The status item shows one image and one title: images interpolated into `Text`
    // are dropped, so this is always an HStack of at most one Image and one Text.
    var body: some View {
        switch ride?.phase(at: now) {
        case .waiting(let departure) where departure.timeIntervalSince(now) < 3 * 3600:
            HStack(spacing: 4) {
                Image(systemName: connectivity.symbol ?? "clock")
                Text(Countdown(until: departure, from: now).text)
            }
        case .onboard(let arrival, _):
            HStack(spacing: 4) {
                Image(systemName: connectivity.symbol ?? "train.side.front.car")
                Text(Countdown(until: arrival, from: now).text)
            }
        default:
            Image(systemName: connectivity.symbol ?? "train.side.front.car")
        }
    }
}
