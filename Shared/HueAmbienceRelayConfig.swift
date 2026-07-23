import Foundation

enum HueAmbienceRelayConfigError: Error, LocalizedError, Equatable {
    case missingBridge
    case missingApplicationKey

    var errorDescription: String? {
        switch self {
        case .missingBridge:
            return "Pair a Hue Bridge before syncing Hue Ambience to the NAS relay."
        case .missingApplicationKey:
            return "Hue Bridge application key is missing. Pair the Bridge again before syncing to NAS."
        }
    }
}

struct HueAmbienceRelayConfig: Encodable, Sendable {
    let schemaVersion: Int
    let enabled: Bool
    let bridge: HueBridgeInfo
    let applicationKey: String
    let streamingClientKey: String?
    let streamingApplicationId: String?
    let resources: HueBridgeResources
    let mappings: [HueAmbienceRelayMapping]
    let groupStrategy: HueGroupSyncStrategy
    let stopBehavior: HueAmbienceStopBehavior
    let motionStyle: HueAmbienceMotionStyle
    let flowIntervalSeconds: Double
    let toneControl: HueAmbienceToneControl

    @MainActor
    init(
        store: HueAmbienceStore,
        credentialStore: HueCredentialStore = HueCredentialStore(),
        sonosSpeakers: [SonosPlayer],
        flowIntervalSeconds: Double? = nil,
        enabledOverride: Bool? = nil
    ) throws {
        guard let bridge = store.bridge else {
            throw HueAmbienceRelayConfigError.missingBridge
        }
        guard let applicationKey = credentialStore.applicationKey(forBridgeID: bridge.id),
              !applicationKey.isEmpty else {
            throw HueAmbienceRelayConfigError.missingApplicationKey
        }

        let speakersByID = sonosSpeakers.reduce(into: [String: SonosPlayer]()) { result, speaker in
            result[speaker.id] = speaker
        }

        self.schemaVersion = 1
        self.enabled = enabledOverride ?? store.isEnabled
        self.bridge = bridge
        self.applicationKey = applicationKey
        self.streamingClientKey = credentialStore.streamingClientKey(forBridgeID: bridge.id)
        self.streamingApplicationId = credentialStore.streamingApplicationId(forBridgeID: bridge.id)
        self.resources = store.hueResources
        self.mappings = store.mappings.map { mapping in
            HueAmbienceRelayMapping(
                mapping: mapping,
                relayGroupID: speakersByID[mapping.sonosID]?.playbackIP
            )
        }
        self.groupStrategy = store.groupStrategy
        self.stopBehavior = store.stopBehavior
        self.motionStyle = store.motionStyle
        self.flowIntervalSeconds = flowIntervalSeconds ?? store.flowSpeed.intervalSeconds
        self.toneControl = store.toneControl
    }
}

struct HueAmbienceRelayMapping: Encodable, Equatable, Sendable {
    let sonosID: String
    let sonosName: String
    let relayGroupID: String?
    let preferredTarget: HueAmbienceRelayTarget?
    let fallbackTarget: HueAmbienceRelayTarget?
    let includedLightIDs: [String]
    let excludedLightIDs: [String]
    let capability: HueAmbienceCapability

    init(mapping: HueSonosMapping, relayGroupID: String?) {
        self.sonosID = mapping.sonosID
        self.sonosName = mapping.sonosName
        self.relayGroupID = relayGroupID
        self.preferredTarget = mapping.preferredTarget.map(HueAmbienceRelayTarget.init)
        self.fallbackTarget = mapping.fallbackTarget.map(HueAmbienceRelayTarget.init)
        if mapping.effectiveRelayTarget?.isEntertainmentArea == true {
            self.includedLightIDs = []
            self.excludedLightIDs = []
        } else {
            self.includedLightIDs = mapping.includedLightIDs.sorted()
            self.excludedLightIDs = mapping.excludedLightIDs.sorted()
        }
        self.capability = mapping.capability
    }
}

private extension HueSonosMapping {
    var effectiveRelayTarget: HueAmbienceTarget? {
        if preferredTarget?.isLegacyDirectLightTarget == true {
            return fallbackTarget
        }
        return preferredTarget ?? fallbackTarget
    }
}

struct HueAmbienceRelayTarget: Encodable, Equatable, Sendable {
    let kind: String
    let id: String

    init(target: HueAmbienceTarget) {
        switch target {
        case .entertainmentArea(let id):
            self.kind = "entertainmentArea"
            self.id = id
        case .room(let id):
            self.kind = "room"
            self.id = id
        case .zone(let id):
            self.kind = "zone"
            self.id = id
        case .light(let id):
            self.kind = "light"
            self.id = id
        }
    }
}

