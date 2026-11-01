import Foundation

/// E-mail + password of a ČD e-shop / Můj vlak account.
public struct Credentials: Codable, Sendable, Equatable {
    public var email: String
    public var password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public enum IpwsError: LocalizedError, Equatable {
    case invalidCredentials
    case server(code: Int?, message: String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Wrong e-mail or password."
        case .server(_, let message): message
        case .unexpectedResponse(let detail): "Unexpected response from České dráhy (\(detail))."
        }
    }

    static func from(message: String) -> IpwsError {
        let parts = message.split(separator: " ", maxSplits: 1)
        let code = parts.first.flatMap { Int($0) }
        if code == 10121 { return .invalidCredentials }
        let text = code != nil && parts.count > 1 ? String(parts[1]) : message
        return .server(code: code, message: text)
    }
}

/// Client for the IPWS back-end used by the Můj vlak app.
///
/// Signs in lazily (anonymous `CreateSession` → `Login1`) and transparently signs in
/// again once when a call fails, which covers expired sessions.
public actor IpwsClient {
    private static let baseURL = URL(string: "https://ipws.cdis.cz/IP.svc/")!
    /// The server only accepts the GUID of the currently published app (v32).
    private static let appID = "{A6AB5B3E-8A7E-4E84-9DC8-801561CE886F}"

    private let credentials: Credentials
    private let userDescription: String
    private let urlSession: URLSession
    private var sessionID: String?

    /// - Parameter installID: stable per-install identifier, sent as part of the device fingerprint.
    public init(credentials: Credentials, installID: String, urlSession: URLSession = .shared) {
        self.credentials = credentials
        self.urlSession = urlSession
        // appVersionCode|sdk|model|androidId^serial|installId|lang|country|dpi|width|height|versionName
        self.userDescription = "352|34|Mac|^|\(installID)|cs|CZ|440|1080|2400|2.19.0"
    }

    /// Verifies the credentials and starts a session.
    public func signIn() async throws {
        sessionID = nil
        let anonymous: IpwsSession = try await post("CreateSession", CreateSession(sAppID: Self.appID, sUserDesc: userDescription))
        guard let anonymousID = anonymous.sSessionID else {
            throw IpwsError.unexpectedResponse("no session id")
        }
        let login: IpwsSession = try await post(
            "Login1",
            Login(sUser: credentials.email, sPwd: credentials.password, sUserDesc: userDescription),
            session: anonymousID
        )
        if let error = login.iLoginErr, error != 0 {
            throw IpwsError.server(code: error, message: login.sLoginErr ?? "Sign-in failed (\(error)).")
        }
        sessionID = login.sSessionID ?? anonymousID
    }

    /// All tickets on the account (full sync).
    func tickets() async throws -> [IpwsTicket] {
        let sync: IpwsTicketSync = try await authorized("GetTickets", GetTickets())
        return sync.all
    }

    /// Trains with the given number running on the Prague calendar day of `day`.
    func searchTrains(number: String, day: Date) async throws -> IpwsTrainSearch {
        try await authorized("SearchTrainInfo", SearchTrainInfo(sMask: number, dtDate: IpwsTime.dayParameter(day)))
    }

    /// Route, live position and delay of one train run. `day` is the day the run started.
    func trainData(_ train: IpwsTrainInfo, combinationID: String, stationKey: Int?, day: Date) async throws -> IpwsTrainData {
        try await authorized("GetTrainDataInfo1", GetTrainDataInfo(
            sCombID: combinationID,
            iTTIndex: train.iTTIndex,
            iTrain: train.iTrain,
            iStationKey: stationKey ?? 0,
            dtDate: IpwsTime.dayParameter(day)
        ))
    }

    // MARK: Transport

    private func authorized<Response: Decodable>(_ command: String, _ payload: some Encodable & Sendable) async throws -> Response {
        if sessionID == nil { try await signIn() }
        do {
            return try await post(command, payload, session: sessionID)
        } catch let error as IpwsError where error != .invalidCredentials {
            try await signIn()
            return try await post(command, payload, session: sessionID)
        }
    }

    private func post<Response: Decodable>(_ command: String, _ payload: some Encodable, session: String? = nil) async throws -> Response {
        var request = URLRequest(url: Self.baseURL.appending(path: command), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("okhttp/5.1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(RequestBody(sessionID: session, payload: payload))

        let (data, response) = try await urlSession.data(for: request)
        let decoder = JSONDecoder()
        // Business errors come back as HTTP 500 with {"ExceptionType", "Message"}.
        if let failure = try? decoder.decode(IpwsFailure.self, from: data) {
            throw IpwsError.from(message: failure.Message)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw IpwsError.unexpectedResponse("\(command): HTTP \(status)")
        }
        do {
            return try decoder.decode(IpwsEnvelope<Response>.self, from: data).d
        } catch {
            throw IpwsError.unexpectedResponse("\(command): \(error.localizedDescription)")
        }
    }
}

// MARK: Request bodies

/// Every request carries `iLang` (0 = Czech) and, once signed in, `sSessionID`,
/// flattened next to the command's own fields.
private struct RequestBody<Payload: Encodable>: Encodable {
    let sessionID: String?
    let payload: Payload

    private enum Keys: String, CodingKey { case iLang, sSessionID }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(0, forKey: .iLang)
        try container.encodeIfPresent(sessionID, forKey: .sSessionID)
        try payload.encode(to: encoder)
    }
}

private struct CreateSession: Encodable, Sendable {
    struct NotificationSettings: Encodable, Sendable {
        var iNotificationMask = 0
        var iInitialAdvance = 0
        var iChangeAdvance = 0
        var iDelayLimit = 0
        var iGetOffAdvance = 0
    }

    let sAppID: String
    let sUserDesc: String
    var sUser = ""
    var sPwd = ""
    var iTokenType = 1
    var oRegisterNotificationsSettings = NotificationSettings()
}

private struct Login: Encodable, Sendable {
    let sUser: String
    let sPwd: String
    let sUserDesc: String
}

private struct GetTickets: Encodable, Sendable {
    struct SyncParam: Encodable, Sendable {
        // Empty lists = "I know nothing", i.e. a full sync.
        var sTransCodeLast: String?
        var asTransCodes: [String] = []
        var asRetTransCodes: [String] = []
        var asLiftagoCodes: [String] = []
        var asHasCompensationTransCodes: [String] = []
        var asLastChange: [String] = []
    }

    var oSynchronizeParam = SyncParam()
}

private struct SearchTrainInfo: Encodable, Sendable {
    let sMask: String
    let dtDate: String
    var iMaxCount = 10
}

private struct GetTrainDataInfo: Encodable, Sendable {
    let sCombID: String
    let iTTIndex: Int
    let iTrain: Int
    let iStationKey: Int
    let dtDate: String
    var bIsArr = false
    var bRelation = false
    var iFlags = 0
    var iOrderingStationIndexDefaultZero = 0
}
