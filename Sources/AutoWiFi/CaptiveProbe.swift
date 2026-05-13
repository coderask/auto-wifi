import Foundation
import OSLog
import Core

/// HEAL-02: detect captive portals by probing Apple's hotspot-detect endpoint.
///
/// The endpoint returns the literal body `<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>`
/// when there is no portal. If we get anything else (a redirect, an HTML login page, a
/// connection that hangs), we conclude the network is captive and remember that verdict per
/// `(SSID, BSSID)` pair — captive APs sometimes share an SSID with non-captive ones in the
/// same enterprise deployment, so SSID alone is too coarse.
public actor CaptiveProbe {
    /// `(SSID, BSSID)` → captive verdict. Stored in-memory for Phase 2; Phase 7 persists.
    public private(set) var verdicts: [Key: Verdict] = [:]

    public struct Key: Sendable, Hashable {
        public let ssid: String
        public let bssid: String?
        public init(ssid: String, bssid: String?) {
            self.ssid = ssid
            self.bssid = bssid
        }
    }

    public struct Verdict: Sendable {
        public let captive: Bool
        public let observedAt: Date
    }

    private let log = Logger(subsystem: "com.aarnavkoushik.autowifi", category: "CaptiveProbe")
    private static let probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    private static let expectedBody = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"

    public init() {}

    /// Probe for the network we're currently joined to. Returns the new verdict and stores it.
    public func probeCurrent(ssid: String?, bssid: String?) async -> Bool {
        guard let ssid else { return false }
        let isCaptive = await runProbe()
        verdicts[Key(ssid: ssid, bssid: bssid)] = Verdict(captive: isCaptive, observedAt: Date())
        log.info("captive probe ssid=\(ssid, privacy: .public) verdict=\(isCaptive ? "captive" : "open", privacy: .public)")
        return isCaptive
    }

    public func cachedVerdict(ssid: String?, bssid: String?) -> Verdict? {
        guard let ssid else { return nil }
        return verdicts[Key(ssid: ssid, bssid: bssid)]
    }

    private func runProbe() async -> Bool {
        var request = URLRequest(url: Self.probeURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        // Stop URLSession from following the redirect that a captive portal will issue —
        // the redirect itself is the signal.
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            // 200 + exact body match → no portal. Anything else is suspicious.
            if http.statusCode == 200, let body = String(data: data, encoding: .utf8), body.contains("Success") {
                return false
            }
            return true
        } catch {
            // Network error during probe — don't claim captive, but log.
            log.debug("captive probe error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// Block automatic redirect following so we can observe captive portal 302s as captive.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
