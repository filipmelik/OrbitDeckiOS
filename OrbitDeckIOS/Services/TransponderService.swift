import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TransponderServiceError: LocalizedError {
    case badResponse(Int)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "SatNOGS returned HTTP \(code)."
        case .invalidJSON: "SatNOGS returned an unexpected response."
        }
    }
}

struct TransponderService {
    static func fetch(norad: UInt) async throws -> [TransponderRecord] {
        var comps = URLComponents(string: "https://db.satnogs.org/api/transmitters/")!
        comps.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "satellite__norad_cat_id", value: String(norad))
        ]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 30
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TransponderServiceError.badResponse(http.statusCode)
        }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TransponderServiceError.invalidJSON
        }
        return parseRows(rows)
    }

    /// The whole SatNOGS transmitter database, keyed by NORAD ID.
    static func fetchAll() async throws -> [UInt: [TransponderRecord]] {
        try await fetchIndex().byNorad
    }

    /// The whole SatNOGS transmitter database, keyed both by NORAD ID and by
    /// SatNOGS `sat_id`. The sat_id key matters for new launches: since NORAD
    /// numbers passed 99999, SatNOGS files new objects under temporary 9xxxx IDs,
    /// so the NORAD key alone can't find their transmitters.
    static func fetchIndex() async throws -> SatNOGSTransmitterIndex {
        let rows = try await getRows("transmitters/", query: [])
        var index = SatNOGSTransmitterIndex()
        for row in rows {
            guard let parsed = parseRow(row) else { continue }
            if let norad = uint(row["norad_cat_id"]) { index.byNorad[norad, default: []].append(parsed) }
            if let satID = row["sat_id"] as? String, !satID.isEmpty { index.bySatID[satID, default: []].append(parsed) }
        }
        return index
    }

    /// Transmitters for one SatNOGS satellite entry.
    static func fetch(satID: String) async throws -> [TransponderRecord] {
        parseRows(try await getRows("transmitters/", query: [URLQueryItem(name: "sat_id", value: satID)]))
    }

    /// The SatNOGS satellite list (names, IDs, status and launch dates).
    static func fetchSatellites() async throws -> [SatNOGSSatellite] {
        try await getRows("satellites/", query: []).compactMap(SatNOGSSatellite.init(row:))
    }

    /// SatNOGS's current TLEs, keyed by sat_id. SatNOGS relays Space-Track
    /// elements and renumbers objects that have six-digit NORAD numbers to its
    /// temporary IDs (the TLE format has five digits); the international
    /// designator in line 1 is kept.
    static func fetchTLEs() async throws -> [String: SatNOGSTLE] {
        var output: [String: SatNOGSTLE] = [:]
        for row in try await getRows("tle/", query: []) {
            if let tle = SatNOGSTLE(row: row) { output[tle.satID] = tle }
        }
        return output
    }

    static func fetchTLE(satID: String) async throws -> SatNOGSTLE? {
        try await getRows("tle/", query: [URLQueryItem(name: "sat_id", value: satID)]).compactMap(SatNOGSTLE.init(row:)).first
    }

    private static func getRows(_ path: String, query: [URLQueryItem]) async throws -> [[String: Any]] {
        var comps = URLComponents(string: "https://db.satnogs.org/api/" + path)!
        comps.queryItems = [URLQueryItem(name: "format", value: "json")] + query
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 60
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TransponderServiceError.badResponse(http.statusCode)
        }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TransponderServiceError.invalidJSON
        }
        return rows
    }

    static func uint(_ value: Any?) -> UInt? {
        if let n = value as? NSNumber { return UInt(exactly: n.uint64Value) }
        if let s = value as? String { return UInt(s) }
        return nil
    }

    private static func parseRows(_ rows: [[String: Any]]) -> [TransponderRecord] {
        rows.compactMap(parseRow)
    }

    private static func parseRow(_ row: [String: Any]) -> TransponderRecord? {
        // Keep active AND inactive transmitters (the reference apps show both);
        // only skip rows with no tunable downlink frequency.
        guard int64(row["downlink_low"]) > 0 else { return nil }
        let id = (row["uuid"] as? String)
            ?? (row["id"] as? NSNumber)?.stringValue
            ?? UUID().uuidString
        let description = (row["description"] as? String) ?? ""
        let mode = (row["mode"] as? String) ?? ""
        let type = (row["type"] as? String) ?? ""
        let service = (row["service"] as? String) ?? ""
        let invert = (row["invert"] as? Bool) ?? false
        // `alive` mirrors SatNOGS status (active/inactive); fall back to status.
        let alive = (row["alive"] as? Bool) ?? ((row["status"] as? String).map { $0 == "active" })
        return TransponderRecord(
            id: id,
            description: description,
            downlinkLow: int64(row["downlink_low"]),
            downlinkHigh: int64(row["downlink_high"]),
            uplinkLow: int64(row["uplink_low"]),
            uplinkHigh: int64(row["uplink_high"]),
            mode: mode,
            invert: invert,
            type: type,
            baud: double(row["baud"]),
            service: service,
            alive: alive
        )
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String, let n = Int64(s) { return n }
        return 0
    }

    private static func double(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let n = Double(s) { return n }
        return 0
    }
}

