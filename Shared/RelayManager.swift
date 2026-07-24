import Foundation
import Observation
import Darwin

extension Notification.Name {
    static let hueAmbienceRelayRunningChanged = Notification.Name("hueAmbienceRelayRunningChanged")
    static let relayAvailabilityChanged = Notification.Name("relayAvailabilityChanged")
}

@MainActor
protocol HueAmbienceRelayRuntimeProviding {
    var shouldDeferLocalHueAmbience: Bool { get }
    var isHueAmbienceRelayEnabled: Bool { get }
    var isHueAmbienceRelayPaused: Bool { get }
}

extension HueAmbienceRelayRuntimeProviding {
    var isHueAmbienceRelayEnabled: Bool { true }
    var isHueAmbienceRelayPaused: Bool { false }
}

/// Optional NAS-side Live Activity relay. Runs as a global singleton because
/// SettingsView, SonosManager, and the persisted UserDefaults entry all need
/// to agree on one source of truth.
///
/// **Optional**: when `urlString` is empty or the relay is unreachable, the
/// rest of the app behaves exactly as it did before (local `Activity.update`
/// path drives the Lock Screen). When it's configured and healthy, we shift
/// to APNs push tokens so the Live Activity stays fresh even with the app
/// fully suspended.
@MainActor
@Observable
final class RelayManager {

    static let shared = RelayManager()

    enum Status: Equatable {
        case disabled
        case probing
        case connected(groupCount: Int)
        case unreachable(reason: String?)
    }

