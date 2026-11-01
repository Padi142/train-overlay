import Foundation
import Testing
@testable import TrainAlarmKit

/// Prague wall-clock date for readable expectations.
private func prague(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    IpwsTime.pragueCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(IpwsEnvelope<T>.self, from: Data(contentsOf: url)).d
}

@Suite struct IpwsTimeTests {
    @Test func wcfDateWithoutOffsetIsPragueWallClock() {
        // Sp 1555 arrives in Praha hl.n. at 17:31 local; the server sends 17:31 "UTC".
        #expect(IpwsTime.decode("/Date(1793554260000)/") == prague(2026, 11, 1, 17, 31))
    }

    @Test func wcfDateWithOffsetIsAnInstant() {
        #expect(IpwsTime.decode("/Date(1793554260000+0100)/") == Date(timeIntervalSince1970: 1_793_554_260))
    }

    @Test func isoWithoutZoneIsPragueWallClock() {
        #expect(IpwsTime.decode("2026-11-01T17:31:00") == prague(2026, 11, 1, 17, 31))
    }

    @Test func dayParameterUsesPragueCalendarDay() {
        // 00:30 in Prague is still the previous day in UTC.
        #expect(IpwsTime.dayParameter(prague(2026, 11, 2, 0, 30)) == "2026-11-02T00:00:00")
    }

    @Test func errorMessagesCarryTheirCode() {
        #expect(IpwsError.from(message: "10121 Zadali jste nesprávný e-mail nebo heslo.") == .invalidCredentials)
        #expect(IpwsError.from(message: "1005 Nepovolená kombinace.") == .server(code: 1005, message: "Nepovolená kombinace."))
    }
}

@Suite struct TicketTests {
    private let json = """
    {"d": {"aoUser": [
      {"sTransCode": "A1", "aoThere": [
        {"sTrainNum": "886", "sTrainType": "R", "sTrainName": "",
         "oFrom": {"iStationKey": 5457076, "sStationName": "Praha hl.n.", "dtTime": "/Date(1793633160000)/"},
         "oTo": {"iStationKey": 5453613, "sStationName": "Pardubice hl.n.", "dtTime": "/Date(1793638860000)/"}}
      ], "aoBack": null},
      {"sTransCode": "A2", "sReturnReason": "Vráceno", "aoThere": [
        {"sTrainNum": "1", "sTrainType": "EC",
         "oFrom": {"sStationName": "A", "dtTime": "/Date(1793633160000)/"},
         "oTo": {"sStationName": "B", "dtTime": "/Date(1793638860000)/"}}
      ]}
    ]}}
    """

    @Test func ticketsBecomeTripsAndRefundsAreSkipped() throws {
        let sync = try JSONDecoder().decode(IpwsEnvelope<IpwsTicketSync>.self, from: Data(json.utf8)).d
        let trips = CeskeDrahyRides.trips(from: sync.all)

        #expect(trips.count == 1)
        let leg = try #require(trips.first?.legs.first)
        #expect(leg.title == "R 886")
        #expect(leg.trainName == nil)
        #expect(leg.from == Station(key: 5457076, name: "Praha hl.n."))
        #expect(leg.departure == prague(2026, 11, 2, 15, 26))
    }
}

@Suite struct TripSelectionTests {
    private func leg(_ number: String, _ from: String, _ to: String, _ departure: Date, _ arrival: Date) -> Leg {
        Leg(trainType: "R", trainNumber: number, from: Station(name: from), to: Station(name: to), departure: departure, arrival: arrival)
    }

    @Test func inProgressTripWinsAndFinishedOnesDrop() {
        let morning = Trip(legs: [leg("1", "A", "B", prague(2026, 11, 1, 6, 0), prague(2026, 11, 1, 7, 0))])
        let current = Trip(legs: [
            leg("2", "A", "B", prague(2026, 11, 1, 17, 0), prague(2026, 11, 1, 17, 40)),
            leg("3", "B", "C", prague(2026, 11, 1, 17, 50), prague(2026, 11, 1, 18, 30)),
        ])
        let tomorrow = Trip(legs: [leg("4", "C", "A", prague(2026, 11, 2, 8, 0), prague(2026, 11, 2, 9, 0))])

        let now = prague(2026, 11, 1, 17, 20)
        #expect(Trip.relevant([tomorrow, morning, current], at: now) == [current, tomorrow])
        #expect(current.activeLegIndex(at: now) == 0)
        // Waiting for the connection after getting off the first train.
        #expect(current.activeLegIndex(at: prague(2026, 11, 1, 17, 52)) == 1)
    }
}

@Suite struct LiveRideTests {
    /// Boarding Sp 1555 in Mladá Boleslav while the live feed reports it near Praha hl.n.
    private func ride() throws -> Ride {
        let data = try fixture("train-sp1555", as: IpwsTrainData.self)
        let leg = Leg(
            trainType: "Sp", trainNumber: "1555",
            from: Station(key: 5454451, name: "Mladá Boleslav hl.n."),
            to: Station(key: 5457076, name: "Praha hl.n."),
            departure: prague(2026, 11, 1, 16, 9), arrival: prague(2026, 11, 1, 17, 31)
        )
        return try #require(CeskeDrahyRides.ride(for: leg, data: data, onward: []))
    }

    @Test func liveDataMapsOntoTheTicketedSection() throws {
        let ride = try ride()
        #expect(ride.train == "Sp 1555")
        #expect(ride.trainName == "Jizera")
        #expect(ride.stops.map(\.name).first == "Mladá Boleslav hl.n.")
        #expect(ride.stops.count == 13)
        #expect(ride.destination?.platform == "1B")
        #expect(ride.delay == 3)
        #expect(ride.position == "Balabenka odbočka")
        // iNextStation 19 in the full route = the last stop of our section.
        #expect(ride.reportedNextStop == 12)
        #expect(ride.expectedArrival == prague(2026, 11, 1, 17, 34))
    }

    @Test func phaseFollowsTheTrain() throws {
        var ride = try ride()
        #expect(ride.phase(at: prague(2026, 11, 1, 17, 30)) == .onboard(arrival: prague(2026, 11, 1, 17, 34), nextStop: 12))

        // Without live position the timetable (plus delay) decides.
        ride.reportedNextStop = nil
        #expect(ride.phase(at: prague(2026, 11, 1, 16, 0)) == .waiting(departure: prague(2026, 11, 1, 16, 12)))
        #expect(ride.phase(at: prague(2026, 11, 1, 17, 40)) == .arrived)
    }

    @Test func platformPrefixesAreStripped() {
        #expect(CeskeDrahyRides.platform("Nást. 1B") == "1B")
        #expect(CeskeDrahyRides.platform("Kolej 5") == "5")
        #expect(CeskeDrahyRides.platform(" ") == nil)
    }
}

@Suite struct IdosTests {
    @Test func htmlEntitiesAreDecoded() {
        #expect(IdosParser.clean("Praha&nbsp;hl.n. &amp; Brno&#160;&#x17E;") == "Praha hl.n. & Brno ž")
    }
}
