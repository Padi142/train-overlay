import Foundation

/// Internet reachability as seen by periodic probes.
public enum Connectivity: Sendable, Equatable {
    case online
    /// The last probe failed.
    case offline(since: Date)
    /// Probes succeed again, but not yet for a full `recoveryWindow`.
    case recovering(since: Date)
}

/// Decides the connectivity state and when to probe next, from probe results.
///
/// - online: probe every `onlineInterval`; one failure → offline
/// - offline: probe every `offlineInterval`; one success → recovering
/// - recovering: probe with exponential backoff (1, 2, 4… s); any failure → offline,
///   a clean `recoveryWindow` → online
public struct ConnectivityMachine: Sendable {
    public var onlineInterval: TimeInterval = 15
    public var offlineInterval: TimeInterval = 3
    public var recoveryWindow: TimeInterval = 15
    public var initialBackoff: TimeInterval = 1

    public private(set) var state: Connectivity = .online
    private var backoff: TimeInterval = 0

    public init() {}

    /// Records a probe result and returns the delay until the next probe.
    public mutating func record(success: Bool, at now: Date) -> TimeInterval {
        guard success else {
            if case .offline = state {} else { state = .offline(since: now) }
            return offlineInterval
        }
        switch state {
        case .online:
            return onlineInterval
        case .offline:
            state = .recovering(since: now)
            backoff = initialBackoff
            return backoff
        case .recovering(let since):
            let elapsed = now.timeIntervalSince(since)
            if elapsed >= recoveryWindow {
                state = .online
                return onlineInterval
            }
            backoff *= 2
            // Land the last probe exactly at the end of the window.
            return min(backoff, recoveryWindow - elapsed)
        }
    }
}

public enum ConnectivityProbe {
    /// Returns 204 when the internet is reachable; captive portals answer differently.
    public static let url = URL(string: "https://cp.cloudflare.com/generate_204")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// One request; slow answers count as failures, since a train connection that slow is unusable.
    public static func check(timeout: TimeInterval = 5) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 204
    }
}
