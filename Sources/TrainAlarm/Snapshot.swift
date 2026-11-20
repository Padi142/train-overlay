#if DEBUG
import AppKit
import SwiftUI
import TrainAlarmKit

/// Renders the README screenshots with sample data and exits:
/// `TRAINALARM_SNAPSHOTS=docs/screenshots swift run`
@MainActor
enum Snapshot {
    static func renderIfRequested() {
        guard let directory = ProcessInfo.processInfo.environment["TRAINALARM_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let now = Date.now
        let ride = sampleRide(now: now)
        for scheme in [ColorScheme.light, .dark] {
            render(window(ride: ride, connectivity: .online, now: now), scheme: scheme,
                   to: output.appending(path: "ride-\(scheme == .light ? "light" : "dark").png"))
        }
        render(connectionStates(ride: ride, now: now), scheme: .light, to: output.appending(path: "connection-states.png"))
        exit(0)
    }

    /// The menu bar window as the app shows it.
    private static func window(ride: Ride, connectivity: Connectivity, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RideView(ride: ride, now: now).padding(16)
            Divider()
            footer(connectivity: connectivity, now: now)
        }
        .frame(width: 340)
    }

    private static func footer(connectivity: Connectivity, now: Date) -> some View {
        WindowFooter(
            status: "Můj vlak · updated \(now.clockTime)",
            connectivity: connectivity,
            isRefreshing: false,
            onRefresh: {},
            staticControls: true
        ) { EmptyView() }
    }

    /// Each connection state as seen in the menu bar and in the window footer.
    private static func connectionStates(ride: Ride, now: Date) -> some View {
        let states: [(String, Connectivity)] = [
            ("Online", .online),
            ("Offline", .offline(since: now.addingTimeInterval(-90))),
            ("Recovering", .recovering(since: now.addingTimeInterval(-4))),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(states, id: \.0) { title, connectivity in
                HStack(spacing: 16) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    MenuBarLabel(ride: ride, connectivity: connectivity, now: now)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(white: 0.12), in: Capsule())
                        .frame(width: 110)
                    footer(connectivity: connectivity, now: now)
                        .frame(width: 340)
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                }
            }
        }
        .padding(16)
    }

    private static func render(_ view: some View, scheme: ColorScheme, to url: URL) {
        let content = view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { fatalError("Snapshot rendering failed for \(url.lastPathComponent)") }
        try! png.write(to: url)
    }

    private static func sampleRide(now: Date) -> Ride {
        let minute: TimeInterval = 60
        func stop(_ id: Int, _ name: String, _ offset: Double, platform: String? = nil) -> Ride.Stop {
            let time = now.addingTimeInterval(offset * minute)
            return Ride.Stop(id: id, name: name, arrival: time, departure: time, platform: platform)
        }
        return Ride(
            train: "Sp 1555",
            trainName: "Jizera",
            stops: [
                stop(0, "Mladá Boleslav hl.n.", -27, platform: "2"),
                stop(1, "Chotětov", -16),
                stop(2, "Kropáčova Vrutice", -6),
                stop(3, "Košátky", -4),
                stop(4, "Všetaty", 7),
                stop(5, "Neratovice", 15),
                stop(6, "Praha-Vysočany", 40),
                stop(7, "Praha hl.n.", 48, platform: "1B"),
            ],
            delay: 3,
            position: "Košátky",
            reportedNextStop: 4,
            onward: [Leg(
                trainType: "R", trainNumber: "886",
                from: Station(name: "Praha hl.n."), to: Station(name: "Praha-Vršovice"),
                departure: now.addingTimeInterval(62 * minute), arrival: now.addingTimeInterval(66 * minute)
            )],
            source: .ceskeDrahy
        )
    }
}
#endif
