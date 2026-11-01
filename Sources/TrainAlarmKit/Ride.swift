import Foundation

/// A station as referenced by tickets and timetables. `key` is the IPWS station key when known.
public struct Station: Sendable, Hashable {
    public var key: Int?
    public var name: String

    public init(key: Int? = nil, name: String) {
        self.key = key
        self.name = name
    }

    /// Same station by key, or by name ignoring case, diacritics and spacing.
    public func matches(key otherKey: Int?, name otherName: String) -> Bool {
        if let key, let otherKey { return key == otherKey }
        return Self.fold(name) == Self.fold(otherName)
    }

    static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "cs_CZ"))
            .filter { !$0.isWhitespace }
    }
}

/// One train ride within a trip, as printed on a ticket (scheduled times only).
public struct Leg: Sendable, Hashable {
    public var trainType: String
    public var trainNumber: String
    public var trainName: String?
    public var from: Station
    public var to: Station
    public var departure: Date
    public var arrival: Date

    public init(trainType: String, trainNumber: String, trainName: String? = nil, from: Station, to: Station, departure: Date, arrival: Date) {
        self.trainType = trainType
        self.trainNumber = trainNumber
        self.trainName = trainName
        self.from = from
        self.to = to
        self.departure = departure
        self.arrival = arrival
    }

    /// "Sp 1555"
    public var title: String { "\(trainType) \(trainNumber)" }
}

/// One direction of a ticket: legs in travel order.
public struct Trip: Sendable, Hashable {
    public var legs: [Leg]

    public init(legs: [Leg]) {
        self.legs = legs.sorted { $0.departure < $1.departure }
    }

    public var departure: Date { legs.first?.departure ?? .distantPast }
    public var arrival: Date { legs.last?.arrival ?? .distantPast }

    /// Trips worth showing at `now`, most relevant first: anything not finished long ago,
    /// ordered by departure, so an in-progress trip wins over a later one.
    public static func relevant(_ trips: some Sequence<Trip>, at now: Date, grace: TimeInterval = 3 * 3600) -> [Trip] {
        Set(trips)
            .filter { !$0.legs.isEmpty && $0.arrival.addingTimeInterval(grace) >= now }
            .sorted { $0.departure < $1.departure }
    }

    /// Index of the leg the passenger is on or waiting for at `now`.
    public func activeLegIndex(at now: Date) -> Int {
        legs.firstIndex { now < $0.arrival.addingTimeInterval(10 * 60) } ?? legs.count - 1
    }
}

/// The train you are on (or about to board), with live data when available.
public struct Ride: Sendable, Equatable {
    public struct Stop: Sendable, Equatable, Identifiable {
        public let id: Int
        public var name: String
        public var arrival: Date?
        public var departure: Date?
        public var platform: String?

        public init(id: Int, name: String, arrival: Date? = nil, departure: Date? = nil, platform: String? = nil) {
            self.id = id
            self.name = name
            self.arrival = arrival
            self.departure = departure
            self.platform = platform
        }

        /// The time a passenger cares about at this stop.
        public var scheduled: Date? { departure ?? arrival }
    }

    public enum Source: Sendable, Equatable {
        case ceskeDrahy
        case idos
    }

    /// Where the train is relative to the passenger's boarding and alighting stops.
    public enum Phase: Sendable, Equatable {
        case waiting(departure: Date)
        case onboard(arrival: Date, nextStop: Int)
        case arrived
    }

    /// "Sp 1555"
    public var train: String
    /// Marketing name, e.g. "Jizera".
    public var trainName: String?
    /// Boarding stop first, alighting stop last.
    public var stops: [Stop]
    /// Live delay in minutes; `nil` when no live data is available.
    public var delay: Int?
    /// Last reported position, e.g. "Praha-Vysočany".
    public var position: String?
    /// Next stop reported by live data, as an index into `stops` (`stops.count` = past the last stop).
    public var reportedNextStop: Int?
    /// Connections after this train within the same trip.
    public var onward: [Leg]
    public var source: Source

    public init(
        train: String,
        trainName: String? = nil,
        stops: [Stop],
        delay: Int? = nil,
        position: String? = nil,
        reportedNextStop: Int? = nil,
        onward: [Leg] = [],
        source: Source
    ) {
        self.train = train
        self.trainName = trainName
        self.stops = stops
        self.delay = delay
        self.position = position
        self.reportedNextStop = reportedNextStop
        self.onward = onward
        self.source = source
    }

    public var origin: Stop? { stops.first }
    public var destination: Stop? { stops.last }

    /// Scheduled time shifted by the live delay.
    public func expected(_ date: Date?) -> Date? {
        date?.addingTimeInterval(TimeInterval((delay ?? 0) * 60))
    }

    public var expectedDeparture: Date? { expected(origin?.departure ?? origin?.arrival) }
    public var expectedArrival: Date? { expected(destination?.arrival ?? destination?.departure) }

    /// Index of the next stop the train will reach, or `nil` once it reached the destination.
    /// Prefers the live position; falls back to the (delay-adjusted) timetable.
    public func nextStopIndex(at now: Date) -> Int? {
        let index = reportedNextStop ?? stops.firstIndex { stop in
            guard let time = expected(stop.scheduled) else { return false }
            return time > now
        } ?? stops.count
        return index < stops.count ? index : nil
    }

    public func phase(at now: Date) -> Phase {
        guard let next = nextStopIndex(at: now) else { return .arrived }
        if next == 0, let departure = expectedDeparture {
            return .waiting(departure: departure)
        }
        guard let arrival = expectedArrival else { return .arrived }
        return .onboard(arrival: arrival, nextStop: max(next, 1))
    }
}