extension RelayClient {
    static func putHueAmbienceConfig(
        baseURL: URL,
        config: HueAmbienceRelayConfig
    ) async throws {
        let url = baseURL.appendingPathComponent("/api/hue-ambience/config")
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(config)
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    static func deleteHueAmbienceConfig(baseURL: URL) async throws {
        let url = baseURL.appendingPathComponent("/api/hue-ambience/config")
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "DELETE"
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    static func setHueAmbienceRunning(baseURL: URL, running: Bool) async throws -> HueAmbienceStatusResponse {
        let action = running ? "start" : "stop"
        let url = baseURL.appendingPathComponent("/api/hue-ambience/\(action)")
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(HueAmbienceStatusResponse.self, from: data)
    }
}

@MainActor
extension RelayManager {
    func pushHueAmbienceConfig(
        store: HueAmbienceStore = .shared,
        sonosSpeakers: [SonosPlayer]
    ) async {
        guard let url else {
            hueAmbienceSyncStatus = .failed("NAS Relay is not reachable yet")
            return
        }

        hueAmbienceSyncStatus = .syncing
        invalidateHueAmbienceStatusReads()
        do {
            let config = try HueAmbienceRelayConfig(
                store: store,
                sonosSpeakers: sonosSpeakers,
                enabledOverride: isHueAmbienceRelayConfigured
                    ? isHueAmbienceRelayRunning
                    : nil
            )
            try await RelayClient.putHueAmbienceConfig(baseURL: url, config: config)
            invalidateHueAmbienceStatusReads()
            updateHueAmbienceRuntimeStatus(configured: true, enabled: config.enabled)
        } catch {
            hueAmbienceSyncStatus = .failed(error.localizedDescription)
        }
    }

    func clearHueAmbienceConfig() async {
        guard let url else {
            hueAmbienceSyncStatus = .idle
            return
        }

        hueAmbienceSyncStatus = .syncing
        invalidateHueAmbienceStatusReads()
        do {
            try await RelayClient.deleteHueAmbienceConfig(baseURL: url)
            invalidateHueAmbienceStatusReads()
            updateHueAmbienceRuntimeStatus(configured: false)
            hueAmbienceSyncStatus = .idle
        } catch {
            hueAmbienceSyncStatus = .failed(error.localizedDescription)
        }
    }

    func refreshHueAmbienceStatus() async {
        guard let url else {
            hueAmbienceSyncStatus = .idle
            return
        }

        let generation = beginHueAmbienceStatusRead()
        do {
            let response = try await RelayClient.hueAmbienceStatus(baseURL: url)
            guard shouldApplyHueAmbienceStatusRead(generation) else { return }
            updateHueAmbienceRuntimeStatus(
                configured: response.status.configured,
                enabled: response.status.enabled != false,
                renderMode: response.status.renderMode,
                runtimeActive: response.status.runtimeActive,
                runtimePaused: response.status.runtimePaused,
                activeTargetIds: response.status.activeTargetIds,
                activeGroups: response.status.activeGroups,
                entertainmentTargetActive: response.status.entertainmentTargetActive,
                entertainmentMetadataComplete: response.status.entertainmentMetadataComplete,
                lastFrameAt: response.status.lastFrameAt,
                lastError: response.status.lastError
            )
        } catch {
            hueAmbienceSyncStatus = .failed(error.localizedDescription)
        }
    }

    func setHueAmbienceRunning(_ running: Bool) async {
        guard let url else {
            hueAmbienceSyncStatus = .failed("NAS Relay is not reachable yet")
            return
        }

        invalidateHueAmbienceStatusReads()
        do {
            let response = try await RelayClient.setHueAmbienceRunning(baseURL: url, running: running)
            invalidateHueAmbienceStatusReads()
            updateHueAmbienceRuntimeStatus(
                configured: response.status.configured,
                enabled: response.status.enabled != false,
                renderMode: response.status.renderMode,
                runtimeActive: response.status.runtimeActive,
                runtimePaused: response.status.runtimePaused,
                activeTargetIds: response.status.activeTargetIds,
                activeGroups: response.status.activeGroups,
                entertainmentTargetActive: response.status.entertainmentTargetActive,
                entertainmentMetadataComplete: response.status.entertainmentMetadataComplete,
                lastFrameAt: response.status.lastFrameAt,
                lastError: response.status.lastError
            )
        } catch {
            hueAmbienceSyncStatus = .failed(error.localizedDescription)
        }
    }
}
