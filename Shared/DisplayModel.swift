import Foundation

enum StatusLevel: String, Codable { case onTime, delayed, late }

struct TrainDisplay: Codable, Equatable {
    var trainNum: String
    var routeName: String
    var stationCode: String
    var stationName: String
    var headerLabel: String      // ESTIMATED ARRIVAL / ARRIVED / DEPARTURE ...
    var shortHeader: String      // ARRIVAL / DEPARTURE
    var statusLabel: String      // On Time / Delayed / Departed / At Station
    var level: StatusLevel
    var timeText: String         // "2:27"
    var ampm: String             // "p"
    var delayText: String        // "26 minutes late"
    var scheduledText: String    // "Scheduled 2:01p"
    var dateText: String         // "Thu, Nov 19"
    var nextStop: String
    var updatedText: String      // "Updated 10:28a"
    var delayMinutes: Int
    var enRoute: Bool            // still approaching the station
    var stale: Bool = false
    var lat: Double? = nil
    var lon: Double? = nil
    var heading: String? = nil
    var velocity: Double? = nil
    var stopCodes: [String]? = nil

    var timeFull: String { timeText + ampm }
}

enum DisplayBuilder {
    static func clock(_ d: Date, tz: TimeZone) -> (String, String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: d)
        let h = c.hour ?? 0, m = c.minute ?? 0
        let h12 = h % 12 == 0 ? 12 : h % 12
        return (String(format: "%d:%02d", h12, m), h < 12 ? "a" : "p")
    }

    static func dateString(_ d: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "EEE, MMM d"
        return f.string(from: d)
    }

    static func delayText(_ minutes: Int) -> String {
        if minutes == 0 { return "On time" }
        let n = abs(minutes)
        let word = minutes > 0 ? "late" : "early"
        if n >= 60 {
            let h = n / 60, m = n % 60
            return m == 0 ? "\(h) hr \(word)" : "\(h) hr \(m) min \(word)"
        }
        return "\(n) minute\(n == 1 ? "" : "s") \(word)"
    }

    static func level(forDelay m: Int) -> StatusLevel {
        m <= 0 ? .onTime : (m >= 60 ? .late : .delayed)
    }

    /// Scheduled/estimated time at the target station (departure for the origin station).
    static func times(_ t: Train, _ st: Station) -> (sched: Date?, est: Date?, departureOnly: Bool) {
        let departureOnly = normalizeCode(t.origCode ?? "") == normalizeCode(st.code ?? "")
            || (st.schArrDate == nil && st.arrDate == nil && st.schDepDate != nil)
        let sched = departureOnly ? (st.schDepDate ?? st.schArrDate) : (st.schArrDate ?? st.schDepDate)
        let est = departureOnly ? (st.depDate ?? st.arrDate) : (st.arrDate ?? st.depDate)
        return (sched, est, departureOnly)
    }

    static func build(_ sel: Selection, now: Date = Date()) -> TrainDisplay {
        let t = sel.train, st = sel.station
        let tz = st.timeZone
        let (sched, est, departureOnly) = times(t, st)
        let shown = est ?? sched
        var delay = 0
        if let est, let sched { delay = Int((est.timeIntervalSince(sched) / 60).rounded()) }
        let hasEstimate = est != nil
        let departed = st.hasDeparted
        let atStation = st.isAtStation

        let lvl = level(forDelay: delay)
        var status: String
        if departed { status = "Departed" }
        else if atStation { status = "At Station" }
        else { status = lvl == .onTime ? "On Time" : "Delayed" }
        if !departed && !atStation && !hasEstimate { status = "Scheduled" }

        let noun = departureOnly ? "DEPARTURE" : "ARRIVAL"
        var header: String
        if departureOnly { header = departed ? "DEPARTED" : "DEPARTURE" }
        else { header = (departed || atStation) ? "ARRIVED" : "ESTIMATED ARRIVAL" }

        let (tt, ap) = shown.map { clock($0, tz: tz) } ?? ("--:--", "")
        let schedText = sched.map { let c = clock($0, tz: tz); return "Scheduled \(c.0)\(c.1)" } ?? ""
        let dateText = (sched ?? shown).map { dateString($0, tz: tz) } ?? ""
        let upd = Station.parse(t.lastValTS) ?? Station.parse(t.updatedAt)
        let updText = upd.map { let c = clock($0, tz: tz); return "Updated \(c.0)\(c.1)" } ?? ""

        return TrainDisplay(
            trainNum: t.trainNum ?? "", routeName: t.routeName ?? "",
            stationCode: normalizeCode(st.code ?? ""), stationName: st.name ?? "",
            headerLabel: header, shortHeader: noun, statusLabel: status, level: lvl,
            timeText: tt, ampm: ap,
            delayText: hasEstimate ? delayText(delay) : "No estimate yet",
            scheduledText: schedText, dateText: dateText,
            nextStop: t.eventName ?? "", updatedText: updText,
            delayMinutes: delay, enRoute: !departed,
            lat: t.lat, lon: t.lon, heading: t.heading, velocity: t.velocity,
            stopCodes: t.stations?.compactMap { $0.code })
    }

    static let sample = TrainDisplay(
        trainNum: "6", routeName: "California Zephyr", stationCode: "TRU", stationName: "Truckee",
        headerLabel: "ESTIMATED ARRIVAL", shortHeader: "ARRIVAL", statusLabel: "Delayed", level: .delayed,
        timeText: "2:27", ampm: "p", delayText: "26 minutes late", scheduledText: "Scheduled 2:01p",
        dateText: "Thu, Nov 19", nextStop: "Truckee", updatedText: "Updated 10:28a",
        delayMinutes: 26, enRoute: true,
        lat: 38.9, lon: -121.2, heading: "NE", velocity: 52)
}

/// Full pipeline used by the widget and app.
func loadDisplay(trainNumber: String, stationCode: String, now: Date = Date()) async throws -> Result<TrainDisplay, SelectionError> {
    let runs = try await AmtrakerClient.runs(trainNumber: trainNumber)
    switch selectRun(runs: runs, stationCode: stationCode, trainNumber: trainNumber, now: now) {
    case .success(let s): return .success(DisplayBuilder.build(s, now: now))
    case .failure(let e): return .failure(e)
    }
}
