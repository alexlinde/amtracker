import ActivityKit
import WidgetKit
import SwiftUI

/// Counting-down timer; ticks on its own without pushes.
struct CountdownText: View {
    let eta: Date
    var body: some View {
        Text(timerInterval: Date()...max(eta, Date().addingTimeInterval(1)), countsDown: true)
            .monospacedDigit()
    }
}

// MARK: - Lock Screen / banner

struct TrainLockScreenView: View {
    let p: ActivityPresenter

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "tram.fill").font(.system(size: 13))
                    Text("\(p.attrs.trainNum) \(p.attrs.routeName)").font(.system(size: 13, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text("\(p.attrs.stationName) \(p.attrs.stationCode)")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(Theme.blue)

                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle().fill(p.color).frame(width: 9, height: 9)
                            Text(p.state.statusLabel).font(.system(size: 14, weight: .bold)).lineLimit(1)
                        }
                        Text(p.isStale ? "Updating…" : p.phaseLine)
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                        if p.showsCountdown && !p.isStale {
                            HStack(spacing: 3) {
                                Text("in").foregroundStyle(.secondary)
                                CountdownText(eta: p.etaDate)
                            }
                            .font(.system(size: 12)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(p.etaTime).font(.system(size: 38, weight: .semibold, design: .rounded))
                            Text(p.etaAmPm).font(.system(size: 16, weight: .semibold, design: .rounded))
                        }
                        .lineLimit(1).minimumScaleFactor(0.6)
                        Text(p.scheduledText).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

            HStack {
                Text(p.footer).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 26).frame(maxWidth: .infinity)
            .background(Theme.navy)
        }
        .opacity(p.isStale ? 0.7 : 1)
    }
}

// MARK: - Dynamic Island pieces

struct IslandTrainIcon: View {
    var body: some View { Image(systemName: "tram.fill").foregroundStyle(Theme.blue) }
}

// MARK: - Widget

struct TrainLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainActivityAttributes.self) { context in
            TrainLockScreenView(p: ActivityPresenter(attrs: context.attributes, state: context.state, isStale: context.isStale))
                .activityBackgroundTint(Theme.background)
                .activitySystemActionForegroundColor(Theme.blue)
        } dynamicIsland: { context in
            let p = ActivityPresenter(attrs: context.attributes, state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        IslandTrainIcon()
                        Text(p.attrs.trainNum).font(.system(size: 17, weight: .bold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(p.etaTime).font(.system(size: 24, weight: .semibold, design: .rounded))
                        Text(p.etaAmPm).font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .opacity(p.isStale ? 0.6 : 1)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 0) {
                        Text(p.attrs.stationName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(p.attrs.routeName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(p.color).frame(width: 8, height: 8)
                            Text(p.isStale ? "Updating…" : "\(p.state.statusLabel) · \(p.phaseLine)")
                                .font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                            if p.showsCountdown && !p.isStale {
                                CountdownText(eta: p.etaDate).font(.system(size: 12, weight: .medium))
                            }
                        }
                        let next = [p.state.nextStopName.isEmpty ? nil : "Next: \(p.state.nextStopName)",
                                    p.stopsText.isEmpty ? nil : p.stopsText].compactMap { $0 }.joined(separator: " · ")
                        if !next.isEmpty {
                            Text(next).font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    IslandTrainIcon()
                    Text(p.attrs.stationCode).font(.system(size: 13, weight: .semibold))
                }
            } compactTrailing: {
                Text(p.etaTime).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(p.isStale ? .secondary : p.color)
            } minimal: {
                IslandTrainIcon()
            }
            .keylineTint(Theme.blue)
        }
    }
}

@main
struct AmtrackerWidgetBundle: WidgetBundle {
    var body: some Widget { TrainLiveActivity() }
}
