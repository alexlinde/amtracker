import Foundation
import ActivityKit

/// Live Activity type. MUST match docs/live-activity-contract.md exactly (the push server encodes
/// `ContentState` as JSON). All times are UNIX epoch Doubles (never Date) and nothing is optional.
struct TrainActivityAttributes: ActivityAttributes {
    // static for the life of the activity
    var trainNum: String        // "6"
    var routeName: String       // "California Zephyr"
    var trainID: String         // "6-19"  (Amtraker run id; server locks to this run)
    var stationCode: String     // "TRU"
    var stationName: String     // "Truckee"
    var stationTZ: String       // IANA, e.g. "America/Los_Angeles"

    struct ContentState: Codable, Hashable {
        var phase: String           // "scheduled" | "enroute" | "atStation" | "departed" | "unknown"
        var statusLabel: String     // "On Time" | "Delayed" | "Arrived" | "Departed" | ...
        var statusColor: String     // "green" | "orange" | "red" | "gray"
        var etaEpoch: Double        // est/actual arrival at target station, UNIX seconds (origin station: departure)
        var scheduledEpoch: Double  // scheduled arrival at target station, UNIX seconds
        var delayMinutes: Int       // positive = late, negative = early, 0 = on time
        var nextStopName: String    // train's next stop (eventName), "" if unknown
        var stopsAway: Int          // stops between train and target (0 = next stop is target), -1 if passed/unknown
        var lat: Double             // train position, 0 if unknown
        var lon: Double
        var speedMph: Int           // rounded velocity
        var updatedEpoch: Double    // Amtraker lastValTS (or updatedAt), UNIX seconds
    }
}

extension TrainActivityAttributes {
    /// Static attributes for a selected run at its target station.
    init?(train: Train, stationCode: String) {
        let code = normalizeCode(stationCode)
        guard let st = train.stations?.first(where: { normalizeCode($0.code ?? "") == code }) else { return nil }
        self.init(trainNum: train.trainNum ?? "", routeName: train.routeName ?? "",
                  trainID: train.trainID ?? "", stationCode: code,
                  stationName: st.name ?? code, stationTZ: st.timeZone.identifier)
    }
}

extension TrainActivityAttributes.ContentState {
    var eta: Date { Date(timeIntervalSince1970: etaEpoch) }
    var scheduled: Date { Date(timeIntervalSince1970: scheduledEpoch) }
    var updated: Date { Date(timeIntervalSince1970: updatedEpoch) }

    /// Pure function: ContentState for a run at a station. Reuses `DisplayBuilder` so numbers match the widget.
    /// Returns nil if the run doesn't stop at `stationCode`.
    static func make(train: Train, stationCode: String, now: Date = Date()) -> TrainActivityAttributes.ContentState? {
        let code = normalizeCode(stationCode)
        guard let idx = train.stations?.firstIndex(where: { normalizeCode($0.code ?? "") == code }),
              let stations = train.stations else { return nil }
        let st = stations[idx]
        let d = DisplayBuilder.build(Selection(train: train, station: st), now: now)
        let (sched, est, _) = DisplayBuilder.times(train, st)

        let phase: String
        if st.hasDeparted { phase = "departed" }
        else if st.isAtStation { phase = "atStation" }
        else if est == nil && sched == nil { phase = "unknown" }
        else if est == nil { phase = "scheduled" }
        else { phase = "enroute" }

        let color: String
        switch phase {
        case "scheduled", "unknown", "departed": color = "gray"
        default:
            switch d.level { case .onTime: color = "green"; case .delayed: color = "orange"; case .late: color = "red" }
        }
        let label = phase == "atStation" ? "Arrived" : d.statusLabel

        let firstActive = stations.firstIndex(where: { !$0.hasDeparted })
        let away = st.hasDeparted ? -1 : (firstActive.map { idx - $0 } ?? -1)

        let upd = Station.parse(train.lastValTS) ?? Station.parse(train.updatedAt) ?? now
        let shown = est ?? sched
        return .init(
            phase: phase, statusLabel: label, statusColor: color,
            etaEpoch: (shown ?? now).timeIntervalSince1970,
            scheduledEpoch: (sched ?? shown ?? now).timeIntervalSince1970,
            delayMinutes: d.delayMinutes,
            nextStopName: train.eventName ?? "",
            stopsAway: away,
            lat: train.lat ?? 0, lon: train.lon ?? 0,
            speedMph: Int((train.velocity ?? 0).rounded()),
            updatedEpoch: upd.timeIntervalSince1970)
    }

    /// Convenience: apply the same run-selection logic as the widget, then compute the state.
    static func select(runs: [Train], stationCode: String, trainNumber: String, now: Date = Date())
        -> (TrainActivityAttributes, TrainActivityAttributes.ContentState)? {
        guard case .success(let sel) = selectRun(runs: runs, stationCode: stationCode, trainNumber: trainNumber, now: now),
              let attrs = TrainActivityAttributes(train: sel.train, stationCode: stationCode),
              let state = make(train: sel.train, stationCode: stationCode, now: now) else { return nil }
        return (attrs, state)
    }
}
