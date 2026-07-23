import SwiftUI

struct MusicAmbienceSetupPresentationState: Equatable {
    var isPresented = false

    mutating func present() {
        isPresented = true
    }

    mutating func dismiss() {
        isPresented = false
    }
}
enum HueAmbienceSetupPresentation {
    static let updateLightsActionTitle = "Update Lights"
}

enum HueAmbienceEnableControlPolicy {
    static func usesRelayRuntime(
        relayAvailable: Bool,
        relayConfigured: Bool
    ) -> Bool {
        relayAvailable && relayConfigured
    }

    static func effectiveIsEnabled(
        localEnabled: Bool,
        relayAvailable: Bool,
        relayConfigured: Bool,
        relayRunning: Bool
    ) -> Bool {
        guard usesRelayRuntime(
            relayAvailable: relayAvailable,
            relayConfigured: relayConfigured
        ) else {
            return localEnabled
        }
        return relayRunning
    }
}

@MainActor
struct MusicAmbienceSettingsSyncActions {
    let refreshStatus: () -> Void
    let canSyncToRelay: () -> Bool
    let syncToRelay: () async -> Void

    func enabledChanged() async {
        refreshStatus()
        guard canSyncToRelay() else { return }
        await syncToRelay()
    }

    func syncableSettingChanged() async {
        guard canSyncToRelay() else { return }
        await syncToRelay()
    }

    func groupPlaybackChanged() async {
        await syncableSettingChanged()
    }

    func stopBehaviorChanged() async {
        await syncableSettingChanged()
    }
}

enum HueAmbienceStatusTone: Equatable {
    case ready
    case working
    case critical
    case neutral
}

struct HueAmbienceStatusChip: Identifiable, Equatable {
    let title: String
    let value: String
    let tone: HueAmbienceStatusTone
    let detail: String?

    var id: String { title }
}

enum HueAmbienceStatusPresentation {
    static let ambienceSectionTitle = "Ambience"

    static func statusChips(
        bridge: HueBridgeInfo?,
        lightingStatus: MusicAmbienceManager.Status,
        relayActiveGroups: [HueAmbienceActiveSyncGroup],
        playbackSnapshot: HueAmbiencePlaybackSnapshot?,
        mappings: [HueSonosMapping],
        groupStrategy: HueGroupSyncStrategy
    ) -> [HueAmbienceStatusChip] {
        [
            bridgeChip(bridge),
            lightingChip(lightingStatus, relayActiveGroups: relayActiveGroups),
            syncingChip(
                relayActiveGroups: relayActiveGroups,
                playbackSnapshot: playbackSnapshot,
                mappings: mappings,
                groupStrategy: groupStrategy
            ),
        ]
    }

    static func setupActionTitle(bridge: HueBridgeInfo?) -> String {
        bridge == nil ? "Set Up Hue Bridge" : "Manage Hue Bridge"
    }

    static func lightingStatusValue(
        _ status: MusicAmbienceManager.Status,
        relayActiveGroups: [HueAmbienceActiveSyncGroup] = []
    ) -> String {
        lightingChip(status, relayActiveGroups: relayActiveGroups).value
    }

    private static func bridgeChip(_ bridge: HueBridgeInfo?) -> HueAmbienceStatusChip {
        HueAmbienceStatusChip(
            title: "Bridge",
            value: bridge == nil ? "Not Paired" : "Connected",
            tone: bridge == nil ? .neutral : .ready,
            detail: nil
        )
    }

    private static func lightingChip(
        _ status: MusicAmbienceManager.Status,
        relayActiveGroups: [HueAmbienceActiveSyncGroup]
    ) -> HueAmbienceStatusChip {
        switch status {
        case .disabled:
            return HueAmbienceStatusChip(title: "Lighting", value: "Off", tone: .neutral, detail: nil)
        case .unconfigured:
            return HueAmbienceStatusChip(title: "Lighting", value: "Needs Setup", tone: .neutral, detail: nil)
        case .idle:
            return HueAmbienceStatusChip(title: "Lighting", value: "Ready", tone: .ready, detail: nil)
        case .syncing(let detail):
            if detail == MusicAmbienceManager.relayControlStatusTitle && relayActiveGroups.isEmpty {
                return HueAmbienceStatusChip(title: "Lighting", value: "Ready", tone: .ready, detail: nil)
            }
            return HueAmbienceStatusChip(title: "Lighting", value: "Changing", tone: .ready, detail: nil)
        case .paused(let reason):
            return HueAmbienceStatusChip(title: "Lighting", value: "Paused", tone: .neutral, detail: reason)
        case .error(let reason):
            return HueAmbienceStatusChip(title: "Lighting", value: "Needs Attention", tone: .critical, detail: reason)
        }
    }

