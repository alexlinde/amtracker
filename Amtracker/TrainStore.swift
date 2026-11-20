import Foundation
import MapKit

/// Route geometry split at the train, ready for drawing.
struct RouteOverlay {
    var traveled: [CLLocationCoordinate2D] = []
    var remaining: [CLLocationCoordinate2D] = []
    var other: [[CLLocationCoordinate2D]] = []
    var stops: [(code: String, coord: CLLocationCoordinate2D)] = []
}

/// Loaded train state for the single screen. Refreshes are shared with the Live Activity's local updates.
@MainActor
final class TrainStore: ObservableObject {
    @Published private(set) var display: TrainDisplay?
    @Published private(set) var train: Train?
    @Published private(set) var state: TrainActivityAttributes.ContentState?
    @Published private(set) var route = RouteOverlay()
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    /// Bumped after every successful load so the map can follow the train.
    @Published private(set) var loadCount = 0

    var trainCoordinate: CLLocationCoordinate2D? {
        guard let lat = display?.lat, let lon = display?.lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func refresh(trainNumber: String, stationCode: String, live: LiveActivityManager) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let num = trainNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = normalizeCode(stationCode)
        do {
            let runs = try await AmtrakerClient.runs(trainNumber: num)
            switch selectRun(runs: runs, stationCode: code, trainNumber: num) {
            case .success(let sel):
                let d = DisplayBuilder.build(sel)
                display = d; train = sel.train
                state = TrainActivityAttributes.ContentState.make(train: sel.train, stationCode: code)
                route = Self.overlay(for: d)
                error = nil
                loadCount += 1
            case .failure(let e):
                display = nil; train = nil; state = nil; route = RouteOverlay()
                error = e.message
            }
            await live.refreshLocally(runs: runs)
        } catch is CancellationError {
            // Refresh task was cancelled (e.g. app left the foreground) — not a user-facing error.
        } catch let e as URLError where e.code == .cancelled {
            // Same, surfaced by URLSession.
        } catch {
            self.error = "Couldn't update: \(error.localizedDescription)"   // keep last-known data
        }
    }

    private static func overlay(for d: TrainDisplay) -> RouteOverlay {
        let paths = RouteGeometry.routePaths(routeName: d.routeName, stopCodes: d.stopCodes ?? [])
        var o = RouteOverlay()
        o.stops = (d.stopCodes ?? []).compactMap { c in RouteGeometry.stationCoord(code: c).map { (c, $0) } }
        if let lat = d.lat, let lon = d.lon {
            let r = RouteGeometry.split(paths: paths, train: .init(latitude: lat, longitude: lon),
                                        heading: RouteGeometry.headingDegrees(d.heading))
            o.traveled = r.traveled; o.remaining = r.remaining; o.other = r.other
        } else {
            o.other = paths
        }
        return o
    }
}
