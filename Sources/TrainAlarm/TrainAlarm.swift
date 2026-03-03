import AppKit
import SwiftUI

struct TrainStop: Identifiable {
    let id = UUID()
    let station: String
    let scheduledTime: String
    let liveTime: String
}

struct JourneySnapshot {
    let trainLine: String
    let fromStation: String
    let toStation: String
    let boardingTime: String
    let scheduledArrival: String
    let liveArrival: String
    let delayMinutes: Int
    let occupancyHint: String
    let platform: String
    let stops: [TrainStop]

    static let mock = JourneySnapshot(
        trainLine: "EC 241 Baltic Express",
        fromStation: "Praha hl.n.",
        toStation: "Brno hl.n.",
        boardingTime: "14:18",
        scheduledArrival: "16:56",
        liveArrival: "17:09",
        delayMinutes: 13,
        occupancyHint: "Medium occupancy",
        platform: "Platform 4",
        stops: [
            TrainStop(station: "Kolin", scheduledTime: "14:52", liveTime: "15:02"),
            TrainStop(station: "Pardubice", scheduledTime: "15:18", liveTime: "15:31"),
            TrainStop(station: "Ceska Trebova", scheduledTime: "15:52", liveTime: "16:06"),
            TrainStop(station: "Blansko", scheduledTime: "16:44", liveTime: "16:58")
        ]
    )
}

@main
struct TrainAlarmApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Train Alarm", systemImage: "tram.fill") {
            JourneyMenuView(snapshot: .mock)
                .frame(width: 380, height: 520)
        }
        .menuBarExtraStyle(.window)
    }
}

struct JourneyMenuView: View {
    let snapshot: JourneySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderCard(snapshot: snapshot)
            RouteCard(snapshot: snapshot)

            Text("Upcoming Stops")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(snapshot.stops) { stop in
                        StopRow(stop: stop)
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(height: 220)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.11, blue: 0.17),
                    Color(red: 0.03, green: 0.07, blue: 0.13)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

struct HeaderCard: View {
    let snapshot: JourneySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(snapshot.trainLine, systemImage: "train.side.front.car")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                DelayBadge(delayMinutes: snapshot.delayMinutes)
            }

            HStack(spacing: 16) {
                StatChip(title: "Boarding", value: snapshot.boardingTime, symbol: "person.crop.circle.badge.checkmark")
                StatChip(title: "Arrival", value: snapshot.liveArrival, symbol: "clock.badge.checkmark")
                StatChip(title: "Platform", value: snapshot.platform, symbol: "signpost.right")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.19, green: 0.35, blue: 0.59),
                            Color(red: 0.15, green: 0.24, blue: 0.44)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

struct RouteCard: View {
    let snapshot: JourneySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.fromStation)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("to \(snapshot.toStation)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer()

                Text(snapshot.occupancyHint)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .foregroundStyle(.white)
            }

            Divider().overlay(Color.white.opacity(0.15))

            HStack {
                Text("Scheduled: \(snapshot.scheduledArrival)")
                Spacer()
                Text("Live: \(snapshot.liveArrival)")
                    .foregroundStyle(Color(red: 0.58, green: 0.95, blue: 0.76))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.82))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

struct StopRow: View {
    let stop: TrainStop

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(Color(red: 0.63, green: 0.82, blue: 0.98))
                .frame(width: 16)

            Text(stop.station)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(stop.liveTime)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("sched \(stop.scheduledTime)")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}

struct DelayBadge: View {
    let delayMinutes: Int

    var body: some View {
        Text("+\(delayMinutes)m")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(red: 1.0, green: 0.91, blue: 0.58))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.28))
            )
    }
}

struct StatChip: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .opacity(0.75)
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
    }
}
