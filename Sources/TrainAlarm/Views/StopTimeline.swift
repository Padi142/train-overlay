import SwiftUI
import TrainAlarmKit

/// Vertical rail of stops between boarding and alighting. Passed stops fade out,
/// the next stop is highlighted and kept in view.
struct StopTimeline: View {
    let ride: Ride
    /// Index of the next stop; `ride.stops.count` once arrived.
    let nextStop: Int

    private static let rowHeight: CGFloat = 26
    private static let visibleRows = 9

    var body: some View {
        if ride.stops.count <= Self.visibleRows {
            rows
        } else {
            ScrollViewReader { proxy in
                ScrollView { rows }
                    .scrollIndicators(.never)
                    .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight)
                    .onAppear { scroll(proxy) }
                    .onChange(of: nextStop) { scroll(proxy) }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(ride.stops) { stop in
                row(stop).id(stop.id)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        // Keep one passed stop visible above the next one for context.
        proxy.scrollTo(max(nextStop - 1, 0), anchor: .top)
    }

    private func row(_ stop: Ride.Stop) -> some View {
        let index = stop.id
        let isPassed = index < nextStop
        let isNext = index == nextStop
        let isEndpoint = index == 0 || index == ride.stops.count - 1
        let time = isPassed ? stop.scheduled : ride.expected(stop.scheduled)
        let isLate = !isPassed && (ride.delay ?? 0) > 0

        return HStack(spacing: 10) {
            Text(time?.clockTime ?? "")
                .font(.system(size: 12, weight: isNext ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isPassed ? AnyShapeStyle(.tertiary) : isLate ? AnyShapeStyle(ride.delayTint) : AnyShapeStyle(.primary))
                .frame(width: 38, alignment: .trailing)

            rail(index: index, isPassed: isPassed, isNext: isNext)

            Text(stop.name)
                .font(.system(size: 13, weight: isNext || isEndpoint ? .semibold : .regular))
                .foregroundStyle(isPassed ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let platform = stop.platform {
                Text(platform)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(height: Self.rowHeight)
    }

    private func rail(index: Int, isPassed: Bool, isNext: Bool) -> some View {
        let traveled = AnyShapeStyle(Color.accentColor)
        let ahead = AnyShapeStyle(.quaternary)
        return ZStack {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(index <= nextStop ? traveled : ahead)
                    .opacity(index == 0 ? 0 : 1)
                Rectangle()
                    .fill(index < nextStop ? traveled : ahead)
                    .opacity(index == ride.stops.count - 1 ? 0 : 1)
            }
            .frame(width: 2)

            if isNext {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .background(Circle().fill(.background))
                    .frame(width: 11, height: 11)
            } else if isPassed {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            } else {
                Circle()
                    .strokeBorder(.tertiary, lineWidth: 1.5)
                    .background(Circle().fill(.background))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 12)
    }
}
