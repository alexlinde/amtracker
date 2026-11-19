import SwiftUI

// MARK: - Presentation helpers

/// Derived strings/colors for a Live Activity, shared by the Lock Screen and Dynamic Island layouts.
struct ActivityPresenter {
    let attrs: TrainActivityAttributes
    let state: TrainActivityAttributes.ContentState
    var isStale: Bool = false

    var tz: TimeZone { TimeZone(identifier: attrs.stationTZ) ?? .current }
    private func clock(_ d: Date) -> (String, String) { DisplayBuilder.clock(d, tz: tz) }

    var etaDate: Date { state.eta }
    var etaTime: String { clock(etaDate).0 }
    var etaAmPm: String { clock(etaDate).1 }
    var etaFull: String { etaTime + etaAmPm }
    var scheduledText: String { "Scheduled \(clock(state.scheduled).0)\(clock(state.scheduled).1)" }
    var updatedText: String { state.updatedEpoch > 0 ? "Updated \(clock(state.updated).0)\(clock(state.updated).1)" : "" }
    var delayText: String { state.phase == "scheduled" || state.phase == "unknown" ? "No estimate yet" : DisplayBuilder.delayText(state.delayMinutes) }

    var color: Color {
        switch state.statusColor {
        case "green": return Theme.green
        case "orange": return Theme.orange
        case "red": return Theme.red
        default: return .gray
        }
    }

    /// Phase-specific headline replacing the delay text ("At Truckee now", "Departed 2:31p").
    var phaseLine: String {
        switch state.phase {
        case "atStation": return "At \(attrs.stationName) now"
        case "departed": return "Departed \(etaFull)"
        default: return delayText
        }
    }

    var showsCountdown: Bool { (state.phase == "enroute" || state.phase == "scheduled") && etaDate > Date() }

    var stopsText: String {
        switch state.stopsAway {
        case ..<0: return ""
        case 0: return state.nextStopName.isEmpty ? "next stop" : ""
        case 1: return "1 stop away"
        default: return "\(state.stopsAway) stops away"
        }
    }

    var footer: String {
        var parts: [String] = []
        if !state.nextStopName.isEmpty { parts.append("Next: \(state.nextStopName)") }
        if !stopsText.isEmpty { parts.append(stopsText) }
        parts.append(isStale ? "Updating…" : updatedText)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

