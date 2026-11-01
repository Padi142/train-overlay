import SwiftUI
import TrainAlarmKit

/// The current ride: train, countdown, progress, stops and onward connections.
struct RideView: View {
    let ride: Ride
    let now: Date

    var body: some View {
        let phase = ride.phase(at: now)
        VStack(alignment: .leading, spacing: 16) {
            header
            hero(phase)
            StopTimeline(ride: ride, nextStop: ride.nextStopIndex(at: now) ?? ride.stops.count)
            if !ride.onward.isEmpty {
                onward
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ride.train)
                        .font(.system(size: 15, weight: .semibold))
                    if let name = ride.trainName {
                        Text(name)
                            .foregroundStyle(.secondary)
                    }
                }
                if let origin = ride.origin, let destination = ride.destination {
                    Text("\(origin.name) → \(destination.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            DelayBadge(ride: ride)
        }
    }

    private func hero(_ phase: Ride.Phase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    switch phase {
                    case .waiting(let departure):
                        countdown(until: departure)
                        Text("until departure").foregroundStyle(.secondary)
                    case .onboard(let arrival, _):
                        countdown(until: arrival)
                        Text("until arrival").foregroundStyle(.secondary)
                    case .arrived:
                        Text("Arrived")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                    }
                }
                Spacer()
                // Time and platform of whichever end of the ride is coming up.
                let isWaiting = if case .waiting = phase { true } else { false }
                let stop = isWaiting ? ride.origin : ride.destination
                VStack(alignment: .trailing, spacing: 2) {
                    if let time = isWaiting ? ride.expectedDeparture : ride.expectedArrival {
                        Text(time.clockTime)
                            .font(.system(size: 15, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(ride.delay ?? 0 > 0 ? ride.delayTint : .primary)
                    }
                    if let platform = stop?.platform {
                        Text("Platform \(platform)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }

            if case .onboard = phase {
                JourneyProgress(ride: ride, now: now)
            }

            if let position = ride.position {
                Label(position, systemImage: "location.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func countdown(until date: Date) -> some View {
        let countdown = Countdown(until: date, from: now)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(countdown.value)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(countdown.unit)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var onward: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ride.onward, id: \.self) { leg in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.secondary)
                    Text(leg.title).fontWeight(.medium)
                    Text("from \(leg.from.name)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(leg.departure.clockTime).monospacedDigit()
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DelayBadge: View {
    let ride: Ride

    var body: some View {
        if let delay = ride.delay {
            Text(delay > 0 ? "+\(delay) min" : "On time")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(ride.delayTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ride.delayTint.opacity(0.15), in: Capsule())
        }
    }
}

/// Thin bar from departure to arrival.
struct JourneyProgress: View {
    let ride: Ride
    let now: Date

    private var fraction: Double {
        guard let start = ride.expectedDeparture, let end = ride.expectedArrival, end > start else { return 0 }
        return min(max(now.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(geometry.size.width * fraction, 4))
            }
        }
        .frame(height: 4)
        .animation(.easeInOut, value: fraction)
    }
}
