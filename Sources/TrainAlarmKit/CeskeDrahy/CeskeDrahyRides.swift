import Foundation

/// Finds your current (or next) ride from the tickets on a Můj vlak account and
/// enriches it with the live position and delay of the train.
public actor CeskeDrahyRides {
    private let client: IpwsClient
    /// Resolved train runs per leg, so refreshes skip the train search.
    private var runs: [Leg: TrainRun] = [:]

    private struct TrainRun {
        let train: IpwsTrainInfo
        let combinationID: String
        let day: Date
    }

    public init(client: IpwsClient) {
        self.client = client
    }

    /// The trip in progress or the next upcoming one, as a `Ride` for its active leg.
    /// Returns `nil` when the account has no relevant tickets.
    public func currentRide(at now: Date = .now) async throws -> Ride? {
        let trips = Self.trips(from: try await client.tickets())
        for trip in Trip.relevant(trips, at: now) {
            let index = trip.activeLegIndex(at: now)
            let ride = await ride(for: trip.legs[index], onward: Array(trip.legs[(index + 1)...]))
            // A delayed train may still be running after its scheduled arrival; once it is
            // in (plus a moment to get off), move on to the next trip.
            let isLastLeg = index == trip.legs.count - 1
            if isLastLeg, let arrival = ride.expectedArrival, arrival.addingTimeInterval(15 * 60) < now {
                continue
            }
            return ride
        }
        return nil
    }

    /// Ticket directions (`aoThere`, `aoBack`) as trips. Refunded tickets and legs
    /// without times are skipped.
    static func trips(from tickets: [IpwsTicket]) -> [Trip] {
        tickets
            .filter { ($0.sReturnReason ?? "").isEmpty }
            .flatMap { [$0.aoThere, $0.aoBack] }
            .compactMap { trains in
                let legs = (trains ?? []).compactMap(Self.leg)
                return legs.isEmpty ? nil : Trip(legs: legs)
            }
    }

    private static func leg(from train: IpwsTicketTrain) -> Leg? {
        guard
            let number = train.sTrainNum, !number.isEmpty,
            let from = train.oFrom, let fromName = from.sStationName,
            let to = train.oTo, let toName = to.sStationName,
            let departure = from.dtTime.flatMap(IpwsTime.decode),
            let arrival = to.dtTime.flatMap(IpwsTime.decode)
        else { return nil }

        return Leg(
            trainType: train.sTrainType ?? "",
            trainNumber: number,
            trainName: train.sTrainName.flatMap { $0.isEmpty ? nil : $0 },
            from: Station(key: from.iStationKey, name: fromName),
            to: Station(key: to.iStationKey, name: toName),
            departure: departure,
            arrival: arrival
        )
    }

    // MARK: Live data

    /// Live ride for a leg; falls back to the ticket's scheduled times when the train
    /// can't be found or the live service fails.
    private func ride(for leg: Leg, onward: [Leg]) async -> Ride {
        do {
            if let data = try await trainData(for: leg), let ride = Self.ride(for: leg, data: data, onward: onward) {
                return ride
            }
        } catch {
            runs[leg] = nil
        }
        return Self.scheduledRide(for: leg, onward: onward)
    }

    private func trainData(for leg: Leg) async throws -> IpwsTrainData? {
        if let run = runs[leg] {
            return try await client.trainData(run.train, combinationID: run.combinationID, stationKey: leg.from.key, day: run.day)
        }
        // Night trains may have started their run the day before you board.
        let days = [leg.departure, leg.departure.addingTimeInterval(-86_400)]
        for day in days {
            let search = try await client.searchTrains(number: leg.trainNumber, day: day)
            // The search matches numbers worldwide; same-type trains go first.
            let typeRank = { (train: IpwsTrainInfo) in
                train.sType?.caseInsensitiveCompare(leg.trainType) == .orderedSame ? 0 : 1
            }
            let candidates = (search.aoTrain ?? [])
                .filter { $0.sNum1 == leg.trainNumber }
                .sorted { typeRank($0) < typeRank($1) }
                .prefix(3)
            for train in candidates {
                let data = try await client.trainData(train, combinationID: search.sCombID, stationKey: leg.from.key, day: day)
                if Self.routeRange(of: leg, in: data.aoRoute ?? []) != nil {
                    runs[leg] = TrainRun(train: train, combinationID: search.sCombID, day: day)
                    return data
                }
            }
        }
        return nil
    }

    /// Indices of the boarding and alighting stops within a train's route.
    static func routeRange(of leg: Leg, in route: [IpwsRouteStop]) -> ClosedRange<Int>? {
        guard let start = route.firstIndex(where: { leg.from.matches(key: $0.iKey, name: $0.sStationName) }),
              let end = route[start...].lastIndex(where: { leg.to.matches(key: $0.iKey, name: $0.sStationName) }),
              end > start
        else { return nil }
        return start...end
    }

    static func ride(for leg: Leg, data: IpwsTrainData, onward: [Leg]) -> Ride? {
        let route = data.aoRoute ?? []
        guard let range = routeRange(of: leg, in: route) else { return nil }

        let stops = route[range].enumerated().map { offset, stop in
            Ride.Stop(
                id: offset,
                name: stop.sStationName,
                arrival: stop.dtArrTime.flatMap(IpwsTime.decode),
                departure: stop.dtDepTime.flatMap(IpwsTime.decode),
                platform: stop.sStand.flatMap(Self.platform)
            )
        }

        // Live data only exists once the train is dispatched. `iNextStation` indexes the
        // full route; 0 means "not moving yet", so it is left to the timetable.
        let position = data.aoTrainPos?.first.flatMap { $0.bNotDispatched == true ? nil : $0 }
        let nextStop = position?.iNextStation.flatMap { next in
            next > 0 ? min(max(next - range.lowerBound, 0), stops.count) : nil
        }

        return Ride(
            train: leg.title,
            trainName: data.sNum2 ?? leg.trainName,
            stops: stops,
            delay: position?.iDelay,
            position: position?.sPosition,
            reportedNextStop: nextStop,
            onward: onward,
            source: .ceskeDrahy
        )
    }

    static func scheduledRide(for leg: Leg, onward: [Leg]) -> Ride {
        Ride(
            train: leg.title,
            trainName: leg.trainName,
            stops: [
                Ride.Stop(id: 0, name: leg.from.name, departure: leg.departure),
                Ride.Stop(id: 1, name: leg.to.name, arrival: leg.arrival),
            ],
            onward: onward,
            source: .ceskeDrahy
        )
    }

    /// "Nást. 1B" → "1B", "Kolej 5" → "5".
    static func platform(_ stand: String) -> String? {
        let trimmed = stand.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for prefix in ["Nást.", "Kolej", "Kol."] where trimmed.hasPrefix(prefix) {
            return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}