    private static func syncingChip(
        relayActiveGroups: [HueAmbienceActiveSyncGroup],
        playbackSnapshot: HueAmbiencePlaybackSnapshot?,
        mappings: [HueSonosMapping],
        groupStrategy: HueGroupSyncStrategy
    ) -> HueAmbienceStatusChip {
        if !relayActiveGroups.isEmpty {
            return HueAmbienceStatusChip(
                title: "Syncing",
                value: relayGroupName(for: relayActiveGroups),
                tone: .ready,
                detail: nil
            )
        }

        guard let playbackSnapshot, playbackSnapshot.isPlaying else {
            return HueAmbienceStatusChip(
                title: "Syncing",
                value: "No Active Group",
                tone: .neutral,
                detail: nil
            )
        }

        let ids = playbackIDs(for: playbackSnapshot, groupStrategy: groupStrategy)
        guard !ids.isEmpty else {
            return HueAmbienceStatusChip(
                title: "Syncing",
                value: "No Active Group",
                tone: .neutral,
                detail: nil
            )
        }

        let mappingsByID = Dictionary(uniqueKeysWithValues: mappings.map { ($0.sonosID, $0) })
        guard ids.contains(where: { mappingsByID[$0] != nil }) else {
            return HueAmbienceStatusChip(
                title: "Syncing",
                value: "Not Assigned",
                tone: .neutral,
                detail: nil
            )
        }

        return HueAmbienceStatusChip(
            title: "Syncing",
            value: groupName(for: ids, snapshot: playbackSnapshot, mappingsByID: mappingsByID),
            tone: .ready,
            detail: nil
        )
    }

    private static func playbackIDs(
        for snapshot: HueAmbiencePlaybackSnapshot,
        groupStrategy: HueGroupSyncStrategy
    ) -> [String] {
        let rawIDs: [String]
        switch groupStrategy {
        case .allMappedRooms:
            rawIDs = snapshot.groupMemberIDs.isEmpty
                ? snapshot.selectedSonosID.map { [$0] } ?? []
                : snapshot.groupMemberIDs
        case .coordinatorOnly:
            rawIDs = snapshot.selectedSonosID.map { [$0] } ?? []
        }

        var seenIDs = Set<String>()
        return rawIDs.filter { seenIDs.insert($0).inserted }
    }

    private static func relayGroupName(for groups: [HueAmbienceActiveSyncGroup]) -> String {
        var seenGroupIDs = Set<String>()
        let names = groups.compactMap { group -> String? in
            guard seenGroupIDs.insert(group.groupId).inserted else { return nil }
            let name = group.speakerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }

        guard !names.isEmpty else {
            return groups.count == 1 ? "Active Group" : "\(groups.count) Groups"
        }
        if names.count <= 2 {
            return names.joined(separator: " + ")
        }
        return "\(names[0]) + \(names.count - 1) more"
    }

    private static func groupName(
        for ids: [String],
        snapshot: HueAmbiencePlaybackSnapshot,
        mappingsByID: [String: HueSonosMapping]
    ) -> String {
        let names = ids.compactMap { id -> String? in
            let name = snapshot.groupMemberNamesByID[id]
                ?? mappingsByID[id]?.sonosName
                ?? (id == snapshot.selectedSonosID ? snapshot.selectedSonosName : nil)
            let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedName.isEmpty ? nil : trimmedName
        }

        guard !names.isEmpty else {
            return "Active Group"
        }
        if names.count <= 2 {
            return names.joined(separator: " + ")
        }
        return "\(names[0]) + \(names.count - 1) more"
    }
}

