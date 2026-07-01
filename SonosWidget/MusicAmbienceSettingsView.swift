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

    var body: some View {
        Group {
            statusOverviewSection
            setupSection
            musicSection
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
            Toggle("Enable Album Ambience", isOn: $store.isEnabled)
                .disabled(store.bridge == nil || store.mappings.isEmpty)

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
        .onChange(of: store.isEnabled) {
            let actions = syncActions
            Task {
                await actions.enabledChanged()
            }
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

private struct HueAmbienceStatusChipView: View {
    let chip: HueAmbienceStatusChip

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(chip.tone.color)
                .frame(width: 8, height: 8)
                .overlay {
                    if chip.tone == .working {
                        Circle()
                            .stroke(chip.tone.color.opacity(0.55), lineWidth: 1)
                            .scaleEffect(1.6)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(chip.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(chip.value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chip.title): \(chip.value)")
    }
}

extension HueAmbienceStatusTone {
    var color: Color {
        switch self {
        case .ready:
            return .green
        case .working:
            return .yellow
        case .critical:
            return .red
        case .neutral:
            return .secondary
        }
    }
}

struct HueAmbienceSetupSheet: View {
    @Bindable var store: HueAmbienceStore
    @Bindable var manager: MusicAmbienceManager
    let sonosSpeakers: [SonosPlayer]

    @Environment(\.dismiss) private var dismiss
    @Bindable private var relay = RelayManager.shared
    @State private var bridgeIP = ""
    @State private var bridgeName = "Hue Bridge"
    @State private var discoveredBridges: [HueBridgeInfo] = []
    @State private var selectedBridgeID = ""
    @State private var hueAreas: [HueAreaResource] = []
    @State private var hueLights: [HueLightResource] = []
    @State private var setupError: String?
    @State private var isBusy = false
    @State private var isManualBridgeExpanded = false
    @State private var isResetConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                bridgeSection
                discoveredBridgeSection
                assignmentsSection
                effectSection
                manualPairingSection
            }
            .navigationTitle("Hue Ambience")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        manager.refreshStatus()
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadStoredBridgeState()
            }
            .confirmationDialog("Forget Hue Bridge?", isPresented: $isResetConfirmationPresented) {
                Button("Forget Bridge", role: .destructive) {
                    Task { await resetMusicAmbience() }
                }
            } message: {
                Text("This clears the paired Hue Bridge, speaker assignments, and cached Hue lights. Pair again after pressing the Hue Bridge button.")
            }
        }
    }

    private var bridgeSection: some View {
        Section {
            if let bridge = store.bridge {
                LabeledContent("Name", value: bridge.name)
                LabeledContent("IP", value: bridge.ipAddress)
                LabeledContent("Available Lights", value: "\(colorLightCount)")
            } else {
                Label("No Hue Bridge paired", systemImage: "lightbulb.slash")
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: bridgeActionColumns, alignment: .leading, spacing: 8) {
                Button {
                    Task { await findHueBridges() }
                } label: {
                    Label("Find Bridge", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)

                if store.bridge != nil {
                    Button {
                        Task { await refreshHueResources() }
                    } label: {
                        Label(HueAmbienceSetupPresentation.updateLightsActionTitle, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)

                    Button(role: .destructive) {
                        isResetConfirmationPresented = true
                    } label: {
                        Label("Forget Bridge", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
                }
            }

            if isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let setupError {
                Label(setupError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Bridge")
        }
    }

    @ViewBuilder
    private var discoveredBridgeSection: some View {
        if !discoveredBridges.isEmpty {
            Section("Discovered") {
                Picker("Bridge", selection: $selectedBridgeID) {
                    ForEach(discoveredBridges) { bridge in
                        Text("\(bridge.name) · \(bridge.ipAddress)").tag(bridge.id)
                    }
                }

                Button {
                    Task { await pairSelectedBridge() }
                } label: {
                    Label("Pair Selected Bridge", systemImage: "link.badge.plus")
                }
                .disabled(selectedBridge == nil || isBusy)
            }
        }
    }

    private var manualPairingSection: some View {
        Section {
            DisclosureGroup("Manual Pairing", isExpanded: $isManualBridgeExpanded) {
                TextField("192.168.1.20", text: $bridgeIP)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Hue Bridge", text: $bridgeName)
                Button {
                    Task { await pairManualBridge() }
                } label: {
                    Label("Pair Manual Bridge", systemImage: "link")
                }
                .disabled(manualBridge == nil || isBusy)
            }
        } header: {
            Text("Manual")
        }
    }

    private var assignmentsSection: some View {
        Section {
            if sonosSpeakers.isEmpty {
                Text("Connect Sonos speakers before assigning Hue areas.")
                    .foregroundStyle(.secondary)
            } else if assignmentAreas.isEmpty {
                Text("Pair or refresh the Hue Bridge to load assignable areas.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sonosSpeakers) { speaker in
                    HueMappingRow(
                        store: store,
                        manager: manager,
                        speaker: speaker,
                        areas: assignmentAreas,
                        lights: hueLights
                    )
                }
            }
        } header: {
            Text("Rooms & Speakers")
        } footer: {
            Text("Choose which Hue room follows each speaker.")
        }
    }

    private var effectSection: some View {
        Section("Light Motion") {
            Picker("Style", selection: $store.motionStyle) {
                ForEach(HueAmbienceMotionStyle.allCases, id: \.self) { motionStyle in
                    Text(motionStyle.label).tag(motionStyle)
                }
            }
        }
    }

    private var bridgeActionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 132), spacing: 8)]
    }

    private var selectedBridge: HueBridgeInfo? {
        discoveredBridges.first { $0.id == selectedBridgeID }
    }

    private var assignmentAreas: [HueAreaResource] {
        HueAmbienceAreaOptions.displayAreas(from: hueAreas, lights: hueLights)
    }

    private var colorLightCount: Int {
        hueLights.filter(\.supportsColor).count
    }

    private var manualBridge: HueBridgeInfo? {
        let trimmedIP = bridgeIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIP.isEmpty else {
            return nil
        }

        let trimmedName = bridgeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bridgeID = store.bridge?.ipAddress == trimmedIP
            ? store.bridge?.id ?? trimmedIP.replacingOccurrences(of: ".", with: "-")
            : trimmedIP.replacingOccurrences(of: ".", with: "-")

        return HueBridgeInfo(
            id: bridgeID,
            ipAddress: trimmedIP,
            name: trimmedName.isEmpty ? "Hue Bridge" : trimmedName
        )
    }

    private func loadStoredBridgeState() {
        guard let bridge = store.bridge else {
            return
        }

        bridgeIP = bridge.ipAddress
        bridgeName = bridge.name
        mergeDiscoveredBridge(bridge)
        hueAreas = store.hueAreas
        hueLights = store.hueLights

        if hueAreas.isEmpty || store.hueResources.needsFunctionMetadataRefresh {
            Task { await refreshHueResources() }
        }
    }

    private func findHueBridges() async {
        setupError = nil
        isBusy = true
        defer { isBusy = false }

        let bridges = await HueBridgeDiscovery.discoverLocal()
        discoveredBridges = bridges
        if let bridge = store.bridge {
            mergeDiscoveredBridge(bridge)
        }
        selectedBridgeID = selectedBridgeID.isEmpty ? discoveredBridges.first?.id ?? "" : selectedBridgeID
        if discoveredBridges.isEmpty {
            setupError = "No Hue Bridge was found on this local network. " +
                "Make sure Local Network access is allowed and this iPhone is on the same Wi-Fi as the Bridge, " +
                "or pair manually with the Bridge IP."
        }
    }

    private func pairSelectedBridge() async {
        guard let selectedBridge else {
            return
        }

        await pairAndFetchResources(for: selectedBridge)
    }

    private func pairManualBridge() async {
        guard let bridge = manualBridge else {
            return
        }

        await pairAndFetchResources(for: bridge)
    }

    private func pairAndFetchResources(for bridge: HueBridgeInfo) async {
        setupError = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let client = HueBridgeClient(bridge: bridge)
            _ = try await client.pairBridge(deviceType: "Charm Player#iPhone")
            store.bridge = bridge
            hueAreas = store.hueAreas
            hueLights = store.hueLights
            bridgeIP = bridge.ipAddress
            bridgeName = bridge.name
            mergeDiscoveredBridge(bridge)
            manager.refreshStatus()

            let resources = try await client.fetchResources()
            guard store.updateResources(resources, forBridgeID: bridge.id) else {
                return
            }
            hueAreas = store.hueAreas
            hueLights = store.hueLights
            manager.refreshStatus()
            await syncRelayIfPossible()
        } catch {
            setupError = error.localizedDescription
            manager.refreshStatus()
        }
    }

    private func refreshHueResources() async {
        guard let bridge = store.bridge else {
            return
        }

        setupError = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let resources = try await HueBridgeClient(bridge: bridge).fetchResources()
            guard store.updateResources(resources, forBridgeID: bridge.id) else {
                return
            }
            hueAreas = store.hueAreas
            hueLights = store.hueLights
            manager.refreshStatus()
            await syncRelayIfPossible()
        } catch {
            let canSyncCachedConfig = relay.url != nil && store.bridge != nil && !store.mappings.isEmpty
            setupError = canSyncCachedConfig
                ? "\(error.localizedDescription). Cached Hue setup was sent to NAS Relay if available."
                : error.localizedDescription
            if canSyncCachedConfig {
                await syncRelayIfPossible()
            }
        }
    }

    private func resetMusicAmbience() async {
        setupError = nil
        isBusy = true
        defer { isBusy = false }

        await relay.clearHueAmbienceConfig()
        store.disconnectBridge()
        hueAreas = []
        hueLights = []
        selectedBridgeID = ""
        manager.refreshStatus()
    }

    private func syncRelayIfPossible() async {
        guard relay.url != nil,
              store.bridge != nil,
              !store.mappings.isEmpty else {
            return
        }

        await relay.pushHueAmbienceConfig(
            store: store,
            sonosSpeakers: sonosSpeakers
        )
    }

    private func mergeDiscoveredBridge(_ bridge: HueBridgeInfo) {
        if let index = discoveredBridges.firstIndex(where: { $0.id == bridge.id }) {
            discoveredBridges[index] = bridge
        } else {
            discoveredBridges.append(bridge)
        }

        selectedBridgeID = bridge.id
    }
}

private struct HueMappingRow: View {
    @Bindable var store: HueAmbienceStore
    @Bindable var manager: MusicAmbienceManager
    let speaker: SonosPlayer
    let areas: [HueAreaResource]
    let lights: [HueLightResource]

    @State private var lightCustomizationArea: HueAreaResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "hifispeaker.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(speaker.name)
                        .font(.subheadline.weight(.semibold))
                    Text(assignmentSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                areaMenu
            }

            if showsLightSelection, let currentArea, !areaLights.isEmpty {
                Button {
                    lightCustomizationArea = currentArea
                } label: {
                    HStack(spacing: 10) {
                        Label(lightSummary, systemImage: "lightbulb.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("Customize")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
            }

            if store.mapping(forSonosID: speaker.id) != nil {
                Button(role: .destructive) {
                    removeAssignment()
                } label: {
                    Label("Remove Assignment", systemImage: "minus.circle")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .sheet(item: $lightCustomizationArea) { area in
            HueLightSelectionSheet(
                store: store,
                manager: manager,
                speaker: speaker,
                area: area,
                lights: areaLights(for: area)
            )
        }
    }

    private var areaMenu: some View {
        Menu {
            ForEach(areas) { area in
                Button {
                    saveArea(area)
                } label: {
                    if currentArea?.id == area.id {
                        Label(areaMenuTitle(area), systemImage: "checkmark")
                    } else {
                        Text(areaMenuTitle(area))
                    }
                }
            }
        } label: {
            Label(currentArea == nil ? "Choose" : "Change", systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var currentMapping: HueSonosMapping? {
        store.mapping(forSonosID: speaker.id)
    }

    private var currentArea: HueAreaResource? {
        guard let target = currentMapping?.preferredTarget else {
            return nil
        }
        return areas.first { $0.ambienceTarget == target }
    }

    private var showsLightSelection: Bool {
        currentMapping?.preferredTarget?.allowsManualLightSelection == true
    }

    private var areaLights: [HueLightResource] {
        areaLights(for: currentArea)
    }

    private var assignmentSubtitle: String {
        HueAssignmentPresentation.subtitle(mapping: currentMapping, area: currentArea)
    }

    private var lightSummary: String {
        HueAssignmentPresentation.lightSummary(mapping: currentMapping, area: currentArea, lights: lights)
    }

    private func areaLights(for area: HueAreaResource?) -> [HueLightResource] {
        HueAssignmentPresentation.areaLights(area: area, lights: lights)
    }

    private func saveArea(_ area: HueAreaResource) {
        guard currentArea?.id != area.id else {
            return
        }

        let didSave = store.assignArea(
            sonosID: speaker.id,
            sonosName: speaker.name,
            areaID: area.id,
            from: areas,
            lights: lights
        )
        if didSave {
            manager.refreshStatus()
        }
    }

    private func removeAssignment() {
        store.removeMapping(forSonosID: speaker.id)
        manager.refreshStatus()
    }

    private func areaMenuTitle(_ area: HueAreaResource) -> String {
        "\(area.name) · \(area.kind.label)"
    }
}

private struct HueLightSelectionSheet: View {
    @Bindable var store: HueAmbienceStore
    @Bindable var manager: MusicAmbienceManager
    let speaker: SonosPlayer
    let area: HueAreaResource
    let lights: [HueLightResource]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if !recommendedLights.isEmpty {
                    Section("Recommended") {
                        ForEach(recommendedLights) { light in
                            lightToggle(light)
                        }
                    }
                }

                if !otherLights.isEmpty {
                    Section {
                        ForEach(otherLights) { light in
                            lightToggle(light)
                        }
                    } header: {
                        Text("Other Lights")
                    } footer: {
                        Text("Task lights stay off unless you turn them on.")
                    }
                }
            }
            .navigationTitle("Lights Used")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var currentMapping: HueSonosMapping? {
        store.mapping(forSonosID: speaker.id)
    }

    private var recommendedLights: [HueLightResource] {
        lights.filter(\.participatesInAmbienceByDefault)
    }

    private var otherLights: [HueLightResource] {
        lights.filter { !$0.participatesInAmbienceByDefault }
    }

    private func lightToggle(_ light: HueLightResource) -> some View {
        Toggle(isOn: Binding(
            get: { HueAssignmentPresentation.isLightEnabled(light, mapping: currentMapping) },
            set: { setLight(light, isEnabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(light.name)
                Text(light.function.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func setLight(_ light: HueLightResource, isEnabled: Bool) {
        guard var mapping = currentMapping else {
            return
        }

        if isEnabled {
            mapping.excludedLightIDs.remove(light.id)
            if light.participatesInAmbienceByDefault {
                mapping.includedLightIDs.remove(light.id)
            } else {
                mapping.includedLightIDs.insert(light.id)
            }
        } else {
            mapping.includedLightIDs.remove(light.id)
            if light.participatesInAmbienceByDefault {
                mapping.excludedLightIDs.insert(light.id)
            } else {
                mapping.excludedLightIDs.remove(light.id)
            }
        }

        store.upsertMapping(mapping)
        manager.refreshStatus()
    }
}
