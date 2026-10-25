import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Identifiable wrapper so a prepared file URL can drive a `.sheet(item:)`.
struct ShareURLItem: Identifiable { let url: URL; var id: URL { url } }

extension Binding where Value == Double {
    /// A gentle center detent: snaps to `center` whenever a set value lands within
    /// `threshold`, so a slider whose neutral default is the center "sticks" there.
    func snapping(to center: Double, within threshold: Double) -> Binding<Double> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = abs($0 - center) <= threshold ? center : $0 }
        )
    }
}

/// Menu picker for a satellite's transponders, isolated from its host's redraws.
///
/// The hosts (Home, Orbital Analysis, Doppler planner) re-render continuously —
/// compass-up heading updates arrive unfiltered, and live look/Doppler readouts
/// tick every second. Rebuilding an inline `.menu` Picker while its menu is open
/// can swallow the tap or snap back to the old choice, which is what made
/// transponder switching feel "sticky". As an `.equatable()` view whose identity
/// is just the transponder list and the current selection, its body only re-runs
/// when one of those actually changes, so an open menu is left alone.
struct TransponderPicker: View, @MainActor Equatable {
    let transponders: [TransponderRecord]
    @Binding var selection: String?

    var body: some View {
        Picker("Transponder", selection: Binding(
            // A stale ID (list refreshed or reordered underneath us) falls back to
            // the first transponder, matching what the hosts display, so the menu
            // never shows an unmatched selection.
            get: { resolvedID },
            set: { selection = $0 }
        )) {
            ForEach(transponders) { tp in
                Text(tp.description.isEmpty ? tp.kind : tp.description).tag(Optional(tp.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var resolvedID: String? {
        if let selection, transponders.contains(where: { $0.id == selection }) { return selection }
        return transponders.first?.id
    }

    static func == (lhs: TransponderPicker, rhs: TransponderPicker) -> Bool {
        lhs.transponders == rhs.transponders && lhs.selection == rhs.selection
    }
}

/// Reverse-geocodes the observer position while following the current location and
/// hands the resolved DXCC entity / administrative subdivisions to a content
/// builder, so different screens (Home card, Settings form) can render the same
/// data in their own row style. Renders nothing in fixed-site mode or before the
/// lookup resolves. Re-geocodes only when the coarse position changes.
struct CurrentLocationEntityInfo<Content: View>: View {
    @EnvironmentObject private var store: OrbitStore
    @ViewBuilder let content: (GeoLocationEntity) -> Content

    var body: some View {
        // Purely reactive: the store reverse-geocodes on the location-update path
        // and publishes `currentLocationEntity`, so this renders reliably without
        // depending on a conditionally-rendered view's `.task` lifecycle.
        if store.locationMode == .currentLocation,
           let info = store.currentLocationEntity, info.hasAnything {
            content(info)
        }
    }
}

#if canImport(UIKit)
/// The system share sheet, presented programmatically (so exports open the share
/// UI directly rather than surfacing a button in an unrelated section).
struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

enum ODFormat {
    /// Operator preference: when true, all displayed times use the device's local
    /// zone instead of UTC. Driven from the store (see OrbitStore.loadPreferences).
    /// Tiny BASIC deliberately ignores this and always uses UTC.
    nonisolated(unsafe) static var useLocalTime = false

    // UTC is always 24-hour with a literal 'UTC' (the ham convention; `zzz` in the
    // GMT zone renders "GMT"). POSIX locale pins 24-hour regardless of the device.
    private static func fixedUTC(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }
    // Whether the device is set to 24-hour time. `j` resolves to the locale's
    // preferred hour field; a 12-hour locale includes the AM/PM ('a') symbol.
    private static let deviceUses24Hour: Bool = {
        let t = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "H"
        return !t.contains("a")
    }()
    // Local formatters honor the device's 12/24-hour preference and current locale
    // (AM/PM symbols), with the live zone abbreviation via `zzz`.
    private static func local(_ format24: String, _ format12: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = .current
        f.dateFormat = deviceUses24Hour ? format24 : format12
        return f
    }

    private static let utcFull = fixedUTC("yyyy-MM-dd HH:mm:ss 'UTC'")
    private static let localFull = local("yyyy-MM-dd HH:mm:ss zzz", "yyyy-MM-dd h:mm:ss a zzz")
    private static let utcShortFixed = fixedUTC("MMM d HH:mm:ss 'UTC'")
    private static let localShort = local("MMM d HH:mm:ss zzz", "MMM d h:mm:ss a zzz")
    private static let utcDayFixed = fixedUTC("yyyy-MM-dd")
    private static let localDay = local("yyyy-MM-dd", "yyyy-MM-dd")
    private static let utcClock = fixedUTC("HH:mm 'UTC'")
    private static let localClock = local("HH:mm zzz", "h:mm a zzz")
    private static let utcAxis = fixedUTC("HH:mm")
    private static let localAxis = local("HH:mm", "h:mm a")

    /// Compact zone-less clock for chart axis ticks, in the operator's chosen zone.
    static func axisClock(_ date: Date) -> String {
        (useLocalTime ? localAxis : utcAxis).string(from: date)
    }
    /// The zone times are displayed in (UTC unless the local-time preference is on).
    static var displayTimeZone: TimeZone {
        useLocalTime ? .current : TimeZone(secondsFromGMT: 0) ?? .current
    }

    static var utc: DateFormatter { useLocalTime ? localFull : utcFull }
    static var utcShort: DateFormatter { useLocalTime ? localShort : utcShortFixed }

    /// Always-UTC date+time stamp, regardless of the local-time display preference —
    /// the QSO log and ADIF are UTC by ham convention.
    static func utcStamp(_ date: Date) -> String { utcFull.string(from: date) }
    static var utcDay: DateFormatter { useLocalTime ? localDay : utcDayFixed }

    /// Short "HH:mm ZZZ" clock in the operator's chosen zone (for pass lists).
    static func primaryClock(_ date: Date) -> String {
        (useLocalTime ? localClock : utcClock).string(from: date)
    }
    /// The same clock in the *other* zone, for an unobtrusive secondary readout
    /// (e.g. show local next to UTC, or vice-versa). Empty if both would match.
    static func secondaryClock(_ date: Date) -> String {
        (useLocalTime ? utcClock : localClock).string(from: date)
    }

    static func angle(_ degrees: Double, decimals: Int = 1) -> String {
        String(format: "%.*f°", decimals, degrees)
    }

    static func distance(_ km: Double) -> String {
        km >= 10_000 ? String(format: "%.0f km", km) : String(format: "%.1f km", km)
    }

    static func velocity(_ kmS: Double) -> String {
        String(format: "%+.3f km/s", kmS)
    }

    static func frequency(_ hz: Int64) -> String {
        let value = Double(hz)
        if abs(value) >= 1_000_000_000 {
            return String(format: "%.6f GHz", value / 1_000_000_000)
        }
        if abs(value) >= 1_000_000 {
            return String(format: "%.6f MHz", value / 1_000_000)
        }
        if abs(value) >= 1_000 {
            return String(format: "%.3f kHz", value / 1_000)
        }
        return "\(hz) Hz"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0
            ? String(format: "%dh %02dm %02ds", h, m, sec)
            : String(format: "%dm %02ds", m, sec)
    }

    static func compass(_ azimuth: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((azimuth.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 22.5 + 0.5) % 16
        return points[index]
    }
}

struct SelectedSatelliteHeader: View {
    @EnvironmentObject private var store: OrbitStore

    var body: some View {
        HStack(spacing: 10) {
            if let satellite = store.selectedSatellite {
                Image(systemName: "dot.scope")
                    .foregroundStyle(ODTheme.accent)
                Text(satellite.name)
                    .font(.headline)
                Text(verbatim: "NORAD \(satellite.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(ODTheme.muted)
                Spacer()
                // Tap to favorite/unfavorite the currently active satellite without
                // leaving the screen.
                let isFav = store.preferences.favorites.contains(satellite.id)
                Button {
                    store.toggleFavorite(satellite.id)
                } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .foregroundStyle(isFav ? ODTheme.warning : ODTheme.muted)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isFav ? "Remove favorite" : "Add favorite")
            } else {
                Label("No satellite selected", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ODTheme.warning)
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(ODTheme.panel)
    }
}

struct PolarSkyPlot: View {
    var points: [SkyPoint]
    var currentPoint: SkyPoint?
    var minimumElevation: Double = 0
    /// Azimuth (degrees) that should point to the top of the plot. 0 = North up;
    /// pass the device heading for a "compass up" view.
    var orientation: Double = 0

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outerRadius = max(1, side / 2 - 20)

            for elevation in stride(from: 0.0, through: 90.0, by: 30.0) {
                let radius = outerRadius * (90 - elevation) / 90
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(ODTheme.grid),
                    lineWidth: elevation == 0 ? 1.5 : 1
                )
            }

            if minimumElevation > 0 && minimumElevation < 90 {
                let radius = outerRadius * (90 - minimumElevation) / 90
                let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(ODTheme.warning.opacity(0.65)),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
            }

            var cross = Path()
            for cardinal in [0.0, 90.0, 180.0, 270.0] {
                let theta = (cardinal - orientation) * .pi / 180
                cross.move(to: center)
                cross.addLine(to: CGPoint(x: center.x + outerRadius * sin(theta), y: center.y - outerRadius * cos(theta)))
            }
            context.stroke(cross, with: .color(ODTheme.grid.opacity(0.8)), lineWidth: 1)

            // 8-point compass rose around the horizon rim.
            let labelRadius = outerRadius + 12
            let compass: [(String, Double)] = [
                ("N", 0), ("NE", 45), ("E", 90), ("SE", 135),
                ("S", 180), ("SW", 225), ("W", 270), ("NW", 315)
            ]
            for (text, azimuth) in compass {
                let theta = (azimuth - orientation) * .pi / 180
                let location = CGPoint(
                    x: center.x + labelRadius * sin(theta),
                    y: center.y - labelRadius * cos(theta)
                )
                context.draw(
                    Text(text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(text.count == 1 ? ODTheme.muted : ODTheme.muted.opacity(0.7)),
                    at: location
                )
            }

            // Numeric elevation-ring labels (0° horizon, 30°, 60°) along the vertical axis.
            for elevation in [0.0, 30.0, 60.0] {
                let radius = outerRadius * (90 - elevation) / 90
                context.draw(
                    Text(verbatim: "\(Int(elevation))°")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(ODTheme.muted.opacity(0.75)),
                    at: CGPoint(x: center.x + 12, y: center.y - radius + 7)
                )
            }

            if points.count > 1 {
                var path = Path()
                for (index, point) in points.enumerated() {
                    let p = plotPoint(point.azimuth, point.elevation, center, outerRadius)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(ODTheme.accent), lineWidth: 2.5)
            }

            // AOS / LOS marked with small heading arrows pointing along the track,
            // so they read as direction-of-travel and stay clear of the rim compass
            // labels.
            if points.count > 1 {
                let a = points[0], b = points[1]
                if let ang = screenTangent(atAz: a.azimuth, atEl: a.elevation,
                                           dAzDeg: angularDeltaDeg(b.azimuth - a.azimuth),
                                           dElDeg: b.elevation - a.elevation, outerRadius: outerRadius) {
                    drawHeadingArrow(&context, at: plotPoint(a.azimuth, a.elevation, center, outerRadius),
                                     angle: ang, color: ODTheme.good, size: 6)
                }
                let n = points.count
                let p0 = points[n - 2], p1 = points[n - 1]
                if let ang = screenTangent(atAz: p1.azimuth, atEl: p1.elevation,
                                           dAzDeg: angularDeltaDeg(p1.azimuth - p0.azimuth),
                                           dElDeg: p1.elevation - p0.elevation, outerRadius: outerRadius) {
                    drawHeadingArrow(&context, at: plotPoint(p1.azimuth, p1.elevation, center, outerRadius),
                                     angle: ang, color: ODTheme.warning, size: 6)
                }
            }

            // Live position: a small arrow pointing the satellite's direction of
            // travel (only while above the horizon).
            if let currentPoint, currentPoint.elevation >= 0 {
                let p = plotPoint(currentPoint.azimuth, currentPoint.elevation, center, outerRadius)
                let angle = headingAngle(for: currentPoint, outerRadius: outerRadius) ?? -.pi / 2
                drawHeadingArrow(&context, at: p, angle: angle, color: .white, size: 8.5)
                drawHeadingArrow(&context, at: p, angle: angle, color: ODTheme.accent, size: 6.5)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Polar sky plot")
    }

    private func plotPoint(
        _ azimuth: Double,
        _ elevation: Double,
        _ center: CGPoint,
        _ outerRadius: Double
    ) -> CGPoint {
        let theta = (azimuth - orientation) * .pi / 180
        let radius = outerRadius * max(0, min(1, (90 - elevation) / 90))
        return CGPoint(
            x: center.x + radius * sin(theta),
            y: center.y - radius * cos(theta)
        )
    }

    /// Screen-space direction of travel at `point`. Works in **azimuth/elevation
    /// (angular) space** rather than pixel deltas, then maps to the screen tangent
    /// analytically — so it stays correct even when consecutive samples project to
    /// a sub-pixel step (a HEO satellite crawling near apogee), which used to
    /// collapse the old pixel-threshold fallback into a bogus constant. Searches
    /// outward for a neighbour with a meaningful angular separation.
    private func headingAngle(for point: SkyPoint, outerRadius: Double) -> Double? {
        guard points.count > 1 else { return nil }
        var i = 0
        for k in 0..<points.count where points[k].date <= point.date { i = k }
        let minDelta = 0.05     // degrees (combined az+el) that counts as real motion
        // Forward neighbour first (direction of travel), then backward.
        for j in (i + 1)..<points.count {
            let dAz = angularDeltaDeg(points[j].azimuth - point.azimuth)
            let dEl = points[j].elevation - point.elevation
            if abs(dAz) + abs(dEl) >= minDelta {
                return screenTangent(atAz: point.azimuth, atEl: point.elevation, dAzDeg: dAz, dElDeg: dEl, outerRadius: outerRadius)
            }
        }
        for j in stride(from: i, through: 0, by: -1) {
            let dAz = angularDeltaDeg(point.azimuth - points[j].azimuth)
            let dEl = point.elevation - points[j].elevation
            if abs(dAz) + abs(dEl) >= minDelta {
                return screenTangent(atAz: point.azimuth, atEl: point.elevation, dAzDeg: dAz, dElDeg: dEl, outerRadius: outerRadius)
            }
        }
        return nil
    }

    /// The screen-space angle of motion `(dAz, dEl)` evaluated at `(az, el)`, using
    /// the analytic derivative of `plotPoint` (`x = r·sinθ`, `y = −r·cosθ`, with
    /// `θ = (az−orientation)·π/180`, `r = R·(90−el)/90`). Near the zenith `r → 0`
    /// so the `r·dθ` terms vanish and the arrow follows the stable radial `dEl`
    /// motion instead of the ill-defined azimuth — exactly the desired behaviour.
    private func screenTangent(atAz az: Double, atEl el: Double, dAzDeg: Double, dElDeg: Double, outerRadius: Double) -> Double? {
        let dTheta = atan2(sin(dAzDeg * .pi / 180), cos(dAzDeg * .pi / 180))   // short way around, radians
        if abs(dTheta) < 1e-9 && abs(dElDeg) < 1e-9 { return nil }
        let theta = (az - orientation) * .pi / 180
        let r = outerRadius * max(0, min(1, (90 - el) / 90))
        let dr = -outerRadius * dElDeg / 90
        let dx = dr * sin(theta) + r * cos(theta) * dTheta
        let dy = -dr * cos(theta) + r * sin(theta) * dTheta
        if abs(dx) < 1e-12 && abs(dy) < 1e-12 { return nil }
        return atan2(dy, dx)
    }

    /// Difference between two azimuths, wrapped to (−180°, 180°].
    private func angularDeltaDeg(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 } else if x <= -180 { x += 360 }
        return x
    }
}

/// A small, unobtrusive bell toggle for scheduling (or cancelling) a local pass
/// reminder for one pass. Filled bell = a reminder is pending. Shows an alert only
/// on error (e.g. notifications denied, or the pass is too close). Designed to sit
/// beside a pass listing anywhere in the app.
struct PassAlarmButton: View {
    let satellite: SatelliteRecord
    let pass: PredictedPass
    let observer: ObserverSite
    let leadMinutes: Int

    @State private var scheduled = false
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Image(systemName: scheduled ? "bell.fill" : "bell")
                .font(.subheadline)
                .foregroundStyle(scheduled ? ODTheme.accent : ODTheme.muted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(working)
        .accessibilityLabel(scheduled ? "Cancel pass reminder" : "Set pass reminder \(leadMinutes) minutes before AOS")
        .task(id: pass.id) { scheduled = await PassAlarmService.isScheduled(pass: pass, satellite: satellite) }
        .alert("Pass alarm", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func toggle() async {
        working = true
        defer { working = false }
        if scheduled {
            PassAlarmService.cancel(pass: pass, satellite: satellite)
            scheduled = false
        } else {
            do {
                try await PassAlarmService.schedule(pass: pass, satellite: satellite, observer: observer, leadMinutes: leadMinutes)
                scheduled = true
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// Shown in place of the pass-alarm bell when a pass is in progress or already
/// past (no reminder can be set), matching the bell's size so rows stay aligned.
struct PassAlarmUnavailable: View {
    var body: some View {
        Image(systemName: "bell.slash")
            .font(.subheadline)
            .foregroundStyle(ODTheme.muted.opacity(0.5))
            .frame(width: 30, height: 30)
            .accessibilityLabel("No reminder — pass in progress or past")
    }
}

/// Draw a small filled triangular heading arrow centered at `p`, pointing along
/// `angle` (radians, screen space). Used for AOS/LOS and live-position markers on
/// the sky plot and the 3D globe.
func drawHeadingArrow(_ context: inout GraphicsContext, at p: CGPoint, angle: Double, color: Color, size: CGFloat) {
    let dx = cos(angle), dy = sin(angle)
    let nx = -dy, ny = dx
    let tip = CGPoint(x: p.x + dx * size, y: p.y + dy * size)
    let back = CGPoint(x: p.x - dx * size * 0.7, y: p.y - dy * size * 0.7)
    let b1 = CGPoint(x: back.x + nx * size * 0.6, y: back.y + ny * size * 0.6)
    let b2 = CGPoint(x: back.x - nx * size * 0.6, y: back.y - ny * size * 0.6)
    var path = Path()
    path.move(to: tip); path.addLine(to: b1); path.addLine(to: b2); path.closeSubpath()
    context.fill(path, with: .color(color))
}

/// Compact toolbar control that shows the active satellite and opens a picker
/// so the operator can switch the active satellite from any screen.
struct SatelliteSwitcherButton: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "dot.scope")
                Text(store.selectedSatellite?.name ?? "Select satellite")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(ODTheme.muted)
            }
        }
        .tint(ODTheme.accent)
        .accessibilityLabel("Active satellite: \(store.selectedSatellite?.name ?? "none"). Tap to change.")
        .sheet(isPresented: $showingPicker) {
            SatellitePickerSheet()
                .environmentObject(store)
        }
    }
}

/// Searchable satellite chooser presented as a sheet by `SatelliteSwitcherButton`.
struct SatellitePickerSheet: View {
    @EnvironmentObject private var store: OrbitStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var favoritesOnly = false

    var body: some View {
        NavigationStack {
            List(results) { satellite in
                Button {
                    store.select(satellite.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: store.selectedSatellite?.id == satellite.id ? "scope" : "satellite")
                            .foregroundStyle(store.selectedSatellite?.id == satellite.id ? ODTheme.accent : ODTheme.muted)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(satellite.name)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(verbatim: "NORAD \(satellite.id)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ODTheme.muted)
                        }
                        Spacer()
                        if store.preferences.favorites.contains(satellite.id) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(ODTheme.warning)
                        }
                        if store.selectedSatellite?.id == satellite.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(ODTheme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Name, NORAD, or designator")
            .navigationTitle("Active Satellite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle("Favorites", isOn: $favoritesOnly)
                        .toggleStyle(.button)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Filtered by search + favorites toggle, with favorites floated to the top
    /// when no search is active.
    private var results: [SatelliteRecord] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = store.satellites.filter { satellite in
            if favoritesOnly && !store.preferences.favorites.contains(satellite.id) {
                return false
            }
            guard !needle.isEmpty else { return true }
            return satellite.name.lowercased().contains(needle)
                || String(satellite.id).contains(needle)
                || satellite.internationalDesignator.lowercased().contains(needle)
        }
        guard needle.isEmpty else { return filtered }
        return filtered.sorted { lhs, rhs in
            let lFav = store.preferences.favorites.contains(lhs.id)
            let rFav = store.preferences.favorites.contains(rhs.id)
            if lFav != rFav { return lFav }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

struct LoadingOrError: View {
    let isLoading: Bool
    let error: String?
    let emptyText: String

    var body: some View {
        if isLoading {
            ProgressView()
                .padding()
        } else if let error {
            ContentUnavailableView(
                "Unable to compute",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            ContentUnavailableView(
                emptyText,
                systemImage: "satellite",
                description: Text("Select a satellite or update the GP catalog.")
            )
        }
    }
}

/// A compact one-line live look for a satellite: current elevation, azimuth (with
/// compass), and a countdown to AOS (below the horizon) or LOS (in a pass). Used on
/// the SSTV and FT4 cards so an operator can see the pass at a glance.
struct SatelliteStatusLine: View {
    @EnvironmentObject private var store: OrbitStore
    let satellite: SatelliteRecord
    @State private var pass: PredictedPass?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let look = try? OrbitPredictor.look(satellite, observer: store.preferences.observer, at: now)
            let up = (look?.elevation ?? -90) >= 0
            HStack(spacing: 6) {
                Image(systemName: up ? "dot.radiowaves.up.forward" : "arrow.up.forward")
                    .font(.system(size: 9)).foregroundStyle(up ? ODTheme.good : ODTheme.muted)
                if let look {
                    Text("El \(ODFormat.angle(look.elevation, decimals: 0))")
                    Text("·").foregroundStyle(ODTheme.muted.opacity(0.6))
                    Text("Az \(ODFormat.angle(look.azimuth, decimals: 0)) \(ODFormat.compass(look.azimuth))")
                }
                Spacer(minLength: 4)
                Text(countdown(now: now)).foregroundStyle(up ? ODTheme.warning : ODTheme.accent)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(ODTheme.muted)
        }
        .task(id: satellite.id) {
            // A new satellite: drop the previous one's pass so its countdown never
            // lingers while the first recompute runs.
            pass = nil
            while !Task.isCancelled {
                await recompute()
                // Refresh soon after the next event (AOS if still waiting, else LOS),
                // but at least once a minute so the readout stays fresh across station
                // movement / prediction drift and recovers quickly from a hiccup.
                let next: TimeInterval
                if let p = pass {
                    let event = Date() < p.aos ? p.aos : p.los
                    next = min(60, max(5, event.timeIntervalSinceNow + 2))
                } else {
                    next = 15   // no pass yet (or a transient failure): retry shortly
                }
                try? await Task.sleep(nanoseconds: UInt64(next * 1_000_000_000))
            }
        }
    }

    private func countdown(now: Date) -> String {
        guard let p = pass else { return "" }
        if now < p.aos { return "AOS \(ODFormat.duration(p.aos.timeIntervalSince(now)))" }
        if now <= p.los { return "LOS \(ODFormat.duration(p.los.timeIntervalSince(now)))" }
        return ""
    }

    @MainActor private func recompute() async {
        let observer = store.preferences.observer
        let sat = satellite
        // minElevation 0 → the true horizon AOS/LOS window (not the pass-list filter).
        let passes = try? await Task.detached(priority: .utility) {
            try OrbitPredictor.predictPasses(sat, observer: observer, minElevation: 0, maxCount: 1)
        }.value
        if let first = passes?.first {
            pass = first
        } else if let current = pass, Date() > current.los {
            // Only clear a stale pass once it has fully elapsed; keep the last good
            // pass through a transient propagation failure so the countdown doesn't blank.
            pass = nil
        }
    }
}

/// Live downlink/uplink frequency readout for the FT4 and SSTV cards, so an operator knows
/// where the radio is (or should be) tuned right now. When CAT is connected it shows the
/// actual corrected dials the loop is driving (Doppler + calibration + passband offset +
/// transverter); otherwise it computes from the transponder — including the passband offset
/// so a manually-tuned operator sees where they're operating, not just the band center.
/// Updates once a second; shown below the az/el line.
struct DopplerFrequencyLine: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    let satellite: SatelliteRecord
    /// Optionally pin to a specific transponder (FT4 passes the one CAT is tracking); else the
    /// first two-way transponder, else the first.
    var transponderOverride: TransponderRecord? = nil

    private var transponder: TransponderRecord? {
        transponderOverride
            ?? satellite.transponders.first(where: { $0.uplinkCenter > 0 })
            ?? satellite.transponders.first
    }

    var body: some View {
        if let tp = transponder, tp.downlinkCenter > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Image(systemName: "dial.medium").font(.system(size: 9)).foregroundStyle(ODTheme.muted)
                    Text(readout(tp: tp, at: context.date))
                    Spacer(minLength: 4)
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.muted)
            }
        }
    }

    private func readout(tp: TransponderRecord, at date: Date) -> String {
        // Prefer the live CAT dials — the ACTUAL frequency the radio is tuned to right now,
        // already including the passband offset the operator chose within the transponder.
        if rig.connected, rig.downlinkDialHz > 0 {
            if rig.uplinkDialHz > 0 {
                return "Tune  RX \(mhz(rig.downlinkDialHz)) · TX \(mhz(rig.uplinkDialHz)) MHz"
            }
            return "Tune  RX \(mhz(rig.downlinkDialHz)) MHz"
        }
        guard let look = try? OrbitPredictor.look(satellite, observer: store.preferences.observer, at: date) else {
            return "Tune \(mhz(tp.downlinkCenter)) MHz"
        }
        // No CAT: fold in the passband offset (where you're operating in the transponder),
        // matching the CAT loop's math, so the manual-tune hint tracks your actual spot.
        let offset = tp.isLinear ? Int64(rig.config.tuning.passbandOffsetHz.rounded()) : 0
        let downlink = tp.downlinkCenter + offset
        let uplink: Int64 = {
            let u = tp.uplinkCenter
            guard tp.isLinear, u > 0 else { return u }
            return tp.invert ? u - offset : u + offset
        }()
        let cal = store.downlinkCalibrationHz(for: satellite.id, invert: tp.invert)
        let c = OrbitPredictor.dopplerFrequencies(downlinkHz: downlink, uplinkHz: uplink,
                                                  rangeRateKmS: look.rangeRateKmS,
                                                  downlinkCalibrationHz: cal, uplinkCalibrationHz: 0)
        if tp.uplinkCenter > 0, c.tx > 0 {
            return "Tune  RX \(mhz(c.rx)) · TX \(mhz(c.tx)) MHz"
        }
        return "Tune  RX \(mhz(c.rx)) MHz"
    }

    private func mhz(_ hz: Int64) -> String { String(format: "%.4f", Double(hz) / 1_000_000) }
}

// MARK: - Pass timeline (KlaTrack-style)

/// One satellite pass on a `PassTimelineChart`: its elevation profile plus the
/// series color slot it is drawn in.
struct TimelinePass: Identifiable, Sendable {
    let id: String
    let norad: UInt
    let name: String
    let colorIndex: Int
    let samples: [ElevationSample]

    var peak: ElevationSample? { samples.max { $0.elevation < $1.elevation } }

    /// Linearly interpolated elevation at `date`, or nil outside the pass.
    func elevation(at date: Date) -> Double? {
        guard let first = samples.first, let last = samples.last,
              date >= first.date, date <= last.date else { return nil }
        guard let upper = samples.firstIndex(where: { $0.date >= date }) else { return last.elevation }
        if upper == 0 { return first.elevation }
        let a = samples[upper - 1], b = samples[upper]
        let span = b.date.timeIntervalSince(a.date)
        guard span > 0 else { return b.elevation }
        let f = date.timeIntervalSince(a.date) / span
        return a.elevation + (b.elevation - a.elevation) * f
    }
}

/// A span during which one satellite is (or would be) the active one, drawn as a
/// strip under the curves — used by the auto-switch plan.
struct TimelineSpan: Identifiable, Sendable {
    let id: Int
    let norad: UInt
    let name: String
    let colorIndex: Int
    let start: Date
    let end: Date
}

enum PassTimeline {
    /// Solarized accents (as KlaTrack uses), which stay distinct on the dark theme.
    static let palette: [Color] = ["#b58900", "#cb4b16", "#dc322f", "#d33682",
                                   "#6c71c4", "#268bd2", "#2aa198", "#859900"].map { Color(hex: $0) }

    static func color(_ index: Int) -> Color { palette[((index % palette.count) + palette.count) % palette.count] }

    /// Predict every pass of `satellites` that overlaps `start…end` and sample its
    /// elevation profile. CPU-bound: call from a detached task. Each entry carries
    /// the color slot to draw it in.
    nonisolated static func load(_ satellites: [(record: SatelliteRecord, colorIndex: Int)],
                                 observer: ObserverSite, from start: Date, to end: Date) -> [TimelinePass] {
        let days = max(1.0 / 24, end.timeIntervalSince(start) / 86400)
        var output: [TimelinePass] = []
        for (record, colorIndex) in satellites {
            guard let passes = try? OrbitPredictor.predictPasses(record, observer: observer, from: start,
                                                                 minElevation: 0, maxCount: 60, horizonDays: days)
            else { continue }
            for pass in passes {
                // Coarser sampling for long (HEO/GEO) windows keeps the point count sane.
                let step = max(30, pass.duration / 400)
                guard let samples = try? OrbitPredictor.elevationProfile(record, observer: observer, pass: pass, step: step),
                      samples.count > 1 else { continue }
                output.append(TimelinePass(id: "\(record.id)-\(pass.aos.timeIntervalSince1970)", norad: record.id,
                                           name: record.name, colorIndex: colorIndex, samples: samples))
            }
        }
        return output
    }
}

/// Elevation-vs-time plot of upcoming passes on one shared time axis, after
/// G0KLA's KlaTrack: each pass is a peak from horizon to max elevation, colored per
/// satellite and labeled at its top, with a "now" line. Optional eclipse shading
/// fills sunlit stretches gold and eclipsed stretches gray. Tapping a peak (or a
/// plan-strip span) reports its satellite.
struct PassTimelineChart: View {
    let passes: [TimelinePass]
    let start: Date
    let end: Date
    let now: Date
    var minElevation: Double = 0
    var eclipseShading = false
    var spans: [TimelineSpan] = []
    var highlighted: UInt?
    var onSelect: ((UInt) -> Void)?

    private let leftInset: CGFloat = 26
    private let topInset: CGFloat = 16
    private let axisHeight: CGFloat = 16
    private let stripHeight: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(in: &ctx, size: size) }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    if let id = hit(value.location, size: geo.size) { onSelect?(id) }
                })
        }
        .frame(height: spans.isEmpty ? 170 : 186)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Geometry

    private func plotRect(_ size: CGSize) -> CGRect {
        let bottom = axisHeight + (spans.isEmpty ? 0 : stripHeight + 4)
        return CGRect(x: leftInset, y: topInset, width: max(1, size.width - leftInset - 4),
                      height: max(1, size.height - topInset - bottom))
    }

    private func x(_ date: Date, _ plot: CGRect) -> CGFloat {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return plot.minX }
        return plot.minX + CGFloat(date.timeIntervalSince(start) / total) * plot.width
    }

    private func y(_ elevation: Double, _ plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat(max(0, min(90, elevation)) / 90) * plot.height
    }

    private func date(atX px: CGFloat, _ plot: CGRect) -> Date {
        start.addingTimeInterval(Double((px - plot.minX) / plot.width) * end.timeIntervalSince(start))
    }

    // MARK: Drawing

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let plot = plotRect(size)

        // Elevation grid at 30° / 60° with left labels, plus the horizon.
        for el in [30.0, 60.0] {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(el, plot)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(el, plot)))
            ctx.stroke(line, with: .color(ODTheme.grid), lineWidth: 0.5)
            ctx.draw(Text(verbatim: "\(Int(el))°").font(.system(size: 9)).foregroundStyle(ODTheme.muted),
                     at: CGPoint(x: plot.minX - 4, y: y(el, plot)), anchor: .trailing)
        }
        var horizon = Path()
        horizon.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        horizon.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.stroke(horizon, with: .color(ODTheme.muted.opacity(0.6)), lineWidth: 1)

        if minElevation > 0 {
            var mask = Path()
            mask.move(to: CGPoint(x: plot.minX, y: y(minElevation, plot)))
            mask.addLine(to: CGPoint(x: plot.maxX, y: y(minElevation, plot)))
            ctx.stroke(mask, with: .color(ODTheme.warn.opacity(0.5)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }

        drawTimeAxis(in: &ctx, plot: plot)

        // Curves, clipped to the plot so passes straddling the window edges are cut.
        var curves = ctx
        curves.clip(to: Path(CGRect(x: plot.minX, y: 0, width: plot.width, height: plot.maxY + 1)))
        // Draw the highlighted satellite last so it sits on top.
        let ordered = passes.sorted { ($0.norad == highlighted ? 1 : 0) < ($1.norad == highlighted ? 1 : 0) }
        for pass in ordered { drawPass(pass, in: &curves, plot: plot) }

        drawLabels(in: &ctx, plot: plot)

        // "Now" line.
        if now >= start, now <= end {
            var line = Path()
            line.move(to: CGPoint(x: x(now, plot), y: plot.minY - 6))
            line.addLine(to: CGPoint(x: x(now, plot), y: plot.maxY))
            ctx.stroke(line, with: .color(.white.opacity(0.7)), lineWidth: 1)
        }

        if !spans.isEmpty { drawSpans(in: &ctx, plot: plot) }
    }

    private func drawPass(_ pass: TimelinePass, in ctx: inout GraphicsContext, plot: CGRect) {
        let points = pass.samples.map { CGPoint(x: x($0.date, plot), y: y($0.elevation, plot)) }
        guard let first = points.first, let last = points.last else { return }
        let color = PassTimeline.color(pass.colorIndex)
        let emphasized = highlighted == pass.norad

        if eclipseShading {
            // Fill each sample interval by its sunlit state (KlaTrack's eclipse view).
            for i in 1..<points.count {
                var quad = Path()
                quad.move(to: CGPoint(x: points[i - 1].x, y: plot.maxY))
                quad.addLine(to: points[i - 1])
                quad.addLine(to: points[i])
                quad.addLine(to: CGPoint(x: points[i].x, y: plot.maxY))
                quad.closeSubpath()
                let lit = pass.samples[i - 1].sunlit
                ctx.fill(quad, with: .color(lit ? ODTheme.warn.opacity(0.75) : ODTheme.muted.opacity(0.35)))
            }
        } else {
            var area = Path()
            area.move(to: CGPoint(x: first.x, y: plot.maxY))
            points.forEach { area.addLine(to: $0) }
            area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(emphasized ? 0.35 : 0.18)))
        }

        var curve = Path()
        curve.addLines(points)
        ctx.stroke(curve, with: .color(eclipseShading ? .white.opacity(0.55) : color),
                   lineWidth: emphasized ? 2.5 : 1.4)
    }

    /// Name labels at each pass peak. Taller peaks are placed first; a label that
    /// would collide is nudged up once, then dropped (the selected satellite's
    /// label is always kept).
    private func drawLabels(in ctx: inout GraphicsContext, plot: CGRect) {
        var placed: [CGRect] = []
        let candidates = passes.compactMap { pass -> (TimelinePass, ElevationSample)? in
            guard let peak = pass.peak, peak.date >= start, peak.date <= end else { return nil }
            return (pass, peak)
        }
        .sorted { a, b in
            if (a.0.norad == highlighted) != (b.0.norad == highlighted) { return a.0.norad == highlighted }
            return a.1.elevation > b.1.elevation
        }
        for (pass, peak) in candidates {
            let text = ctx.resolve(Text(pass.name).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(eclipseShading ? Color.white : PassTimeline.color(pass.colorIndex)))
            let measured = text.measure(in: CGSize(width: 200, height: 20))
            let px = min(max(x(peak.date, plot), plot.minX + measured.width / 2), plot.maxX - measured.width / 2)
            var rect = CGRect(x: px - measured.width / 2, y: y(peak.elevation, plot) - measured.height - 1,
                              width: measured.width, height: measured.height)
            if placed.contains(where: { $0.intersects(rect) }) {
                rect.origin.y -= measured.height
                if placed.contains(where: { $0.intersects(rect) }) || rect.minY < 0 {
                    if pass.norad != highlighted { continue }
                }
            }
            rect.origin.y = max(0, rect.origin.y)
            placed.append(rect)
            ctx.draw(text, in: rect)
        }
    }

    private func drawTimeAxis(in ctx: inout GraphicsContext, plot: CGRect) {
        let total = end.timeIntervalSince(start)
        let step: TimeInterval = total > 8 * 3600 ? 7200 : 3600
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ODFormat.displayTimeZone
        // First whole-hour tick at or after `start`, then every `step`.
        guard var tick = calendar.nextDate(after: start.addingTimeInterval(-1), matching: DateComponents(minute: 0),
                                           matchingPolicy: .nextTime) else { return }
        if step == 7200, calendar.component(.hour, from: tick) % 2 == 1 { tick.addTimeInterval(3600) }
        let labelY = plot.maxY + (spans.isEmpty ? 0 : stripHeight + 4) + axisHeight / 2 + 1
        while tick <= end {
            let px = x(tick, plot)
            var mark = Path()
            mark.move(to: CGPoint(x: px, y: plot.maxY))
            mark.addLine(to: CGPoint(x: px, y: plot.maxY + 3))
            ctx.stroke(mark, with: .color(ODTheme.muted), lineWidth: 0.8)
            ctx.draw(Text(ODFormat.axisClock(tick)).font(.system(size: 9).monospacedDigit()).foregroundStyle(ODTheme.muted),
                     at: CGPoint(x: px, y: labelY))
            tick.addTimeInterval(step)
        }
    }

    private func drawSpans(in ctx: inout GraphicsContext, plot: CGRect) {
        let top = plot.maxY + 3
        for span in spans {
            let x0 = max(plot.minX, x(span.start, plot)), x1 = min(plot.maxX, x(span.end, plot))
            guard x1 > x0 else { continue }
            let rect = CGRect(x: x0, y: top, width: max(2, x1 - x0), height: stripHeight)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(PassTimeline.color(span.colorIndex)))
            let text = ctx.resolve(Text(span.name).font(.system(size: 8, weight: .bold)).foregroundStyle(Color.black))
            if text.measure(in: CGSize(width: 300, height: 20)).width + 4 < rect.width {
                ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
    }

    // MARK: Interaction

    private func hit(_ point: CGPoint, size: CGSize) -> UInt? {
        let plot = plotRect(size)
        let t = date(atX: point.x, plot)
        if !spans.isEmpty, point.y > plot.maxY {
            return spans.first { t >= $0.start && t <= $0.end }?.norad
        }
        let tappedElevation = Double((plot.maxY - point.y) / plot.height) * 90
        // The curve whose value at the tapped time is nearest the tapped height.
        return passes
            .compactMap { pass in pass.elevation(at: t).map { (pass.norad, abs($0 - tappedElevation)) } }
            .min { $0.1 < $1.1 }?.0
    }

    private var accessibilitySummary: String {
        let upcoming = passes.compactMap { pass -> (String, ElevationSample)? in
            guard let peak = pass.peak, peak.date >= now else { return nil }
            return (pass.name, peak)
        }
        .sorted { $0.1.date < $1.1.date }
        .prefix(4)
        .map { "\($0.0) peaks \(Int($0.1.elevation.rounded())) degrees at \(ODFormat.axisClock($0.1.date))" }
        return upcoming.isEmpty ? "Pass timeline: no passes in this window." : "Pass timeline. " + upcoming.joined(separator: ". ")
    }
}
