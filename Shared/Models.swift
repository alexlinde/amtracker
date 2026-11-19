import Foundation

struct Station: Codable, Equatable {
    var name: String?
    var code: String?
    var tz: String?
    var schArr: String?
    var schDep: String?
    var arr: String?
    var dep: String?
    var status: String?

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime]
        if let d = a.date(from: s) { return d }
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return b.date(from: s)
    }
    var schArrDate: Date? { Station.parse(schArr) }
    var schDepDate: Date? { Station.parse(schDep) }
    var arrDate: Date? { Station.parse(arr) }
    var depDate: Date? { Station.parse(dep) }
    var timeZone: TimeZone { tz.flatMap { TimeZone(identifier: $0) } ?? .current }
    var hasDeparted: Bool { (status ?? "").caseInsensitiveCompare("Departed") == .orderedSame }
    var isAtStation: Bool { (status ?? "").caseInsensitiveCompare("Station") == .orderedSame }
    /// Sort key: scheduled arrival, falling back to scheduled departure.
    var schedKey: Date? { schArrDate ?? schDepDate }
}

struct Train: Codable, Equatable {
    var routeName: String?
    var trainNum: String?
    var trainID: String?
    var trainState: String?
    var origCode: String?
    var origName: String?
    var originTZ: String?
    var lat: Double?
    var lon: Double?
    var heading: String?
    var velocity: Double?
    var destName: String?
    var eventName: String?
    var lastValTS: String?
    var updatedAt: String?
    var stations: [Station]?
}

/// The API returns `{ "<trainNum>": [Train, ...] }`.
struct TrainsResponse: Decodable {
    let runs: [String: [Train]]
    init(from decoder: Decoder) throws {
        runs = try decoder.singleValueContainer().decode([String: [Train]].self)
    }
}
