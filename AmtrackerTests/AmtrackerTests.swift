import XCTest
import CoreLocation

final class AmtrackerTests: XCTestCase {
    let nov19 = ISO8601DateFormatter().date(from: "2026-11-19T20:00:00Z")!
    let nov17 = ISO8601DateFormatter().date(from: "2026-11-17T20:00:00Z")!
    let nov25 = ISO8601DateFormatter().date(from: "2026-11-25T20:00:00Z")!

    func fixtureRuns() throws -> [Train] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "train6", withExtension: "json"))
        return try AmtrakerClient.decodeRuns(Data(contentsOf: url), trainNumber: "6")
    }

    func testDecodesThreeRuns() throws {
        XCTAssertEqual(try fixtureRuns().count, 3)
    }

    func testPicksUpcomingRunAtDavis() throws {
        let sel = try selectRun(runs: fixtureRuns(), stationCode: " dav ", now: nov19).get()
        XCTAssertEqual(sel.train.trainID, "6-19")
        XCTAssertFalse(sel.station.hasDeparted)
    }

    func testAllDepartedPicksMostRecent() throws {
        let sel = try selectRun(runs: fixtureRuns(), stationCode: "EMY", now: nov19).get()
        XCTAssertEqual(sel.train.trainID, "6-19")
        XCTAssertTrue(sel.station.hasDeparted)
    }

    func testDoesNotStop() throws {
        let r = selectRun(runs: try fixtureRuns(), stationCode: "ZZZ", now: nov19)
        XCTAssertEqual(r, .failure(.doesNotStop(train: "6", code: "ZZZ")))
        XCTAssertEqual(SelectionError.doesNotStop(train: "6", code: "ZZZ").message, "Train 6 doesn't stop at ZZZ")
    }

    func testNoRuns() {
        XCTAssertEqual(selectRun(runs: [], stationCode: "DAV", trainNumber: "6"), .failure(.noActiveRuns(train: "6")))
    }

    func testDelayComputationAtDavis() throws {
        let sel = try selectRun(runs: fixtureRuns(), stationCode: "DAV", now: nov19).get()
        let d = DisplayBuilder.build(sel)
        XCTAssertEqual(d.delayMinutes, 58)
        XCTAssertEqual(d.level, .delayed)
        XCTAssertEqual(d.statusLabel, "Delayed")
        XCTAssertEqual(d.delayText, "58 minutes late")
        XCTAssertEqual(d.timeText, "10:46"); XCTAssertEqual(d.ampm, "a")
        XCTAssertEqual(d.scheduledText, "Scheduled 9:48a")
        XCTAssertEqual(d.headerLabel, "ESTIMATED ARRIVAL")
        XCTAssertEqual(d.dateText, "Thu, Nov 19")
    }

    func testDepartedLabelAndFormatting() throws {
        let runs = try fixtureRuns()
        let r17 = runs.filter { $0.trainID == "6-17" }
        let d = DisplayBuilder.build(try selectRun(runs: r17, stationCode: "DAV").get())
        XCTAssertEqual(d.statusLabel, "Departed")
        XCTAssertEqual(d.headerLabel, "ARRIVED")
        XCTAssertEqual(d.delayMinutes, 19)
    }

    func testDelayTextAndLevels() {
        XCTAssertEqual(DisplayBuilder.delayText(0), "On time")
        XCTAssertEqual(DisplayBuilder.delayText(-5), "5 minutes early")
        XCTAssertEqual(DisplayBuilder.delayText(1), "1 minute late")
        XCTAssertEqual(DisplayBuilder.level(forDelay: -3), .onTime)
        XCTAssertEqual(DisplayBuilder.level(forDelay: 59), .delayed)
        XCTAssertEqual(DisplayBuilder.level(forDelay: 60), .late)
    }

    func testOriginIsDeparture() throws {
        var runs = try fixtureRuns().filter { $0.trainID == "6-19" }
        runs[0].origCode = "DAV"
        let d = DisplayBuilder.build(try selectRun(runs: runs, stationCode: "DAV").get())
        XCTAssertEqual(d.headerLabel, "DEPARTURE")
    }

    func testPrefersTodaysDepartureEvenIfDeparted() throws {
        // On Nov 17 run 6-17 started today; it already left TRU but is still preferred.
        let sel = try selectRun(runs: fixtureRuns(), stationCode: "TRU", now: nov17).get()
        XCTAssertEqual(sel.train.trainID, "6-17")
        let sel19 = try selectRun(runs: fixtureRuns(), stationCode: "TRU", now: nov19).get()
        XCTAssertEqual(sel19.train.trainID, "6-19")
    }

    func testFallsBackWhenNoRunStartedToday() throws {
        // Nov 25: no run started today; fall back to earliest not-departed (6-19 enroute).
        let sel = try selectRun(runs: fixtureRuns(), stationCode: "TRU", now: nov25).get()
        XCTAssertEqual(sel.train.trainID, "6-19")
    }

    func testTruckeeDisplay() throws {
        let d = DisplayBuilder.build(try selectRun(runs: fixtureRuns(), stationCode: "TRU", now: nov19).get())
        XCTAssertEqual(d.timeText, "2:27"); XCTAssertEqual(d.ampm, "p")
        XCTAssertEqual(d.delayText, "26 minutes late")
        XCTAssertEqual(d.scheduledText, "Scheduled 2:01p")
    }

    func testRouteSplitAheadOfTrain() {
        typealias C = CLLocationCoordinate2D
        // Two segments heading north-east joined end to end; train in the middle of the first.
        let a = [C(latitude: 39.0, longitude: -121.0), C(latitude: 39.1, longitude: -120.9), C(latitude: 39.2, longitude: -120.8)]
        let b = [C(latitude: 39.2, longitude: -120.8), C(latitude: 39.3, longitude: -120.7)]
        let r = RouteGeometry.split(paths: [b, a], train: C(latitude: 39.1, longitude: -120.9), heading: 45)
        XCTAssertEqual(r.traveled.first?.latitude ?? 0, 39.0, accuracy: 0.001)
        XCTAssertEqual(r.remaining.last?.latitude ?? 0, 39.3, accuracy: 0.001)
        let r2 = RouteGeometry.split(paths: [b, a], train: C(latitude: 39.1, longitude: -120.9), heading: 225)
        XCTAssertEqual(r2.remaining.last?.latitude ?? 0, 39.0, accuracy: 0.001)
    }

    // MARK: Live Activity content state

    func testContentStateTruckee() throws {
        let run = try XCTUnwrap(fixtureRuns().first { $0.trainID == "6-19" })
        let st = try XCTUnwrap(TrainActivityAttributes.ContentState.make(train: run, stationCode: "tru", now: nov19))
        XCTAssertEqual(st.phase, "enroute")
        XCTAssertEqual(st.statusLabel, "Delayed")
        XCTAssertEqual(st.statusColor, "orange")
        XCTAssertEqual(st.delayMinutes, 26)
        XCTAssertEqual(st.etaEpoch, ISO8601DateFormatter().date(from: "2026-11-19T14:27:00-08:00")!.timeIntervalSince1970)
        XCTAssertEqual(st.scheduledEpoch, ISO8601DateFormatter().date(from: "2026-11-19T14:01:00-08:00")!.timeIntervalSince1970)
        XCTAssertEqual(st.nextStopName, "Davis")
        XCTAssertEqual(st.stopsAway, 4)   // DAV (first non-departed, idx 3) -> TRU (idx 7)
        XCTAssertEqual(st.speedMph, 78)
        XCTAssertEqual(st.updatedEpoch, ISO8601DateFormatter().date(from: "2026-11-19T10:26:10-08:00")!.timeIntervalSince1970)
        XCTAssertEqual(st.lat, 38.2826, accuracy: 0.001)
    }

    func testContentStateNextStopAndDeparted() throws {
        let run = try XCTUnwrap(fixtureRuns().first { $0.trainID == "6-19" })
        XCTAssertEqual(TrainActivityAttributes.ContentState.make(train: run, stationCode: "DAV", now: nov19)?.stopsAway, 0)
        let gone = try XCTUnwrap(TrainActivityAttributes.ContentState.make(train: run, stationCode: "EMY", now: nov19))
        XCTAssertEqual(gone.stopsAway, -1)
        XCTAssertEqual(gone.phase, "departed")
        XCTAssertEqual(gone.statusColor, "gray")
        XCTAssertNil(TrainActivityAttributes.ContentState.make(train: run, stationCode: "ZZZ"))
    }

    func testContentStateJSONRoundTripUsesEpochs() throws {
        let run = try XCTUnwrap(fixtureRuns().first { $0.trainID == "6-19" })
        let st = try XCTUnwrap(TrainActivityAttributes.ContentState.make(train: run, stationCode: "TRU", now: nov19))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(st)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["phase", "statusLabel", "statusColor", "etaEpoch", "scheduledEpoch", "delayMinutes",
                                        "nextStopName", "stopsAway", "lat", "lon", "speedMph", "updatedEpoch"])
        XCTAssertGreaterThan(json["etaEpoch"] as! Double, 1.7e9)
        let attrs = try XCTUnwrap(TrainActivityAttributes(train: run, stationCode: "TRU"))
        XCTAssertEqual(attrs.trainID, "6-19"); XCTAssertEqual(attrs.stationTZ, "America/Los_Angeles")
        XCTAssertEqual(attrs.stationName, "Truckee")
    }
}
