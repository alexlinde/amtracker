import Foundation

enum SelectionError: Error, Equatable {
    case noActiveRuns(train: String)
    case doesNotStop(train: String, code: String)

    var message: String {
        switch self {
        case .noActiveRuns(let t): return "Train \(t) isn't running right now"
        case .doesNotStop(let t, let c): return "Train \(t) doesn't stop at \(c)"
        }
    }
}

struct Selection: Equatable {
    let train: Train
    let station: Station
}

func normalizeCode(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

/// Picks which active run to show for a station.
func selectRun(runs: [Train], stationCode: String, trainNumber: String = "", now: Date = Date()) -> Result<Selection, SelectionError> {
    let code = normalizeCode(stationCode)
    if runs.isEmpty { return .failure(.noActiveRuns(train: trainNumber)) }
    let candidates: [Selection] = runs.compactMap { t in
        guard let st = t.stations?.first(where: { normalizeCode($0.code ?? "") == code }) else { return nil }
        return Selection(train: t, station: st)
    }
    if candidates.isEmpty {
        return .failure(.doesNotStop(train: runs.first?.trainNum ?? trainNumber, code: code))
    }
    // Prefer the run that departed its origin today (origin time zone).
    let todays = candidates.filter { startsToday($0.train, now: now) }
    if let first = todays.min(by: { ($0.station.schedKey ?? .distantFuture) < ($1.station.schedKey ?? .distantFuture) }) {
        return .success(first)
    }
    func key(_ s: Selection) -> Date { s.station.schedKey ?? .distantFuture }
    let upcoming = candidates.filter { !$0.station.hasDeparted }
    if let best = upcoming.min(by: { key($0) < key($1) }) { return .success(best) }
    // all departed: most recent
    let best = candidates.max(by: { ($0.station.schedKey ?? .distantPast) < ($1.station.schedKey ?? .distantPast) })!
    return .success(best)
}

/// True if the run's origin-station scheduled departure falls on `now`'s calendar date in the origin time zone.
func startsToday(_ t: Train, now: Date) -> Bool {
    guard let origin = t.stations?.first, let dep = origin.schDepDate ?? origin.schArrDate else { return false }
    let tz = origin.tz.flatMap { TimeZone(identifier: $0) } ?? t.originTZ.flatMap { TimeZone(identifier: $0) } ?? .current
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal.isDate(dep, inSameDayAs: now)
}
