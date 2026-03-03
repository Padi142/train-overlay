import AppKit
import Foundation
import SwiftUI

struct TrainStop: Identifiable {
    let id = UUID()
    let station: String
    let scheduledTime: String
    let liveTime: String
    let isCurrent: Bool
    let isNext: Bool
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

    static let placeholder = JourneySnapshot(
        trainLine: "Set IDOS link to begin",
        fromStation: "--",
        toStation: "--",
        boardingTime: "--:--",
        scheduledArrival: "--:--",
        liveArrival: "--:--",
        delayMinutes: 0,
        occupancyHint: "Live source",
        platform: "--",
        stops: []
    )

    var currentStopID: TrainStop.ID? {
        stops.first(where: { $0.isCurrent })?.id
    }
}

@MainActor
final class JourneyViewModel: ObservableObject {
    @Published var snapshot: JourneySnapshot = .placeholder
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sourceText: String
    @Published var debugLines: [String] = []

    private var sourceURL: URL?
    private var hasLoaded = false
    private static let savedURLKey = "TrainAlarm.sourceURL"

    init() {
        if let savedText = UserDefaults.standard.string(forKey: Self.savedURLKey),
           let savedURL = URL(string: savedText) {
            self.sourceURL = savedURL
            self.sourceText = savedText
        } else {
            self.sourceURL = nil
            self.sourceText = ""
        }
    }

    func refreshIfNeeded() async {
        if hasLoaded {
            return
        }
        guard sourceURL != nil else {
            return
        }
        await refresh()
    }

    func refresh() async {
        appendDebug("Refresh requested")

        guard let sourceURL else {
            errorMessage = "Set your IDOS URL with the edit icon first."
            appendDebug("Refresh blocked: no source URL")
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            appendDebug("Parsing URL: \(sourceURL.absoluteString)")
            let parsed = try await IdosParser.parseJourney(from: sourceURL)
            snapshot = parsed
            hasLoaded = true
            appendDebug("Parsed \(parsed.stops.count) stops, delay \(parsed.delayMinutes)m")
        } catch {
            errorMessage = error.localizedDescription
            appendDebug("Parse failed: \(error.localizedDescription)")
        }

        isLoading = false
    }

    func applySourceAndRefresh() async {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            errorMessage = "Please enter a valid full URL."
            appendDebug("Rejected invalid URL input")
            return
        }

        sourceURL = url
        hasLoaded = false
        UserDefaults.standard.set(url.absoluteString, forKey: Self.savedURLKey)
        appendDebug("Using new source URL")
        await refresh()
    }

    private func appendDebug(_ message: String) {
        let stamp = Self.debugDateFormatter.string(from: Date())
        let line = "[\(stamp)] \(message)"
        debugLines.append(line)
        if debugLines.count > 40 {
            debugLines.removeFirst(debugLines.count - 40)
        }
        print("[TrainAlarm] \(line)")
    }

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

enum IdosParserError: LocalizedError {
    case invalidURL
    case missingTrainLine
    case missingRoute
    case missingDetailURL
    case missingStops

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The IDOS URL is not valid."
        case .missingTrainLine:
            return "Could not parse train line from IDOS page."
        case .missingRoute:
            return "Could not parse route times and stations."
        case .missingDetailURL:
            return "Could not find detail URL for train stops."
        case .missingStops:
            return "Could not parse stops in IDOS train detail."
        }
    }
}

