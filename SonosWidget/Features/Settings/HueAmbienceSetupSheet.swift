import SwiftUI
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
