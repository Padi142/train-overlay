import SwiftUI
import TrainAlarmKit

@main
struct TrainAlarmApp: App {
    @State private var store: RideStore

    init() {
        #if DEBUG
        Snapshot.renderIfRequested()
        #endif
        _store = State(initialValue: RideStore())
        // Menu bar only, also when launched outside an app bundle (`swift run`).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            MenuBarLabel(ride: store.ride, now: store.now)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Train icon, plus a countdown while a departure or arrival is coming up.
struct MenuBarLabel: View {
    let ride: Ride?
    let now: Date

    // The status item drops images interpolated into `Text`; an HStack keeps the icon.
    var body: some View {
        switch ride?.phase(at: now) {
        case .waiting(let departure) where departure.timeIntervalSince(now) < 3 * 3600:
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(Countdown(until: departure, from: now).text)
            }
        case .onboard(let arrival, _):
            HStack(spacing: 4) {
                Image(systemName: "train.side.front.car")
                Text(Countdown(until: arrival, from: now).text)
            }
        default:
            Image(systemName: "train.side.front.car")
        }
    }
}
