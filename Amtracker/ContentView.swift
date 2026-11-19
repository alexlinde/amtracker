import SwiftUI

struct ContentView: View {
    @AppStorage("trainNumber") private var trainNumber = "6"
    @AppStorage("stationCode") private var stationCode = "TRU"
    @EnvironmentObject private var live: LiveActivityManager
    @EnvironmentObject private var store: TrainStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 10) {
            configBar
            statusSection
            liveControl
            TrainMapView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary))
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        // Foreground auto-refresh every 60s (shared with the Live Activity's local updates).
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func reload() async {
        await store.refresh(trainNumber: trainNumber, stationCode: stationCode, live: live)
    }

    private var configBar: some View {
        HStack(spacing: 8) {
            TextField("Train #", text: $trainNumber)
                .keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder)
                .frame(maxWidth: 90)
            TextField("Station", text: $stationCode)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .onChange(of: stationCode) { _, v in
                    let u = v.uppercased(); if u != v { stationCode = u }
                }
            Button { Task { await reload() } } label: {
                Group { if store.loading { ProgressView() } else { Label("Load", systemImage: "arrow.clockwise") } }
                    .frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent).disabled(store.loading)
        }
        .submitLabel(.go)
        .onSubmit { Task { await reload() } }
    }

    @ViewBuilder private var statusSection: some View {
        if let d = store.display {
            VStack(spacing: 4) {
                StatusCard(d: d, state: store.state, dimmed: store.error != nil)
                if let e = store.error { Text(e).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            }
        } else if let e = store.error {
            Label(e, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Theme.orange)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        } else {
            HStack { ProgressView(); Text("Loading train…").font(.subheadline).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }

    private var liveControl: some View {
        HStack(spacing: 10) {
            if live.activity != nil {
                Button(role: .destructive) { Task { await live.endTracking() } } label: {
                    Label("End tracking", systemImage: "stop.circle").lineLimit(1).fixedSize()
                }.buttonStyle(.bordered)
            } else {
                Button {
                    Task { await live.start(trainNumber: trainNumber.trimmingCharacters(in: .whitespaces), stationCode: stationCode) }
                } label: { Label("Track on Lock Screen", systemImage: "lock.iphone").lineLimit(1).minimumScaleFactor(0.75) }
                    .buttonStyle(.borderedProminent)
            }
            Text(liveStateLine).font(.footnote)
                .foregroundStyle(live.errorMessage == nil ? Color.secondary : Color.red)
                .lineLimit(2).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    private var liveStateLine: String {
        if let e = live.errorMessage { return e }
        if let a = live.activity, let st = live.state {
            let p = ActivityPresenter(attrs: a.attributes, state: st)
            return "Tracking \(a.attributes.trainNum) at \(a.attributes.stationCode) · ETA \(p.etaFull)"
        }
        return "Not tracking"
    }
}
