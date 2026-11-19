import Foundation
import ActivityKit
import os

private let log = Logger(subsystem: "com.somefamilies.amtracker", category: "LiveActivity")

/// Starts/ends the train Live Activity, registers its push token with the server, and refreshes it locally.
@MainActor
final class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    @Published private(set) var activity: Activity<TrainActivityAttributes>?
    @Published private(set) var state: TrainActivityAttributes.ContentState?
    @Published var errorMessage: String?

    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var stateTask: Task<Void, Never>?
    private static let staleInterval: TimeInterval = 15 * 60

    // MARK: Lifecycle

    /// Re-attach to activities that outlived the app process and re-register their tokens.
    func reattach() {
        let existing = Activity<TrainActivityAttributes>.activities
        guard let a = existing.first(where: { $0.activityState == .active }) ?? existing.first else { return }
        adopt(a)
    }

    func start(trainNumber: String, stationCode: String) async {
        errorMessage = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            errorMessage = "Live Activities are disabled in Settings."; return
        }
        do {
            let now = Date()
            let runs = try await AmtrakerClient.runs(trainNumber: trainNumber)
            guard let (attrs, st) = TrainActivityAttributes.ContentState.select(
                runs: runs, stationCode: stationCode, trainNumber: trainNumber, now: now) else {
                errorMessage = "Couldn't find train \(trainNumber) at \(normalizeCode(stationCode))."; return
            }
            // One tracked trip at a time.
            if let old = activity { await end(old) }
            let content = ActivityContent(state: st, staleDate: now.addingTimeInterval(Self.staleInterval))
            let a = try Activity.request(attributes: attrs, content: content, pushType: .token)
            adopt(a)
        } catch {
            log.error("start failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Ends locally (with final content) and tells the server to forget the trip.
    func endTracking() async {
        guard let a = activity else { return }
        await end(a)
    }

    private func end(_ a: Activity<TrainActivityAttributes>) async {
        let id = a.id
        let final = ActivityContent(state: a.content.state, staleDate: nil)
        await a.end(final, dismissalPolicy: .immediate)
        tokenTasks[id]?.cancel(); tokenTasks[id] = nil
        if activity?.id == id { detach() }
        await TripServer.delete(activityId: id)
    }

    private func detach() {
        stateTask?.cancel()
        stateTask = nil
        activity = nil; state = nil
    }

    private func adopt(_ a: Activity<TrainActivityAttributes>) {
        detach()
        activity = a
        state = a.content.state
        let attrs = a.attributes
        if tokenTasks[a.id] == nil {
            tokenTasks[a.id] = Task { [id = a.id] in
                for await data in a.pushTokenUpdates {
                    let hex = data.map { String(format: "%02x", $0) }.joined()
                    await TripServer.register(activityId: id, pushToken: hex, attributes: attrs)
                }
            }
        }
        stateTask = Task { [weak self] in
            for await s in a.activityStateUpdates {
                if s == .ended || s == .dismissed {
                    // Ended by the system, the user, or the server.
                    await TripServer.delete(activityId: a.id)
                    self?.handleEnded(id: a.id)
                    return
                }
            }
        }
        Task { [weak self] in
            for await c in a.contentUpdates { self?.state = c.state }
        }
    }

    private func handleEnded(id: String) {
        tokenTasks[id]?.cancel(); tokenTasks[id] = nil
        if activity?.id == id { detach() }
    }

    // MARK: Local refresh (foreground only; works without the server)

    /// Compute + update from already-fetched `runs` (shared with the app's 60s refresh), or fetch if nil.
    func refreshLocally(runs given: [Train]? = nil) async {
        guard let a = activity, a.activityState == .active else { return }
        let attrs = a.attributes
        do {
            var runs = given ?? []
            if runs.first?.trainNum != attrs.trainNum { runs = try await AmtrakerClient.runs(trainNumber: attrs.trainNum) }
            // Stay locked to the run chosen at start, like the server does.
            guard let run = runs.first(where: { $0.trainID == attrs.trainID }),
                  let st = TrainActivityAttributes.ContentState.make(train: run, stationCode: attrs.stationCode) else { return }
            let content = ActivityContent(state: st, staleDate: Date().addingTimeInterval(Self.staleInterval))
            await a.update(content)
            state = st
        } catch {
            log.error("local refresh failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Server client

/// Minimal client for the push server (docs/live-activity-contract.md). Never throws; logs failures.
enum TripServer {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 15
        return URLSession(configuration: c)
    }()

    static func register(activityId: String, pushToken: String, attributes a: TrainActivityAttributes) async {
        guard let req = request(path: "trips", method: "POST") else {
            log.info("Server not configured (AMTRACKER_SERVER_URL / AMTRACKER_SHARED_SECRET); skipping token registration")
            return
        }
        var req2 = req
        let body: [String: String] = [
            "activityId": activityId, "pushToken": pushToken, "apnsEnv": ServerConfig.apnsEnv,
            "trainNum": a.trainNum, "trainID": a.trainID, "stationCode": a.stationCode,
        ]
        req2.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await send(req2, what: "POST /trips")
    }

    static func delete(activityId: String) async {
        guard let enc = activityId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let req = request(path: "trips/\(enc)", method: "DELETE") else {
            log.info("Server not configured; skipping DELETE /trips")
            return
        }
        await send(req, what: "DELETE /trips")
    }

    private static func request(path: String, method: String) -> URLRequest? {
        guard let base = ServerConfig.baseURL, let secret = ServerConfig.sharedSecret else { return nil }
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 15
        r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return r
    }

    private static func send(_ req: URLRequest, what: String) async {
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.error("\(what) failed: HTTP \(http.statusCode)")
            }
        } catch {
            log.error("\(what) failed: \(error.localizedDescription)")
        }
    }
}
