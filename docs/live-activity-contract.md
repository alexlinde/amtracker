# Live Activity ↔ push server contract

Single source of truth for the iOS app/widget and the `server/` Cloud Run service.
Both sides MUST match this exactly (field names, types, units).

## Overview

1. User taps **Track this trip** in the app → app picks the run (same selection logic as the widget),
   starts an `Activity<TrainActivityAttributes>` with `pushType: .token`.
2. App receives the activity push token (`activity.pushTokenUpdates`) and POSTs it to the server
   (`POST /trips`). Re-POST whenever the token changes.
3. Cloud Scheduler calls `POST /tick` every minute. The server fetches each active train from
   Amtraker, computes the content state for the trip's **locked run** (`trainID`), and sends an APNs
   Live Activity push only if the content state changed (or ≥15 min since last push, as a heartbeat).
4. Server ends the activity (APNs `event: "end"`) when the train has departed the target station
   (or arrived, if it's the terminus) + 10 min, or 12 h after the trip was registered,
   then deletes the trip doc. App calls `DELETE /trips/{activityId}` if the user ends it locally.

## Swift types (Shared/, compiled into app AND widget extension)

```swift
import ActivityKit

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
        var stopsAway: Int          // number of stops between train and target station (0 = next stop is target), -1 if passed/unknown
        var lat: Double             // train position, 0 if unknown
        var lon: Double
        var speedMph: Int           // rounded velocity
        var updatedEpoch: Double    // Amtraker lastValTS (or updatedAt), UNIX seconds
    }
}
```

**IMPORTANT – dates:** all times are `Double` UNIX epoch seconds. Do NOT use `Date` in ContentState:
ActivityKit decodes push `content-state` with the default `JSONDecoder` (Date = seconds since 2001),
which silently breaks server-sent dates. Convert in the view: `Date(timeIntervalSince1970:)`.

All ContentState fields are always present in every push (no optionals) — decoding fails otherwise.

## Server HTTP API

Base URL: Cloud Run service URL (e.g. `https://amtracker-push-xxxx-uw.a.run.app`).
Auth: every app request sends `Authorization: Bearer <APP_SHARED_SECRET>`.
Scheduler requests send `X-Tick-Secret: <TICK_SECRET>`.

### `POST /trips`
```json
{
  "activityId": "uuid-string",
  "pushToken": "hex-string",
  "apnsEnv": "development",           // "development" (Xcode builds) | "production" (TestFlight/App Store)
  "trainNum": "6",
  "trainID": "6-19",
  "stationCode": "TRU"
}
```
Upsert by `activityId`. Response `200 {"ok":true}`. Server immediately computes and sends one update.

### `DELETE /trips/{activityId}`
Response `200 {"ok":true}` (idempotent).

### `POST /tick`
Called by Cloud Scheduler every minute. Response `200 {"trips":N,"pushed":M,"ended":K}`.

### `GET /health` → `200 ok`

## APNs push format

- Host: `api.sandbox.push.apple.com` if `apnsEnv == "development"`, else `api.push.apple.com`. HTTP/2, path `/3/device/{pushToken}`.
- Headers: `apns-push-type: liveactivity`, `apns-topic: <APP_BUNDLE_ID>.push-type.liveactivity`
  (APP_BUNDLE_ID = `com.somefamilies.amtracker`), `apns-priority: 5` for routine updates, `10` when
  `statusLabel`/`phase` changes or delay changes by ≥5 min, `authorization: bearer <JWT>` (ES256, kid = key id,
  iss = team id, iat; cache ≤ 50 min).
- Body:
```json
{ "aps": {
    "timestamp": 1763575000,
    "event": "update",                  // or "end"
    "content-state": { ...ContentState... },
    "stale-date": 1763575900,           // timestamp + 15 min
    "dismissal-date": 1763576200        // only with event "end"
} }
```
- On APNs `410` or `400 BadDeviceToken`/`ExpiredToken`: delete the trip doc.

## Firestore

Collection `trips`, doc id = `activityId`. Fields: request fields + `createdAt`, `lastPushAt`,
`lastStateHash`, `lastState` (map).