struct IdosParser {
    static func parseJourney(from prehledURL: URL) async throws -> JourneySnapshot {
        print("[TrainAlarm] Starting IDOS parse")
        print("[TrainAlarm] Overview URL: \(prehledURL.absoluteString)")

        let overviewHTML = try await fetchHTML(url: prehledURL)
        print("[TrainAlarm] Overview page length: \(overviewHTML.count)")

        let routePattern = #"<ul class="reset stations[^"]*">\s*<li[^>]*>\s*<p class="reset time[^>]*>\s*([0-9]{1,2}:[0-9]{2})\s*</p>\s*<p class="station"><strong class="name[^"]*">([^<]+)</strong>[\s\S]*?</li>\s*<li[^>]*>\s*<p class="reset time[^>]*>\s*([0-9]{1,2}:[0-9]{2})\s*</p>\s*<p class="station"><strong class="name[^"]*">([^<]+)</strong>"#

        guard
            let routeMatch = firstMatchGroups(in: overviewHTML, pattern: routePattern, groups: [1, 2, 3, 4]),
            routeMatch.count == 4
        else {
            print("[TrainAlarm] Route parse failed. Expected 2-station summary block.")
            throw IdosParserError.missingRoute
        }

        let boardingTime = normalizeText(routeMatch[0])
        let fromStation = normalizeText(routeMatch[1])
        let scheduledArrival = normalizeText(routeMatch[2])
        let toStation = normalizeText(routeMatch[3])

        let delayPattern = #"delay-bubble[\s\S]*?>(?:[^<]*?)([0-9]+)\s*min"#
        let delayMinutes = Int(firstMatch(in: overviewHTML, pattern: delayPattern) ?? "0") ?? 0
        print("[TrainAlarm] Parsed delay: \(delayMinutes)m")

        guard let detailRaw = firstMatch(in: overviewHTML, pattern: #"<a href="([^"]*?/spojeni/draha/\?[^"]+)"[^>]*class="title""#) else {
            print("[TrainAlarm] Could not find detail URL in overview HTML")
            throw IdosParserError.missingDetailURL
        }

        let detailURL = try makeAbsoluteURL(from: detailRaw, base: prehledURL)
        print("[TrainAlarm] Detail URL: \(detailURL.absoluteString)")
        let detailHTML = try await fetchHTML(url: detailURL)
        print("[TrainAlarm] Detail page length: \(detailHTML.count)")

        let trainLineRaw = firstMatch(in: detailHTML, pattern: #"<h1[^>]*>\s*<span>([^<]+)</span>"#)
            ?? firstMatch(in: overviewHTML, pattern: #"<h3[^>]*>\s*<span>([^<]+)</span>"#)

        guard let trainLineRaw else {
            print("[TrainAlarm] Train line parse failed in both detail and overview pages")
            print("[TrainAlarm] detail has <h1>: \(detailHTML.contains("<h1"))")
            print("[TrainAlarm] overview has <h3>: \(overviewHTML.contains("<h3"))")
            print("[TrainAlarm] Detail snippet: \(debugSnippet(detailHTML))")
            throw IdosParserError.missingTrainLine
        }

        let parsedStops = parseStops(detailHTML: detailHTML, fromStation: fromStation, toStation: toStation, delayMinutes: delayMinutes)

        guard !parsedStops.stops.isEmpty else {
            print("[TrainAlarm] Parsed zero stops from detail page")
            throw IdosParserError.missingStops
        }

        let liveArrival = shiftTime(scheduledArrival, byMinutes: delayMinutes)

        return JourneySnapshot(
            trainLine: normalizeText(trainLineRaw),
            fromStation: fromStation,
            toStation: toStation,
            boardingTime: boardingTime,
            scheduledArrival: scheduledArrival,
            liveArrival: liveArrival,
            delayMinutes: delayMinutes,
            occupancyHint: "Parsed from IDOS",
            platform: parsedStops.platform,
            stops: parsedStops.stops
        )
    }

    private static func parseStops(detailHTML: String, fromStation: String, toStation: String, delayMinutes: Int) -> (stops: [TrainStop], platform: String) {
        guard let itineraryBlock = firstMatch(
            in: detailHTML,
            pattern: #"<ul class="reset line-itinerary">([\s\S]*?)</ul>"#
        ) else {
            return ([], "--")
        }

        guard let regex = try? NSRegularExpression(pattern: #"<li class="item([^"]*)"[^>]*>([\s\S]*?)</li>"#, options: []) else {
            return ([], "--")
        }

        let nsRange = NSRange(itineraryBlock.startIndex..<itineraryBlock.endIndex, in: itineraryBlock)
        let matches = regex.matches(in: itineraryBlock, options: [], range: nsRange)

        var entries: [(station: String, arrival: String?, departure: String?, isInactive: Bool, html: String)] = []

        for match in matches {
            guard
                let classRange = Range(match.range(at: 1), in: itineraryBlock),
                let htmlRange = Range(match.range(at: 2), in: itineraryBlock)
            else {
                continue
            }

            let classText = String(itineraryBlock[classRange])
            let itemHTML = String(itineraryBlock[htmlRange])
            guard let stationRaw = firstMatch(in: itemHTML, pattern: #"<strong class="name">([^<]+)</strong>"#) else {
                continue
            }

            let arrival = firstMatch(in: itemHTML, pattern: #"<span class="arrival">\s*<span class="label out"></span>\s*([0-9]{1,2}:[0-9]{2})"#)
            let departure = firstMatch(in: itemHTML, pattern: #"<span class="departure">\s*<span class="label out"></span>\s*([0-9]{1,2}:[0-9]{2})"#)

            entries.append((
                station: normalizeText(stationRaw),
                arrival: arrival,
                departure: departure,
                isInactive: classText.contains("inactive"),
                html: itemHTML
            ))
        }

        let platform = parsePlatform(entries: entries, fromStation: fromStation)

        var rawStops: [(station: String, scheduled: String, live: String)] = []
        var seenFrom = false

        for entry in entries {
            if !seenFrom {
                if normalizeForCompare(entry.station) == normalizeForCompare(fromStation) {
                    seenFrom = true
                    let scheduled = entry.departure ?? entry.arrival ?? "--:--"
                    let live = shiftTime(scheduled, byMinutes: delayMinutes)
                    rawStops.append((station: entry.station, scheduled: scheduled, live: live))
                }
                continue
            }

            if entry.isInactive {
                continue
            }

            if normalizeForCompare(entry.station) == normalizeForCompare(fromStation) {
                continue
            }

            let scheduled = entry.departure ?? entry.arrival ?? "--:--"
            let live = shiftTime(scheduled, byMinutes: delayMinutes)
            rawStops.append((station: entry.station, scheduled: scheduled, live: live))

            if normalizeForCompare(entry.station) == normalizeForCompare(toStation) {
                break
            }
        }

        let currentIndex = resolveCurrentStopIndex(from: rawStops)
        let nextIndex = resolveNextStopIndex(currentIndex: currentIndex, total: rawStops.count)

        let stops = rawStops.enumerated().map { index, raw in
            TrainStop(
                station: raw.station,
                scheduledTime: raw.scheduled,
                liveTime: raw.live,
                isCurrent: index == currentIndex,
                isNext: index == nextIndex
            )
        }

        return (stops, platform)
    }

    private static func resolveCurrentStopIndex(from rawStops: [(station: String, scheduled: String, live: String)]) -> Int? {
        guard !rawStops.isEmpty else {
            return nil
        }

        let nowMinutes = currentMinutesOfDay()
        let liveMinutes = rawStops.map { minutesOfDay($0.live) }

        if let first = liveMinutes.first, nowMinutes <= first {
            return 0
        }

        for index in stride(from: liveMinutes.count - 1, through: 0, by: -1) {
            if nowMinutes >= liveMinutes[index] {
                return index
            }
        }

        return 0
    }

    private static func resolveNextStopIndex(currentIndex: Int?, total: Int) -> Int? {
        guard let currentIndex, total > 0 else {
            return nil
        }

        let next = currentIndex + 1
        if next < total {
            return next
        }
        return nil
    }

    private static func parsePlatform(
        entries: [(station: String, arrival: String?, departure: String?, isInactive: Bool, html: String)],
        fromStation: String
    ) -> String {
        guard let boardingEntry = entries.first(where: { normalizeForCompare($0.station) == normalizeForCompare(fromStation) }) else {
            return "--"
        }

        if let full = firstMatch(
            in: boardingEntry.html,
            pattern: #"title="nástupiště/kolej" class="color-green">([^<]+)<"#
        ) {
            return normalizeText(full)
        }

        if let trackOnly = firstMatch(
            in: boardingEntry.html,
            pattern: #"title="kolej" class="color-green">([^<]+)<"#
        ) {
            return normalizeText(trackOnly)
        }

        return "--"
    }

    private static func makeAbsoluteURL(from rawHref: String, base: URL) throws -> URL {
        let normalized = rawHref.replacingOccurrences(of: "&amp;", with: "&")

        if let absolute = URL(string: normalized), absolute.scheme != nil {
            return absolute
        }

        if let resolved = URL(string: normalized, relativeTo: base)?.absoluteURL {
            return resolved
        }

        throw IdosParserError.invalidURL
    }

    private static func fetchHTML(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw IdosParserError.invalidURL
        }
        return html
    }

    private static func debugSnippet(_ html: String) -> String {
        html
            .prefix(300)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private static func shiftTime(_ time: String, byMinutes minutes: Int) -> String {
        let components = time.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              hour >= 0,
              hour < 24,
              minute >= 0,
              minute < 60 else {
            return time
        }

        let total = ((hour * 60 + minute + minutes) % 1440 + 1440) % 1440
        let newHour = total / 60
        let newMinute = total % 60
        return String(format: "%02d:%02d", newHour, newMinute)
    }

    private static func minutesOfDay(_ time: String) -> Int {
        let components = time.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              hour >= 0,
              hour < 24,
              minute >= 0,
              minute < 60 else {
            return 0
        }
        return hour * 60 + minute
    }

    private static func currentMinutesOfDay() -> Int {
        let now = Date()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return hour * 60 + minute
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func firstMatchGroups(in text: String, pattern: String, groups: [Int]) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else {
            return nil
        }

        var results: [String] = []
        for group in groups {
            guard let range = Range(match.range(at: group), in: text) else {
                return nil
            }
            results.append(String(text[range]))
        }
        return results
    }

    private static func normalizeText(_ input: String) -> String {
        let decoded = decodeHTMLEntities(input)
        return decoded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeForCompare(_ input: String) -> String {
        normalizeText(input)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "cs_CZ"))
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else {
            return input
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil).string) ?? input
    }
}

@main
struct TrainAlarmApp: App {
    @StateObject private var viewModel = JourneyViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Train Alarm", systemImage: "train.side.front.car") {
            JourneyMenuView(viewModel: viewModel)
                .frame(width: 420, height: 640)
                .task {
                    await viewModel.refreshIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

struct JourneyMenuView: View {
    @ObservedObject var viewModel: JourneyViewModel
    @State private var isEditingSource = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.11, blue: 0.17),
                    Color(red: 0.03, green: 0.07, blue: 0.13)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("IDOS Journey")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))

                    Spacer()

                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }

                    Button {
                        Task {
                            await viewModel.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.88))
                    .help("Refresh from IDOS")
                    .disabled(viewModel.isLoading)

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isEditingSource.toggle()
                        }
                    } label: {
                        Image(systemName: isEditingSource ? "xmark.circle.fill" : "square.and.pencil")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.88))
                    .help("Edit IDOS link")
                }

                if isEditingSource {
                    HStack(spacing: 8) {
                        TextField("Paste IDOS share link", text: $viewModel.sourceText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .onSubmit {
                                Task {
                                    await viewModel.applySourceAndRefresh()
                                    if viewModel.errorMessage == nil {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            isEditingSource = false
                                        }
                                    }
                                }
                            }

                        Button("Load") {
                            Task {
                                await viewModel.applySourceAndRefresh()
                                if viewModel.errorMessage == nil {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        isEditingSource = false
                                    }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                HeaderCard(snapshot: viewModel.snapshot)
                RouteCard(snapshot: viewModel.snapshot)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.56))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text("Upcoming Stops")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            if viewModel.snapshot.stops.isEmpty {
                                Text(viewModel.isLoading ? "Loading stops..." : "No stops found")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                            } else {
                                ForEach(viewModel.snapshot.stops) { stop in
                                    StopRow(stop: stop)
                                        .id(stop.id)
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .layoutPriority(1)
                    .onAppear {
                        scrollToCurrentStop(using: proxy)
                    }
                    .onChange(of: viewModel.snapshot.currentStopID) { _ in
                        scrollToCurrentStop(using: proxy)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func scrollToCurrentStop(using proxy: ScrollViewProxy) {
        guard let currentStopID = viewModel.snapshot.currentStopID else {
            return
        }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(currentStopID, anchor: .center)
            }
        }
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

    private var accentColor: Color {
        if stop.isCurrent {
            return Color(red: 0.45, green: 0.78, blue: 1.0)
        }
        if stop.isNext {
            return Color(red: 1.0, green: 0.86, blue: 0.36)
        }
        return Color(red: 0.63, green: 0.82, blue: 0.98)
    }

    private var rowTint: Color {
        if stop.isCurrent {
            return Color(red: 0.15, green: 0.57, blue: 0.94)
        }
        if stop.isNext {
            return Color(red: 0.96, green: 0.68, blue: 0.08)
        }
        return .white
    }

    private var isHighlighted: Bool {
        stop.isCurrent || stop.isNext
    }

    private var badgeText: String? {
        if stop.isCurrent {
            return "CURRENT"
        }
        if stop.isNext {
            return "NEXT"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(stop.station)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(isHighlighted ? accentColor : .white)

                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(rowTint.opacity(0.85), in: Capsule())
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(stop.liveTime)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isHighlighted ? accentColor : .white)

                Text("sched \(stop.scheduledTime)")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowTint.opacity(isHighlighted ? 0.2 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(rowTint.opacity(isHighlighted ? 0.35 : 0.0), lineWidth: 1)
                )
        )
    }
}

struct DelayBadge: View {
    let delayMinutes: Int

    var body: some View {
        Text(delayMinutes > 0 ? "+\(delayMinutes)m" : "On time")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(delayMinutes > 0 ? Color(red: 1.0, green: 0.91, blue: 0.58) : Color(red: 0.73, green: 0.95, blue: 0.74))
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