enum HueAssignmentPresentation {
    static func subtitle(mapping: HueSonosMapping?, area: HueAreaResource?) -> String {
        guard mapping != nil else {
            return "No room selected"
        }
        return area?.name ?? "Selected room unavailable"
    }

    static func lightSummary(
        mapping: HueSonosMapping?,
        area: HueAreaResource?,
        lights: [HueLightResource]
    ) -> String {
        let availableLights = areaLights(area: area, lights: lights)
        guard !availableLights.isEmpty else {
            return "No color lights"
        }

        let enabledCount = availableLights.filter { light in
            isLightEnabled(light, mapping: mapping)
        }.count
        return "Lights Used: \(enabledCount) of \(availableLights.count)"
    }

    static func areaLights(area: HueAreaResource?, lights: [HueLightResource]) -> [HueLightResource] {
        guard let area else {
            return []
        }

        let lightsByID = lights.reduce(into: [String: HueLightResource]()) { result, light in
            result[light.id] = light
        }

        return area.childLightIDs.compactMap { lightID in
            guard let light = lightsByID[lightID], light.supportsColor else {
                return nil
            }
            return light
        }
    }

    static func isLightEnabled(_ light: HueLightResource, mapping: HueSonosMapping?) -> Bool {
        guard let mapping else {
            return false
        }

        if mapping.excludedLightIDs.contains(light.id) {
            return false
        }

        return light.participatesInAmbienceByDefault
            || mapping.includedLightIDs.contains(light.id)
    }
}

struct MusicAmbienceSettingsView: View {
    @Bindable var store: HueAmbienceStore
    @Bindable var manager: MusicAmbienceManager
    let sonosSpeakers: [SonosPlayer]
    let playbackSnapshot: HueAmbiencePlaybackSnapshot?
    let presentSetup: () -> Void
    @Bindable private var relay = RelayManager.shared
    @State private var isChangingRelayRuntime = false
    @State private var pendingAmbienceEnabled: Bool?

    var body: some View {
        Group {
            statusOverviewSection
            setupSection
            musicSection
        }
        .task {
            await relay.refreshHueAmbienceStatus()
            manager.refreshStatus()
        }
        .onChange(of: relay.isHueAmbienceRelayPaused) {
            manager.refreshStatus()
        }
        .onChange(of: relay.isHueAmbienceRelayEnabled) {
            manager.refreshStatus()
        }
    }

