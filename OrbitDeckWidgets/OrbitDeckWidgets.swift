import ActivityKit
import SwiftUI
import WidgetKit

/// The next-pass Live Activity (Lock Screen and Dynamic Island).
///
/// KEEP IN SYNC: the app target declares an identical `OrbitDeckPassAttributes`
/// in OrbitStore.swift. ActivityKit hands the content across by type name and
/// Codable shape, so the two copies must match field for field.
struct OrbitDeckPassAttributes: ActivityAttributes {
    enum Source: String, Codable, Hashable {
        /// From the auto-switch priority list.
        case priority
        /// The next pass of any favorite.
        case favorite
    }

    struct ContentState: Codable, Hashable {
        var satellite: String
        var aos: Date
        var los: Date
        var maxElevation: Double
        /// When auto switching will select this satellite (can precede AOS).
        var switchAt: Date?
        var source: Source
        /// True when the pass was already in progress at the last update.
        var inPass: Bool
        /// Show times in UTC (the app's default) rather than local time.
        var utc: Bool
    }
}

struct OrbitDeckPassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbitDeckPassAttributes.self) { context in
            PassLockScreenView(state: context.state, isStale: context.isStale)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            let state = context.state
            let up = PassPhase.isUp(state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(state.satellite).lineLimit(1)
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .font(.headline)
                    .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(up ? "LOS in" : "AOS in").font(.caption2).foregroundStyle(.secondary)
                        PassCountdown(state: state, up: up)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(up ? .orange : .green)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PassDetailLine(state: state)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(state.satellite).lineLimit(1)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.cyan)
                .frame(maxWidth: 76, alignment: .leading)
            } compactTrailing: {
                PassCountdown(state: state, up: up)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(up ? .orange : .green)
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(up ? .orange : .cyan)
            }
            .keylineTint(.cyan)
        }
    }
}

private enum PassPhase {
    /// The app marks the content stale at AOS (when it couldn't refresh), so a
    /// stale upcoming pass is treated as in progress.
    static func isUp(_ state: OrbitDeckPassAttributes.ContentState, isStale: Bool) -> Bool {
        state.inPass || isStale
    }

    static func clock(_ date: Date, utc: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if utc {
            formatter.dateFormat = "HH:mm'Z'"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
        } else {
            formatter.locale = .current
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }
}

/// A self-updating countdown to AOS, or to LOS once the pass is up. The system
/// animates timer text without app updates, and it stops at 0:00.
private struct PassCountdown: View {
    let state: OrbitDeckPassAttributes.ContentState
    let up: Bool

    var body: some View {
        if up {
            Text(timerInterval: state.aos...max(state.aos, state.los), countsDown: true)
                .multilineTextAlignment(.trailing)
        } else {
            let now = Date()
            Text(timerInterval: now...max(now, state.aos), countsDown: true)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct PassDetailLine: View {
    let state: OrbitDeckPassAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AOS \(PassPhase.clock(state.aos, utc: state.utc)) · LOS \(PassPhase.clock(state.los, utc: state.utc)) · max \(Int(state.maxElevation.rounded()))°")
            if let switchAt = state.switchAt {
                Text("Auto switch at \(PassPhase.clock(switchAt, utc: state.utc))")
            } else {
                Text(state.source == .priority ? "Next priority satellite" : "Next favorite pass")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PassLockScreenView: View {
    let state: OrbitDeckPassAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let up = PassPhase.isUp(state, isStale: isStale)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.satellite)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                PassDetailLine(state: state)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(up ? "LOS in" : "AOS in")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                PassCountdown(state: state, up: up)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(up ? .orange : .green)
                    .frame(maxWidth: 90, alignment: .trailing)
            }
        }
    }
}

#Preview("Lock Screen", as: .content, using: OrbitDeckPassAttributes()) {
    OrbitDeckPassLiveActivity()
} contentStates: {
    OrbitDeckPassAttributes.ContentState(satellite: "ISS (ZARYA)", aos: .now.addingTimeInterval(900),
                                         los: .now.addingTimeInterval(1500), maxElevation: 54,
                                         switchAt: .now.addingTimeInterval(840), source: .priority,
                                         inPass: false, utc: true)
    OrbitDeckPassAttributes.ContentState(satellite: "SO-50", aos: .now.addingTimeInterval(-120),
                                         los: .now.addingTimeInterval(480), maxElevation: 31,
                                         switchAt: nil, source: .favorite, inPass: true, utc: false)
}
