import Foundation

// Wire models for the IPWS back-end (ipws.cdis.cz). Field names mirror the server's
// Hungarian notation; see mujvlak/openapi.yaml. Everything is optional because the
// server omits fields freely; mapping into `Ride`/`Leg` happens in `CeskeDrahyRides`.

struct IpwsFailure: Decodable {
    let ExceptionType: String?
    /// "<numeric code> <text>", e.g. "10121 Zadali jste nesprávný e-mail nebo heslo."
    let Message: String
}

struct IpwsEnvelope<Payload: Decodable>: Decodable {
    let d: Payload
}

struct IpwsSession: Decodable {
    let sSessionID: String?
    let iLoginErr: Int?
    let sLoginErr: String?
    let oLoginInfo: IpwsLoginInfo?
}

struct IpwsLoginInfo: Decodable {
    let sEmail: String?
    let sFirstName: String?
    let sSurname: String?
}

// MARK: Tickets

struct IpwsTicketSync: Decodable {
    let aoCreated: [IpwsTicket]?
    let aoUpdated: [IpwsTicket]?
    let aoUser: [IpwsTicket]?
    let aoRestored: [IpwsTicket]?

    var all: [IpwsTicket] {
        [aoCreated, aoUpdated, aoUser, aoRestored].compactMap { $0 }.flatMap { $0 }
    }
}

struct IpwsTicket: Decodable {
    let sTransCode: String?
    let sReturnReason: String?
    let aoThere: [IpwsTicketTrain]?
    let aoBack: [IpwsTicketTrain]?
}

struct IpwsTicketTrain: Decodable {
    let sTrainNum: String?
    let sTrainName: String?
    let sTrainType: String?
    let oFrom: IpwsTicketStation?
    let oTo: IpwsTicketStation?
}

struct IpwsTicketStation: Decodable {
    let iStationKey: Int?
    let sStationName: String?
    let dtTime: String?
}

// MARK: Trains

struct IpwsTrainSearch: Decodable {
    let sCombID: String
    let aoTrain: [IpwsTrainInfo]?
}

struct IpwsTrainInfo: Decodable {
    let iTTIndex: Int
    let iTrain: Int
    let sNum1: String?
    let sNum2: String?
    let sType: String?
}

struct IpwsTrainData: Decodable {
    let aoRoute: [IpwsRouteStop]?
    let aoTrainPos: [IpwsTrainPosition]?
    let sNum1: String?
    let sNum2: String?
    let sType: String?
}

struct IpwsRouteStop: Decodable {
    let sStationName: String
    let iKey: Int?
    let dtArrTime: String?
    let dtDepTime: String?
    /// Platform/track, e.g. "Nást. 1B" or "Kolej 5". Only present for some stops.
    let sStand: String?
}

struct IpwsTrainPosition: Decodable {
    let iDelay: Int?
    let sPosition: String?
    /// Index into `aoRoute` of the next station the train will reach.
    let iNextStation: Int?
    let bNotDispatched: Bool?
}
