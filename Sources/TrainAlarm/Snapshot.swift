#if DEBUG
import AppKit
import SwiftUI
import TrainAlarmKit

/// Renders the ride view with sample data to a PNG and exits — used for the README screenshot:
/// `TRAINALARM_SNAPSHOT=image.png swift run`
@MainActor
enum Snapshot {
    static func renderIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["TRAINALARM_SNAPSHOT"] else { return }
        let now = Date.now
        let minute: TimeInterval = 60
        func stop(_ id: Int, _ name: String, _ offset: Double, platform: String? = nil) -> Ride.Stop {
            let time = now.addingTimeInterval(offset * minute)
            return Ride.Stop(id: id, name: name, arrival: time, departure: time, platform: platform)
        }
        let ride = Ride(
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

        let view = RideView(ride: ride, now: now)
            .padding(16)
            .frame(width: 340)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, ProcessInfo.processInfo.environment["TRAINALARM_DARK"] == nil ? .light : .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { fatalError("Snapshot rendering failed") }
        try! png.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
#endif
