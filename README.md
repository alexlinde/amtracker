# Amtracker

An iOS app that tracks the live status of a specific Amtrak train and its estimated arrival at a station you choose, with a Lock Screen / Dynamic Island Live Activity. Defaults: train 6 (California Zephyr) at TRU (Truckee). (The home-screen/lock-screen widgets were removed; the widget extension now contains only the Live Activity.)

## Data source caveat
Data comes from the free, **unofficial** Amtraker API (`https://api-v3.amtraker.com/v3/trains/{trainNum}`). It has no SLA, may change or disappear, and can lag Amtrak. Don't rely on it for connections you can't afford to miss.

## Build and run
1. `brew install xcodegen` (once), then `xcodegen generate` in this folder.
2. Open `Amtracker.xcodeproj` in Xcode (iOS 17+).
3. Select the `Amtracker` and `AmtrackerWidget` targets, Signing & Capabilities, and set your Team (bundle ids `com.somefamilies.amtracker` / `.widget`).
4. Choose your device (or a simulator) and Run.

Tests: `xcodebuild test -scheme Amtracker -destination 'platform=iOS Simulator,name=<an iPhone>'`.

## The app
One screen: a config bar (train number, station code, Load), a live status card (status, ETA at the station in its time zone, delay, scheduled time, next stop, stops away, speed, updated time), the Live Activity control, and a full-width interactive map (pan/zoom). The map draws the bundled route (traveled part solid, remainder lighter), the train (with heading arrow) and the target station; the recenter button frames the train about 70 miles across, and refreshes follow the train unless you have moved the map. The app refreshes every 60 s in the foreground (shared with the Live Activity's local updates).

Run selection: long-distance trains have several runs active at once. The app shows the run that left its origin today (origin time zone); otherwise the earliest run that hasn't yet departed your station, otherwise the most recent.

## Map data
Route geometry and station coordinates are **bundled** in `Shared/Resources` (`routes/<slug>.json`, `stations.json`), so the only runtime network calls are the train status API and MapKit's map tiles. If a route file is missing, a station-to-station polyline is drawn instead. Regenerate the data (stdlib-only Python 3) with:

    python3 scripts/fetch_routes.py [tolerance_meters]

It reads route names from Amtrak's `RoutesList.json`, fetches each route's GeoJSON from `maps.amtrak.com`, simplifies it (Douglas-Peucker, default 50 m), and fetches all station coordinates from the Amtraker API. Output is about 0.6 MB.

## Live Activity (Lock Screen and Dynamic Island)
Tap **Track this trip on Lock Screen** in the app to start a Live Activity for the loaded train/station (same run selection as the widget). It shows the ETA, delay, next stop, stops away and a live countdown on the Lock Screen and in the Dynamic Island. Tap **End tracking** in the app (or dismiss it) to stop; this also calls `DELETE /trips/{id}` on the push server. Relaunching the app re-attaches to a running activity, and while the app is in the foreground it refreshes the activity every 60 s on its own, so it works without a server (iOS will mark it "Updating…" once it goes 15 min without data). In DEBUG builds, launching with `-autostartActivity` starts train 6 / TRU without any taps.

**Push server (optional, for updates while the app is closed).** See `docs/live-activity-contract.md`. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` (gitignored) and set `AMTRACKER_SERVER_URL` and `AMTRACKER_SHARED_SECRET`; they flow into the app's Info.plist and `Shared/ServerConfig.swift`. In xcconfig write URLs as `https:/$()/host` (a bare `//` starts a comment). If unset, token registration is skipped (logged) and the local Live Activity still works.

**Capabilities.** The app target has `NSSupportsLiveActivities` (+ frequent updates) and the **Push Notifications** capability (`Amtracker/Amtracker.entitlements`, `aps-environment`, generated from `project.yml`). Enable it for your Team in Xcode Signing & Capabilities if needed. Builds run from Xcode use the APNs **sandbox** (`apnsEnv = "development"`, compile-time `#if DEBUG`); TestFlight/App Store builds use production. Simulators can run the Live Activity but cannot receive APNs pushes.
