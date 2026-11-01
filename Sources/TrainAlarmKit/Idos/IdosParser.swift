import Foundation

public enum IdosParserError: LocalizedError {
    case unreadablePage
    case missingRoute
    case missingDetailURL
    case missingTrainLine
    case missingStops

    public var errorDescription: String? {
        switch self {
        case .unreadablePage: "Could not read the IDOS page."
        case .missingRoute: "Could not find the route on the IDOS page."
        case .missingDetailURL: "Could not find the train detail on the IDOS page."
        case .missingTrainLine: "Could not find the train name on the IDOS page."
        case .missingStops: "Could not find the stops on the IDOS page."
        }
    }
}

/// Scrapes a shared IDOS connection link ("…/spojeni/…") into a `Ride`.
/// IDOS only exposes times of day, so the ride is assumed to start today.
public enum IdosParser {
    public static func ride(from url: URL, now: Date = .now) async throws -> Ride {
        let overview = try await fetchHTML(url)

        let routePattern = #"<ul class="reset stations[^"]*">\s*<li[^>]*>\s*<p class="reset time[^>]*>\s*([0-9]{1,2}:[0-9]{2})\s*</p>\s*<p class="station"><strong class="name[^"]*">([^<]+)</strong>[\s\S]*?</li>\s*<li[^>]*>\s*<p class="reset time[^>]*>\s*([0-9]{1,2}:[0-9]{2})\s*</p>\s*<p class="station"><strong class="name[^"]*">([^<]+)</strong>"#
        guard let route = firstMatch(in: overview, pattern: routePattern, groups: 4) else {
            throw IdosParserError.missingRoute
        }
        let boardingTime = route[0], fromStation = clean(route[1])
        let arrivalTime = route[2], toStation = clean(route[3])

        let delay = firstMatch(in: overview, pattern: #"delay-bubble[\s\S]*?>(?:[^<]*?)([0-9]+)\s*min"#).flatMap { Int($0) }

        guard let detailHref = firstMatch(in: overview, pattern: #"<a href="([^"]*?/spojeni/draha/\?[^"]+)"[^>]*class="title""#),
              let detailURL = URL(string: detailHref.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: url)?.absoluteURL
        else {
            throw IdosParserError.missingDetailURL
        }
        let detail = try await fetchHTML(detailURL)

        guard let trainLine = firstMatch(in: detail, pattern: #"<h1[^>]*>\s*<span>([^<]+)</span>"#)
            ?? firstMatch(in: overview, pattern: #"<h3[^>]*>\s*<span>([^<]+)</span>"#)
        else {
            throw IdosParserError.missingTrainLine
        }

        let clock = Clock(start: boardingTime, now: now)
        var stops = itinerary(in: detail, from: fromStation, to: toStation).enumerated().map { index, entry in
            Ride.Stop(
                id: index,
                name: entry.station,
                arrival: entry.arrival.flatMap(clock.date),
                departure: entry.departure.flatMap(clock.date),
                platform: entry.platform
            )
        }
        guard stops.count >= 2 else { throw IdosParserError.missingStops }

        // The overview's times are authoritative for where you board and get off.
        stops[0].arrival = nil
        stops[0].departure = clock.date(boardingTime)
        stops[stops.count - 1].arrival = clock.date(arrivalTime)
        stops[stops.count - 1].departure = nil

        return Ride(train: clean(trainLine), stops: stops, delay: delay, source: .idos)
    }

    private struct ItineraryEntry {
        let station: String
        let arrival: String?
        let departure: String?
        let platform: String?
    }

    /// Stops of the train between `from` and `to` (inclusive), skipping ones it passes through.
    private static func itinerary(in html: String, from: String, to: String) -> [ItineraryEntry] {
        guard let block = firstMatch(in: html, pattern: #"<ul class="reset line-itinerary">([\s\S]*?)</ul>"#) else {
            return []
        }
        let from = Station(name: from), to = Station(name: to)
        var entries: [ItineraryEntry] = []

        for item in allMatches(in: block, pattern: #"<li class="item([^"]*)"[^>]*>([\s\S]*?)</li>"#) {
            let (classes, body) = (item[0], item[1])
            guard let name = firstMatch(in: body, pattern: #"<strong class="name">([^<]+)</strong>"#).map(clean) else { continue }

            let isBoarding = from.matches(key: nil, name: name)
            if entries.isEmpty && !isBoarding { continue }
            if !entries.isEmpty && (classes.contains("inactive") || isBoarding) { continue }

            entries.append(ItineraryEntry(
                station: name,
                arrival: firstMatch(in: body, pattern: #"<span class="arrival">\s*<span class="label out"></span>\s*([0-9]{1,2}:[0-9]{2})"#),
                departure: firstMatch(in: body, pattern: #"<span class="departure">\s*<span class="label out"></span>\s*([0-9]{1,2}:[0-9]{2})"#),
                platform: firstMatch(in: body, pattern: #"title="(?:nástupiště/kolej|kolej)" class="color-green">([^<]+)<"#).map(clean)
            ))
            if to.matches(key: nil, name: name) { break }
        }
        return entries
    }

    /// Turns "HH:mm" strings into dates, starting today and rolling over past midnight.
    private struct Clock {
        let midnight: Date
        let startMinutes: Int

        init(start: String, now: Date) {
            midnight = Calendar.current.startOfDay(for: now)
            startMinutes = Self.minutes(start) ?? 0
        }

        func date(_ time: String) -> Date? {
            guard var minutes = Self.minutes(time) else { return nil }
            if minutes < startMinutes - 60 { minutes += 24 * 60 }
            return midnight.addingTimeInterval(TimeInterval(minutes * 60))
        }

        static func minutes(_ time: String) -> Int? {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
            return parts[0] * 60 + parts[1]
        }
    }

    // MARK: HTML helpers

    private static func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw IdosParserError.unreadablePage
        }
        return html
    }

    private static func allMatches(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { group in
                Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func firstMatch(in text: String, pattern: String, groups: Int) -> [String]? {
        allMatches(in: text, pattern: pattern).first.flatMap { $0.count == groups ? $0 : nil }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        allMatches(in: text, pattern: pattern).first?.first
    }

    /// Decodes HTML entities and collapses whitespace.
    static func clean(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            rest = rest[amp...]
            guard let semicolon = rest.prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = rest.dropFirst()
                continue
            }
            let entity = rest[rest.index(after: rest.startIndex)..<semicolon]
            if let decoded = decode(entity) {
                result.append(decoded)
                rest = rest[rest.index(after: semicolon)...]
            } else {
                result += "&"
                rest = rest.dropFirst()
            }
        }
        result += rest
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func decode(_ entity: Substring) -> Character? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            let scalar = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                ? UInt32(entity.dropFirst(2), radix: 16)
                : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil
            return scalar.flatMap(Unicode.Scalar.init).map(Character.init)
        }
    }
}