    enum HueAmbienceSyncStatus: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                return "Not synced"
            case .syncing:
                return "Syncing Hue Ambience"
            case .synced:
                return "Synced to NAS Relay"
            case .failed(let reason):
                return reason
            }
        }
    }

    private(set) var urlString: String = ""
    private(set) var discoveredURLString: String?
    private(set) var discoveredRelayURLStrings: [String] = []
    private(set) var status: Status = .disabled {
        didSet {
            let wasAvailable: Bool
            if case .connected = oldValue {
                wasAvailable = true
            } else {
                wasAvailable = false
            }
            let isAvailable: Bool
            if case .connected = status {
                isAvailable = true
            } else {
                isAvailable = false
            }
            guard wasAvailable != isAvailable else { return }
            NotificationCenter.default.post(
                name: .relayAvailabilityChanged,
                object: isAvailable
            )
        }
    }
    private(set) var relaySonos: RelayClient.HealthResponse.Sonos?
    private(set) var relayAPNs: RelayClient.HealthResponse.APNs?
    private(set) var relayDiscoveryMessage: String?
    private(set) var isHueAmbienceRelayConfigured = false
    private(set) var isHueAmbienceRelayEnabled = false
    private(set) var isHueAmbienceRelayPaused = false
    private(set) var hueAmbienceRuntimeStatus: HueLiveEntertainmentRuntimeStatus = .unavailable
    private(set) var hueAmbienceRuntimeDetail = "Sync Hue Ambience to NAS Relay to enable always-on ambience."
    private(set) var hueAmbienceActiveGroups: [HueAmbienceActiveSyncGroup] = []
    private(set) var hueEntertainmentStreamingStatus: HueEntertainmentStreamingStatus = .unknown
    private(set) var hueEntertainmentStreamingDetail = "Entertainment streaming status has not been checked."
    var hueAmbienceSyncStatus: HueAmbienceSyncStatus = .idle

    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightProbe: Task<Void, Never>?
    @ObservationIgnored private var hueAmbienceStatusGeneration: UInt = 0
    @ObservationIgnored private let discovery = RelayDiscovery()

    private var manualURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private var discoveredURL: URL? {
        discoveredURLString.flatMap(URL.init(string:))
    }

    /// Active relay URL. Manual URL wins; discovered URL is used only when
    /// the manual field is blank.
    var url: URL? {
        RelayDiscovery.preferredRelayURL(
            manualURLString: urlString,
            discoveredURL: discoveredURL
        )
    }

    var activeURLString: String? {
        url?.absoluteString
    }

    /// App extensions don't participate in the main app's Bonjour resolution
    /// context reliably. Prefer a discovered numeric address on the same LAN
    /// as the selected Sonos coordinator when serializing a relay URL into
    /// RemoteMediaSession attributes.
    func appExtensionURLString(preferredPeerHost: String?) -> String? {
        if let manualURL, Self.isNumericHost(manualURL.host) {
            return manualURL.absoluteString
        }
        let candidates = discoveredRelayURLStrings.compactMap(URL.init(string:))
        if let prefix = Self.ipv4NetworkPrefix(preferredPeerHost),
           let sameLAN = candidates.first(where: {
               Self.ipv4NetworkPrefix($0.host) == prefix
           }) {
            return sameLAN.absoluteString
        }
        if let numeric = candidates.first(where: { Self.isNumericHost($0.host) }) {
            return numeric.absoluteString
        }
        return activeURLString
    }

    var isUsingDiscoveredURL: Bool {
        manualURL == nil && discoveredURL != nil
    }

    /// Convenience flag callers gate "use the relay" on. True only when the
    /// last probe succeeded — `disabled` and `unreachable` both return false.
    var isAvailable: Bool {
        if case .connected = status { return true }
        return false
    }

    var shouldDeferLocalHueAmbience: Bool {
        isAvailable && isHueAmbienceRelayConfigured
    }

    var isHueAmbienceRelayRunning: Bool {
        isHueAmbienceRelayConfigured
            && isHueAmbienceRelayEnabled
            && !isHueAmbienceRelayPaused
    }

    private init() {
        urlString = SharedStorage.relayURLString ?? ""
        discoveredURLString = SharedStorage.discoveredRelayURLString
        discovery.onCandidate = { [weak self] url in
            Task { @MainActor in
                await self?.handleDiscoveredRelay(url)
            }
        }
        discovery.onEvent = { [weak self] message in
            self?.relayDiscoveryMessage = message
        }
    }

    // MARK: - Lifecycle

    /// Persist the user's input, kick a fresh probe, and (re)start periodic
    /// background probing. Empty input enables Bonjour auto-discovery.
    func setURL(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = trimmed
        SharedStorage.relayURLString = trimmed.isEmpty ? nil : trimmed

        if trimmed.isEmpty {
            startRelayDiscovery()
            startPeriodicProbe()
            Task { await probeNow() }
            return
        }
        discovery.stop()
        discoveredURLString = nil
        SharedStorage.discoveredRelayURLString = nil
        Task { await probeNow() }
        startPeriodicProbe()
    }

    /// Spawn an immediate probe; results land on `status`. Safe to call at
    /// any time (older in-flight probes are cancelled implicitly because we
    /// just overwrite `status` once a fresh result arrives).
    func probeNow() async {
        guard let url else {
            SonosLog.info(.relay, "probe skipped: no relay URL yet; starting discovery")
            status = .probing
            startRelayDiscovery()
            return
        }
        // Don't pile up parallel probes on every onAppear / 30s tick.
        inFlightProbe?.cancel()
        let hueAmbienceReadGeneration = beginHueAmbienceStatusRead()
        let task = Task { [weak self] in
            guard let self else { return }
            // Keep the last known connected state while refreshing. Flipping
            // to `probing` here made Hue Ambience briefly fall back to the
            // local renderer and local UserDefaults on every 30-second probe.
            if !self.isAvailable {
                self.status = .probing
            }
            SonosLog.info(.relay, "health probe start url=\(url.absoluteString)")
            do {
                let health = try await RelayClient.health(baseURL: url)
                guard !Task.isCancelled else { return }
                SonosLog.info(
                    .relay,
                    "health probe success url=\(url.absoluteString) groups=\(health.groups.count) " +
                    "apns=\(health.apns?.mode.rawValue ?? "nil")"
                )
                self.status = .connected(groupCount: health.groups.count)
                self.relaySonos = health.sonos
                self.relayAPNs = health.apns
                if self.shouldApplyHueAmbienceStatusRead(hueAmbienceReadGeneration) {
                    self.updateHueAmbienceRuntimeStatus(from: health.hueAmbience)
                }
                self.updateHueEntertainmentStatus(health.hueEntertainment)
            } catch is CancellationError {
                // Newer probe took over — its result is what matters.
            } catch {
                guard !Task.isCancelled else { return }
                SonosLog.error(.relay, "health probe failed url=\(url.absoluteString) error=\(error)")
                self.status = .unreachable(reason: error.localizedDescription)
                self.relaySonos = nil
                self.relayAPNs = nil
                self.updateHueEntertainmentStatus(nil)
            }
        }
        inFlightProbe = task
        await task.value
    }

    /// 30-second probe loop, used as a passive watchdog so the iOS side
    /// notices when the NAS comes back online (or goes away) without the
    /// user opening Settings to retest.
    func startPeriodicProbe() {
        stopPeriodicProbe()
        if manualURL == nil {
            startRelayDiscovery()
        }
        periodicTask = Task { [weak self] in
            var secondsSinceFullProbe = 30
            while !Task.isCancelled {
                guard let self else { return }
                if secondsSinceFullProbe >= 30 {
                    await probeNow()
                    secondsSinceFullProbe = 0
                } else if isAvailable {
                    await refreshHueAmbienceRuntimeOnly()
                }
                try? await Task.sleep(for: .seconds(5))
                secondsSinceFullProbe += 5
            }
        }
    }

    func stopPeriodicProbe() {
        periodicTask?.cancel()
        periodicTask = nil
        discovery.stop()
    }

    private func refreshHueAmbienceRuntimeOnly() async {
        guard let url else { return }
        let generation = beginHueAmbienceStatusRead()
        do {
            let response = try await RelayClient.hueAmbienceStatus(baseURL: url)
            guard shouldApplyHueAmbienceStatusRead(generation) else {
                SonosLog.debug(.relay, "ignored stale Hue ambience status poll")
                return
            }
            let status = response.status
            updateHueAmbienceRuntimeStatus(
                configured: status.configured,
                enabled: status.enabled != false,
                renderMode: status.renderMode,
                runtimeActive: status.runtimeActive,
                runtimePaused: status.runtimePaused,
                activeTargetIds: status.activeTargetIds,
                activeGroups: status.activeGroups,
                entertainmentTargetActive: status.entertainmentTargetActive,
                entertainmentMetadataComplete: status.entertainmentMetadataComplete,
                lastFrameAt: status.lastFrameAt,
                lastError: status.lastError
            )
        } catch {
            SonosLog.debug(.relay, "Hue ambience status poll failed error=\(error)")
        }
    }

    private func startRelayDiscovery() {
        guard manualURL == nil else { return }
        SonosLog.info(.relay, "start relay auto-discovery")
        discovery.start()
    }

    private func handleDiscoveredRelay(_ url: URL) async {
        guard manualURL == nil else { return }
        SonosLog.info(.relay, "received relay candidate url=\(url.absoluteString)")
        if !discoveredRelayURLStrings.contains(url.absoluteString) {
            discoveredRelayURLStrings.append(url.absoluteString)
        }
        discoveredURLString = url.absoluteString
        SharedStorage.discoveredRelayURLString = url.absoluteString
        await probeNow()
    }

    private nonisolated static func isNumericHost(_ host: String?) -> Bool {
        guard let host else { return false }
        var address = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }

    private nonisolated static func ipv4NetworkPrefix(_ host: String?) -> String? {
        guard let host, isNumericHost(host) else { return nil }
        let octets = host.split(separator: ".")
        guard octets.count == 4 else { return nil }
        return octets.prefix(3).joined(separator: ".")
    }

    func updateHueAmbienceRuntimeStatus(
        configured: Bool,
        enabled: Bool = true,
        renderMode: HueAmbienceRelayRenderMode? = nil,
        runtimeActive: Bool? = nil,
        runtimePaused: Bool? = nil,
        activeTargetIds: [String]? = nil,
        activeGroups: [HueAmbienceActiveSyncGroup]? = nil,
        entertainmentTargetActive: Bool? = nil,
        entertainmentMetadataComplete: Bool? = nil,
        lastFrameAt: String? = nil,
        lastError: String? = nil
    ) {
        let wasConfigured = isHueAmbienceRelayConfigured
        let wasEnabled = isHueAmbienceRelayEnabled
        let wasPaused = isHueAmbienceRelayPaused
        let wasRunning = isHueAmbienceRelayRunning
        isHueAmbienceRelayConfigured = configured
        isHueAmbienceRelayEnabled = configured && enabled
        isHueAmbienceRelayPaused = configured && runtimePaused == true
        let isRunning = isHueAmbienceRelayRunning
        if wasConfigured != configured
            || wasEnabled != isHueAmbienceRelayEnabled
            || wasPaused != isHueAmbienceRelayPaused {
            SonosLog.info(
                .relay,
                "Hue ambience relay state configured=\(configured) "
                    + "enabled=\(isHueAmbienceRelayEnabled) "
                    + "paused=\(isHueAmbienceRelayPaused) running=\(isRunning)"
            )
        }
        if configured && (!wasConfigured || wasRunning != isRunning) {
            NotificationCenter.default.post(
                name: .hueAmbienceRelayRunningChanged,
                object: isRunning
            )
        }
        hueAmbienceSyncStatus = configured ? .synced(Date()) : .idle
        hueAmbienceActiveGroups = runtimeActive == true ? activeGroups ?? [] : []

        guard configured else {
            hueAmbienceRuntimeStatus = .unavailable
            hueAmbienceRuntimeDetail = "Sync Hue Ambience to NAS Relay to enable always-on ambience."
            return
        }

        guard enabled else {
            hueAmbienceRuntimeStatus = .ready("Album ambience disabled")
            hueAmbienceRuntimeDetail = "Enable album ambience to let NAS control your lights."
            return
        }

        guard runtimePaused != true else {
            hueAmbienceRuntimeStatus = .ready("NAS ambience stopped")
            hueAmbienceRuntimeDetail = "Start Hue Ambience from the app or relay dashboard."
            return
        }

        let trimmedError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedError.isEmpty {
            hueAmbienceRuntimeStatus = .error(trimmedError)
            hueAmbienceRuntimeDetail = "NAS reported a Hue Ambience runtime error."
            return
        }

        if runtimeActive == true {
            switch renderMode {
            case .entertainmentStreaming:
                hueAmbienceRuntimeStatus = .active("Entertainment streaming active")
            case .streamingReady:
                hueAmbienceRuntimeStatus = .fallback("Streaming-ready via CLIP fallback")
            case .clipFallback, nil:
                hueAmbienceRuntimeStatus = .fallback("CLIP fallback active")
            }
        } else {
            hueAmbienceRuntimeStatus = .ready("NAS runtime ready")
        }

        hueAmbienceRuntimeDetail = entertainmentTargetActive == true && entertainmentMetadataComplete == false
            ? "Entertainment channel metadata is incomplete."
            : "NAS controls Hue Ambience while it is reachable."
    }

    private func updateHueAmbienceRuntimeStatus(from health: RelayClient.HealthResponse.HueAmbience?) {
        guard let health else {
            updateHueAmbienceRuntimeStatus(configured: false)
            return
        }

        updateHueAmbienceRuntimeStatus(
            configured: health.configured == true,
            enabled: health.enabled != false,
            renderMode: health.renderMode,
            runtimeActive: health.runtimeActive,
            runtimePaused: health.runtimePaused,
            activeTargetIds: health.activeTargetIds,
            activeGroups: health.activeGroups,
            entertainmentTargetActive: health.entertainmentTargetActive,
            entertainmentMetadataComplete: health.entertainmentMetadataComplete,
            lastFrameAt: health.lastFrameAt,
            lastError: health.lastError
        )
    }

    func beginHueAmbienceStatusRead() -> UInt {
        hueAmbienceStatusGeneration &+= 1
        return hueAmbienceStatusGeneration
    }

    func invalidateHueAmbienceStatusReads() {
        hueAmbienceStatusGeneration &+= 1
    }

    func shouldApplyHueAmbienceStatusRead(_ generation: UInt) -> Bool {
        generation == hueAmbienceStatusGeneration
    }

    private func updateHueEntertainmentStatus(_ health: RelayClient.HealthResponse.HueEntertainment?) {
        guard let health else {
            hueEntertainmentStreamingStatus = .unknown
            hueEntertainmentStreamingDetail = "Entertainment streaming status has not been checked."
            return
        }

        hueEntertainmentStreamingStatus = health.streaming
        if let error = health.lastError, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hueEntertainmentStreamingDetail = error
            return
        }

        switch health.streaming {
        case .free:
            hueEntertainmentStreamingDetail = "Bridge Entertainment streaming is free."
        case .activeByRelay:
            hueEntertainmentStreamingDetail = "NAS Relay owns the active Entertainment stream."
        case .occupied:
            if let streamer = health.activeStreamer, !streamer.isEmpty {
                hueEntertainmentStreamingDetail = "Occupied by \(streamer)."
            } else {
                hueEntertainmentStreamingDetail = "Occupied by another Hue streaming app."
            }
        case .unknown:
            hueEntertainmentStreamingDetail = "Entertainment streaming status is not available yet."
        }
    }

    func submitArtworkHints(_ items: [BrowseItem]) {
        guard isAvailable, let url else { return }
        let body = RelayClient.ArtworkHintsBody(items: items)
        guard !body.hints.isEmpty else { return }

        Task {
            do {
                try await RelayClient.postArtworkHints(baseURL: url, body: body)
                SonosLog.debug(.relay, "artwork hints posted count=\(body.hints.count)")
            } catch {
                SonosLog.debug(.relay, "artwork hints post failed count=\(body.hints.count) error=\(error)")
            }
        }
    }

}

extension RelayManager: HueAmbienceRelayRuntimeProviding {}
