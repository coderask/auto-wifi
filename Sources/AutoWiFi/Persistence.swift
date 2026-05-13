import Foundation
import OSLog
import Core
import Algorithms

// MARK: - Records (Codable, not SwiftData — see note below)

/// BG-03: persisted form of a Decision. We don't store the full ScoreBreakdown — for the
/// log view a textual reason + key fields is enough. Phase 8/v2 can promote to SwiftData
/// when Xcode is installed (Command Line Tools doesn't ship the SwiftDataMacros plugin).
public struct DecisionLogRecord: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: String
    public let reason: String
    public let currentSSID: String?
    public let currentBSSID: String?
    public let targetSSID: String?
    public let targetBSSID: String?
    public let fsmAfter: String
}

/// BG-04: per-SSID preference.
public struct NetworkPreferenceRecord: Codable, Sendable {
    public let ssid: String
    public let preferenceRaw: String
    public let updatedAt: Date
}

/// BG-04 (also): per-(SSID,BSSID) captive verdict.
public struct CaptiveFlagRecord: Codable, Sendable {
    public let ssid: String
    public let bssid: String?
    public let captive: Bool
    public let observedAt: Date
}

// MARK: - PersistenceActor

/// Owns the on-disk persistence. Three files in `~/Library/Application Support/auto-wifi/`:
///   - `decisions.jsonl` — append-only newline-delimited JSON for the decision log
///   - `preferences.json` — atomic-rewrite map of SSID → NetworkPreference
///   - `captive-flags.json` — atomic-rewrite array of captive verdicts
///
/// All writes are serialized through the actor. BG-05 pruning rewrites `decisions.jsonl`
/// dropping rows older than the cutoff. The interface is intentionally identical to what
/// a SwiftData-backed actor would expose; the storage layer can be swapped without touching
/// AppState or DecisionLoop.
public actor PersistenceActor {
    public static let shared: PersistenceActor = {
        do { return try PersistenceActor() }
        catch {
            // If persistence can't open, in-memory only — the app degrades gracefully.
            let inst = try? PersistenceActor(directory: FileManager.default.temporaryDirectory.appendingPathComponent("auto-wifi-fallback"))
            return inst ?? PersistenceActor.failed
        }
    }()

    /// Last-ditch in-memory-only instance for when both the real and fallback directories
    /// can't be opened. Calls do nothing.
    private static let failed: PersistenceActor = {
        // Force one to exist — guaranteed-creatable temp dir.
        let url = FileManager.default.temporaryDirectory
        return try! PersistenceActor(directory: url)
    }()

    private let directory: URL
    private let decisionsURL: URL
    private let preferencesURL: URL
    private let captiveURL: URL

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "Persistence")
    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(directory: URL? = nil) throws {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            dir = appSupport.appendingPathComponent("auto-wifi", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        self.decisionsURL = dir.appendingPathComponent("decisions.jsonl")
        self.preferencesURL = dir.appendingPathComponent("preferences.json")
        self.captiveURL = dir.appendingPathComponent("captive-flags.json")
    }

    // MARK: - Decision log (BG-03)

    public func appendDecision(_ d: Decision) {
        let target: (ssid: String?, bssid: String?) = {
            switch d.action {
            case .switchTo(let t): return (t.ssid, t.bssid)
            case .rejectedSwitch(let t, _, _): return (t.ssid, t.bssid)
            default: return (nil, nil)
            }
        }()
        let record = DecisionLogRecord(
            id: d.id,
            timestamp: d.timestamp,
            kind: actionKind(d.action),
            reason: d.reason,
            currentSSID: d.currentKey?.ssid,
            currentBSSID: d.currentKey?.bssid,
            targetSSID: target.ssid,
            targetBSSID: target.bssid,
            fsmAfter: d.fsmStateAfter.rawValue
        )
        appendJSONL(record, to: decisionsURL)
    }

    public func recentDecisions(limit: Int = 200) -> [DecisionLogRecord] {
        let all = readJSONL(DecisionLogRecord.self, from: decisionsURL)
        let sorted = all.sorted { $0.timestamp > $1.timestamp }
        return Array(sorted.prefix(limit))
    }

    /// BG-05: remove decision-log rows older than `days`. Returns the count deleted.
    @discardableResult
    public func pruneDecisions(olderThanDays days: Int = 90) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let all = readJSONL(DecisionLogRecord.self, from: decisionsURL)
        let kept = all.filter { $0.timestamp >= cutoff }
        let removed = all.count - kept.count
        if removed > 0 {
            rewriteJSONL(kept, to: decisionsURL)
            log.info("pruned \(removed, privacy: .public) decision-log rows older than \(days)d")
        }
        return removed
    }

    // MARK: - Preferences (BG-04)

    public func loadPreferences() -> [String: NetworkPreference] {
        let records = readJSON([NetworkPreferenceRecord].self, from: preferencesURL) ?? []
        var out: [String: NetworkPreference] = [:]
        for r in records {
            if let pref = NetworkPreference(rawValue: r.preferenceRaw) {
                out[r.ssid] = pref
            }
        }
        return out
    }

    public func savePreference(ssid: String, preference: NetworkPreference?) {
        var records = readJSON([NetworkPreferenceRecord].self, from: preferencesURL) ?? []
        records.removeAll { $0.ssid == ssid }
        if let p = preference, p != .neutral {
            records.append(NetworkPreferenceRecord(ssid: ssid, preferenceRaw: p.rawValue, updatedAt: Date()))
        }
        writeJSON(records, to: preferencesURL)
    }

    // MARK: - Captive flags (BG-04 also)

    public func loadCaptiveFlags() -> [CaptiveFlagRecord] {
        readJSON([CaptiveFlagRecord].self, from: captiveURL) ?? []
    }

    public func saveCaptiveFlag(ssid: String, bssid: String?, captive: Bool) {
        var records = readJSON([CaptiveFlagRecord].self, from: captiveURL) ?? []
        records.removeAll { $0.ssid == ssid && $0.bssid == bssid }
        records.append(CaptiveFlagRecord(ssid: ssid, bssid: bssid, captive: captive, observedAt: Date()))
        writeJSON(records, to: captiveURL)
    }

    // MARK: - File helpers

    private func appendJSONL<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try Self.jsonEncoder.encode(value)
            var line = data
            line.append(0x0A)  // newline
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            log.error("appendJSONL failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readJSONL<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            var out: [T] = []
            var i = data.startIndex
            while i < data.endIndex {
                guard let end = data[i...].firstIndex(of: 0x0A) else {
                    if i < data.endIndex {
                        if let v = try? Self.jsonDecoder.decode(T.self, from: data[i...]) {
                            out.append(v)
                        }
                    }
                    break
                }
                let slice = data[i..<end]
                if !slice.isEmpty, let v = try? Self.jsonDecoder.decode(T.self, from: slice) {
                    out.append(v)
                }
                i = data.index(after: end)
            }
            return out
        } catch {
            log.error("readJSONL failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func rewriteJSONL<T: Encodable>(_ values: [T], to url: URL) {
        do {
            var buf = Data()
            for v in values {
                buf.append(try Self.jsonEncoder.encode(v))
                buf.append(0x0A)
            }
            try buf.write(to: url, options: .atomic)
        } catch {
            log.error("rewriteJSONL failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try Self.jsonDecoder.decode(T.self, from: data)
        } catch {
            log.error("readJSON failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try Self.jsonEncoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("writeJSON failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func actionKind(_ a: Decision.Action) -> String {
        switch a {
        case .stay: "stay"
        case .stayCurrentGoodEnough: "stayCurrentGoodEnough"
        case .rejectedSwitch: "rejectedSwitch"
        case .rejectedSwitchCooldown: "rejectedSwitchCooldown"
        case .switchTo: "switchTo"
        case .noCurrentConnection: "noCurrentConnection"
        }
    }
}
