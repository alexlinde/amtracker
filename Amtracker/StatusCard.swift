import SwiftUI

/// Live status card styled like the former medium widget.
struct StatusCard: View {
    let d: TrainDisplay
    let state: TrainActivityAttributes.ContentState?
    var dimmed = false

    private var stopsText: String? {
        guard let n = state?.stopsAway, n >= 0 else { return nil }
        // "Next: <station>" already says it when the target is the next stop.
        if n == 0 { return d.nextStop.isEmpty ? "next stop" : nil }
        return "\(n) stop\(n == 1 ? "" : "s") away"
    }
    private var speedText: String? {
        guard let v = d.velocity else { return nil }
        return v < 1 ? "Stopped" : "\(Int(v.rounded())) mph"
    }
    private var footer: String {
        [d.nextStop.isEmpty ? nil : "Next: \(d.nextStop)", stopsText, speedText, d.updatedText.isEmpty ? nil : d.updatedText]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "tram.fill").font(.system(size: 13))
                    Text("\(d.trainNum) \(d.routeName)").font(.system(size: 13, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text("\(d.stationName) \(d.stationCode)").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(Theme.blue)
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.color(d.level)).frame(width: 9, height: 9)
                            Text(d.statusLabel).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        }
                        Text(d.delayText).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                        Text(d.scheduledText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(d.headerLabel).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(d.timeText).font(.system(size: 40, weight: .semibold, design: .rounded))
                            Text(d.ampm).font(.system(size: 17, weight: .semibold, design: .rounded))
                        }
                        .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
            Text(footer).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                .lineLimit(2).minimumScaleFactor(0.8)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.navy)
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        .opacity(dimmed ? 0.6 : 1)
    }
}