/// SatNOGS transmitters indexed both ways (see TransponderService.fetchIndex).
struct SatNOGSTransmitterIndex: Sendable {
    var byNorad: [UInt: [TransponderRecord]] = [:]
    var bySatID: [String: [TransponderRecord]] = [:]
}

/// One entry from the SatNOGS satellite list.
struct SatNOGSSatellite: Sendable {
    let satID: String
    let name: String
    let norad: UInt?
    let status: String
    let launched: Date?
    let deployed: Date?
    let decayed: Date?
    let operatorName: String

    /// SatNOGS's temporary IDs for objects without a usable NORAD number.
    static let placeholderRange: ClosedRange<UInt> = 90000...99999

    var hasPlaceholderNorad: Bool { norad.map { Self.placeholderRange.contains($0) } ?? true }

    init?(row: [String: Any]) {
        guard let satID = row["sat_id"] as? String, !satID.isEmpty else { return nil }
        self.satID = satID
        name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? satID
        norad = TransponderService.uint(row["norad_cat_id"])
        status = (row["status"] as? String) ?? ""
        launched = Self.date(row["launched"])
        deployed = Self.date(row["deployed"])
        decayed = Self.date(row["decayed"])
        operatorName = (row["operator"] as? String) ?? ""
    }

    // Shared formatters: the satellite list has ~2,800 rows with three dates each.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()
    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return isoFractional.date(from: text) ?? isoPlain.date(from: text) ?? dayOnly.date(from: String(text.prefix(10)))
    }
}

/// One SatNOGS TLE record.
struct SatNOGSTLE: Sendable {
    let satID: String
    let line0: String
    let line1: String
    let line2: String

    init?(row: [String: Any]) {
        guard let satID = row["sat_id"] as? String,
              let l1 = row["tle1"] as? String, let l2 = row["tle2"] as? String,
              l1.hasPrefix("1 "), l2.hasPrefix("2 ") else { return nil }
        self.satID = satID
        var name = (row["tle0"] as? String) ?? ""
        if name.hasPrefix("0 ") { name.removeFirst(2) }
        line0 = name
        line1 = l1
        line2 = l2
    }

    /// The COSPAR designator from line 1 (columns 10-17, "26203A") in OMM form
    /// ("2026-203A"), or nil when blank or a SatNOGS placeholder (launch 900+).
    var internationalDesignator: String? {
        let chars = Array(line1)
        guard chars.count >= 17 else { return nil }
        let field = String(chars[9..<17]).trimmingCharacters(in: .whitespaces)
        guard field.count >= 6, let yy = Int(field.prefix(2)),
              let launch = Int(field.dropFirst(2).prefix(3)), launch < 900 else { return nil }
        let year = yy < 57 ? 2000 + yy : 1900 + yy
        return "\(year)-\(field.dropFirst(2))"
    }
}
