import Foundation
import Observation
import OSLog
import TrainAlarmKit

/// App state: the signed-in account, the current ride and its refresh cycle.
///
/// The ride comes from the Můj vlak account, unless an IDOS link is set, which then
/// takes over until it is cleared.
@MainActor
@Observable
final class RideStore {
    private(set) var ride: Ride?
    private(set) var account: String?
    private(set) var idosLink: URL?
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    /// Ticks every few seconds so countdowns stay current.
    private(set) var now = Date.now

    /// Observed on purpose: `isConfigured` (sign-in vs. ride screen) derives from it.
    private var rides: CeskeDrahyRides?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    private static let logger = Logger(subsystem: "cz.trainalarm.app", category: "rides")
    private static let idosLinkKey = "TrainAlarm.sourceURL"
    private static let installIDKey = "TrainAlarm.installID"

    var isConfigured: Bool { rides != nil || idosLink != nil }

    init() {
        idosLink = UserDefaults.standard.string(forKey: Self.idosLinkKey).flatMap(URL.init(string:))
        if let credentials = CredentialStore.load() {
            connect(credentials)
        }
        ticker = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.tick()
            }
        }
    }

    // MARK: Account

    /// Checks the credentials against ČD, then stores them in the Keychain.
    func signIn(email: String, password: String) async throws {
        let credentials = Credentials(email: email.trimmingCharacters(in: .whitespaces), password: password)
        let client = IpwsClient(credentials: credentials, installID: Self.installID)
        try await client.signIn()
        try CredentialStore.save(credentials)
        rides = CeskeDrahyRides(client: client)
        account = credentials.email
        await refresh()
    }

    func signOut() {
        CredentialStore.delete()
        rides = nil
        account = nil
        if idosLink == nil { reset() }
    }

    private func connect(_ credentials: Credentials) {
        rides = CeskeDrahyRides(client: IpwsClient(credentials: credentials, installID: Self.installID))
        account = credentials.email
    }

    // MARK: IDOS

    func track(idosLink text: String) async -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true else {
            errorMessage = "That doesn't look like a link."
            return false
        }
        idosLink = url
        UserDefaults.standard.set(url.absoluteString, forKey: Self.idosLinkKey)
        reset()
        await refresh()
        return true
    }

    func clearIdosLink() {
        idosLink = nil
        UserDefaults.standard.removeObject(forKey: Self.idosLinkKey)
        reset()
        Task { await refresh() }
    }

    // MARK: Refreshing

    func refresh() async {
        guard !isRefreshing, isConfigured else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            if let idosLink {
                ride = try await IdosParser.ride(from: idosLink)
            } else if let rides {
                ride = try await rides.currentRide()
            }
            errorMessage = nil
            lastUpdated = .now
        } catch {
            // Keep showing the last known ride; just surface the problem.
            Self.logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
        now = .now
    }

    /// Called when the popover opens.
    func refreshIfStale() async {
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < 30 { return }
        await refresh()
    }

    private func tick() async {
        now = .now
        let age = lastUpdated.map { now.timeIntervalSince($0) } ?? .infinity
        if age >= refreshInterval {
            await refresh()
        }
    }

    /// Refresh often while the train matters, rarely otherwise.
    private var refreshInterval: TimeInterval {
        guard let ride else { return 300 }
        switch ride.phase(at: now) {
        case .waiting(let departure) where departure.timeIntervalSince(now) > 3600: return 300
        case .arrived: return 300
        default: return 60
        }
    }

    private func reset() {
        ride = nil
        errorMessage = nil
        hasLoaded = false
        lastUpdated = nil
    }

    private static var installID: String {
        if let id = UserDefaults.standard.string(forKey: installIDKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: installIDKey)
        return id
    }
}