    private var statusOverviewSection: some View {
        Section {
            LazyVGrid(columns: statusGridColumns, alignment: .leading, spacing: 10) {
                ForEach(statusChips) { chip in
                    HueAmbienceStatusChipView(chip: chip)
                }
            }
            .padding(.vertical, 4)

            if let detail = statusProblemDetail {
                Label(detail, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

        }
    }

    private var setupSection: some View {
        Section {
            setupStatusRow

            Button {
                presentSetup()
            } label: {
                Label(
                    HueAmbienceStatusPresentation.setupActionTitle(bridge: store.bridge),
                    systemImage: "link.badge.plus"
                )
            }
        } header: {
            Text("Setup")
        }
    }

    private var musicSection: some View {
        Section {
            Toggle("Enable Album Ambience", isOn: ambienceEnabledBinding)
                .disabled(
                    store.bridge == nil
                        || store.mappings.isEmpty
                        || isChangingRelayRuntime
                )

            if store.bridge != nil {
                Picker("Group Playback", selection: $store.groupStrategy) {
                    ForEach(HueGroupSyncStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.label).tag(strategy)
                    }
                }

                Picker("When Playback Stops", selection: $store.stopBehavior) {
                    ForEach(HueAmbienceStopBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }

                Picker("Light Motion Speed", selection: $store.flowSpeed) {
                    ForEach(HueAmbienceFlowSpeed.allCases, id: \.self) { flowSpeed in
                        Text(flowSpeed.label).tag(flowSpeed)
                    }
                }

                toneSlider(
                    "Brightness",
                    value: $store.brightnessLevel,
                    range: HueAmbienceToneControl.brightnessRange
                )

                toneSlider(
                    "Saturation",
                    value: $store.saturationLevel,
                    range: HueAmbienceToneControl.saturationRange
                )
            }
        } header: {
            Text(HueAmbienceStatusPresentation.ambienceSectionTitle)
        } footer: {
            Text("Album colors drive the assigned Hue targets.")
        }
        .onChange(of: store.flowSpeed) {
            let actions = syncActions
            Task {
                await actions.syncableSettingChanged()
            }
        }
        .onChange(of: store.brightnessLevel) {
            let actions = syncActions
            Task {
                await actions.syncableSettingChanged()
            }
        }
        .onChange(of: store.saturationLevel) {
            let actions = syncActions
            Task {
                await actions.syncableSettingChanged()
            }
        }
        .onChange(of: store.groupStrategy) {
            let actions = syncActions
            Task {
                await actions.groupPlaybackChanged()
            }
        }
        .onChange(of: store.stopBehavior) {
            let actions = syncActions
            Task {
                await actions.stopBehaviorChanged()
            }
        }
    }

    private func toneSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(HueAmbienceToneControl.percentLabel(for: value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 0.05)
        }
    }

    private var syncActions: MusicAmbienceSettingsSyncActions {
        MusicAmbienceSettingsSyncActions(
            refreshStatus: {
                manager.refreshStatus()
            },
            canSyncToRelay: {
                canSyncToRelay
            },
            syncToRelay: {
                await relay.pushHueAmbienceConfig(
                    store: store,
                    sonosSpeakers: sonosSpeakers
                )
            }
        )
    }

    private var ambienceEnabledBinding: Binding<Bool> {
        Binding {
            pendingAmbienceEnabled ?? HueAmbienceEnableControlPolicy.effectiveIsEnabled(
                localEnabled: store.isEnabled,
                relayAvailable: relay.isAvailable,
                relayConfigured: relay.isHueAmbienceRelayConfigured,
                relayRunning: relay.isHueAmbienceRelayRunning
            )
        } set: { enabled in
            guard usesRelayRuntimeControl else {
                store.isEnabled = enabled
                let actions = syncActions
                Task {
                    await actions.enabledChanged()
                }
                return
            }

            pendingAmbienceEnabled = enabled
            isChangingRelayRuntime = true
            Task {
                await relay.setHueAmbienceRunning(enabled)
                manager.refreshStatus()
                pendingAmbienceEnabled = nil
                isChangingRelayRuntime = false
            }
        }
    }

    private var usesRelayRuntimeControl: Bool {
        HueAmbienceEnableControlPolicy.usesRelayRuntime(
            relayAvailable: relay.isAvailable,
            relayConfigured: relay.isHueAmbienceRelayConfigured
        )
    }

    private var canSyncToRelay: Bool {
        relay.url != nil
            && store.bridge != nil
            && !store.mappings.isEmpty
            && relay.hueAmbienceSyncStatus != .syncing
    }

    private var statusGridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 90), spacing: 10),
            GridItem(.flexible(minimum: 90), spacing: 10),
        ]
    }

    private var statusChips: [HueAmbienceStatusChip] {
        HueAmbienceStatusPresentation.statusChips(
            bridge: store.bridge,
            lightingStatus: manager.status,
            relayActiveGroups: relay.hueAmbienceActiveGroups,
            playbackSnapshot: playbackSnapshot,
            mappings: store.mappings,
            groupStrategy: store.groupStrategy
        )
    }

    private var statusProblemDetail: String? {
        statusChips.compactMap(\.detail).first
    }

    private var setupStatusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title3)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.status.title)
                    .font(.subheadline.weight(.semibold))
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        switch manager.status {
        case .disabled:
            return "lightswitch.off"
        case .unconfigured:
            return "link.badge.plus"
        case .idle:
            return "checkmark.circle.fill"
        case .syncing:
            return "sparkles"
        case .paused:
            return "pause.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .syncing, .idle:
            return .green
        case .paused, .unconfigured:
            return .orange
        case .error:
            return .red
        case .disabled:
            return .secondary
        }
    }

    private var statusSubtitle: String {
        if let bridge = store.bridge {
            return "\(bridge.name) · \(store.mappings.count) assignment\(store.mappings.count == 1 ? "" : "s")"
        }
        return "Pair a Hue Bridge and assign Hue targets to Sonos rooms."
    }
}
