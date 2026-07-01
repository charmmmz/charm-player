import SwiftUI
import UIKit

enum SettingsDetailFormLayout {
    static func bottomContentInset(
        isMiniPlayerVisible: Bool,
        usesSystemAccessory: Bool
    ) -> CGFloat {
        guard usesSystemAccessory else { return 0 }
        return MiniPlayerLayoutMetrics.systemAccessoryContentBottomInset(
            isMiniPlayerVisible: isMiniPlayerVisible
        )
    }
}

enum LiveActivitySettingsPresentation {
    static let sectionTitle = "Live Activity"
    static let footer = "Choose how playback controls appear on the Lock Screen."
}

enum HueLightingRelayPresentation {
    static let sectionTitle = "NAS Relay"
    static let footer = "Leave the URL blank to auto-discover NAS Relay. Hue Ambience owns lighting setup updates."

    static func statusRows(
        relayStatus: RelayManager.Status,
        syncStatus: RelayManager.HueAmbienceSyncStatus,
        hasBridge: Bool,
        assignmentCount: Int
    ) -> [HueAmbienceStatusChip] {
        [
            connectionRow(relayStatus),
            lightingSetupRow(syncStatus: syncStatus, hasBridge: hasBridge, assignmentCount: assignmentCount),
        ]
    }

    private static func connectionRow(_ status: RelayManager.Status) -> HueAmbienceStatusChip {
        switch status {
        case .disabled:
            return HueAmbienceStatusChip(
                title: "Connection",
                value: "Not Set",
                tone: .neutral,
                detail: "Enter a relay URL or leave it blank for auto-discovery."
            )
        case .probing:
            return HueAmbienceStatusChip(title: "Connection", value: "Checking", tone: .working, detail: nil)
        case .connected:
            return HueAmbienceStatusChip(title: "Connection", value: "Connected", tone: .ready, detail: nil)
        case .unreachable(let reason):
            return HueAmbienceStatusChip(title: "Connection", value: "Offline", tone: .critical, detail: reason)
        }
    }
}

enum HueLightingRelayAutoSyncPolicy {
    static func shouldSyncAfterConnection(
        relayStatus: RelayManager.Status,
        hasBridge: Bool,
        assignmentCount: Int,
        syncStatus: RelayManager.HueAmbienceSyncStatus
    ) -> Bool {
        guard case .connected = relayStatus,
              hasBridge,
              assignmentCount > 0,
              syncStatus != .syncing else {
            return false
        }

        return true
    }
}

private extension HueLightingRelayPresentation {
    private static func lightingSetupRow(
        syncStatus: RelayManager.HueAmbienceSyncStatus,
        hasBridge: Bool,
        assignmentCount: Int
    ) -> HueAmbienceStatusChip {
        guard hasBridge else {
            return HueAmbienceStatusChip(
                title: "Lighting Setup",
                value: "Needs Bridge",
                tone: .neutral,
                detail: "Pair a Hue Bridge before updating the relay."
            )
        }

        guard assignmentCount > 0 else {
            return HueAmbienceStatusChip(
                title: "Lighting Setup",
                value: "Needs Rooms",
                tone: .neutral,
                detail: "Choose which Hue rooms follow each speaker first."
            )
        }

        switch syncStatus {
        case .idle:
            return HueAmbienceStatusChip(title: "Lighting Setup", value: "Not Updated", tone: .neutral, detail: nil)
        case .syncing:
            return HueAmbienceStatusChip(title: "Lighting Setup", value: "Updating", tone: .working, detail: nil)
        case .synced:
            return HueAmbienceStatusChip(title: "Lighting Setup", value: "Updated", tone: .ready, detail: nil)
        case .failed(let reason):
            return HueAmbienceStatusChip(
                title: "Lighting Setup",
                value: "Could Not Update",
                tone: .critical,
                detail: reason
            )
        }
    }
}

/// Consolidated Settings tab. Groups Sonos account, speakers, external
/// connections, feature settings, diagnostics, and about-app rows into one
/// place, replacing the two per-tab menus that used to live in `PlayerView`
/// (ellipsis) and `SearchView` (sliders).
struct SettingsView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var isConnectingSonos = false
    /// Bound to the Live Activity Relay TextField. We only push edits into
    /// `RelayManager` on submit / blur — typing per-character would otherwise
    /// fire a probe with every keystroke.
    @State private var relayURLDraft: String = RelayManager.shared.urlString

    /// Re-read the singleton through @Bindable so SwiftUI subscribes to its
    /// observable changes and re-renders the status row.
    @Bindable private var relay = RelayManager.shared

    @FocusState private var focusedInputField: SettingsInputField?
    @Bindable private var auth = SonosAuth.shared
    @Bindable private var hueStore = HueAmbienceStore.shared
    @Bindable private var musicAmbience = MusicAmbienceManager.shared
    @State private var musicAmbienceSetupPresentation = MusicAmbienceSetupPresentationState()
    @State private var settingsPath: [SettingsHubDestination] = []
    @State private var liveActivityStyle: LiveActivityStyle = SharedStorage.liveActivityStyle
    @State private var lastHueRelayAutoSyncKey: String?

    var body: some View {
        NavigationStack(path: $settingsPath) {
            Form {
                settingsHubSection
                aboutSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .scrollContentBackground(.hidden)
            .background {
                backgroundLayer.ignoresSafeArea()
            }
            .preferredColorScheme(.dark)
            .navigationDestination(for: SettingsHubDestination.self) { destination in
                settingsDestinationView(for: destination)
            }
            .onAppear {
                relayURLDraft = relay.urlString
                liveActivityStyle = SharedStorage.liveActivityStyle
                Task {
                    await relay.probeNow()
                    await autoSyncHueLightingSetupIfNeeded()
                }
                musicAmbience.refreshStatus()
            }
            .onChange(of: relay.status) { _, _ in
                Task { await autoSyncHueLightingSetupIfNeeded() }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    finishEditingFocusedInput()
                }
            }
        }
        .sheet(isPresented: musicAmbienceSetupBinding) {
            HueAmbienceSetupSheet(
                store: hueStore,
                manager: musicAmbience,
                sonosSpeakers: displayedSpeakers
            )
        }
    }

    // MARK: - Settings Hub

    private var settingsHubSection: some View {
        Section {
            ForEach(SettingsHubDestination.primary) { destination in
                NavigationLink(value: destination) {
                    SettingsHubDestinationRow(
                        destination: destination,
                        status: settingsHubStatus(for: destination)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func settingsDestinationView(for destination: SettingsHubDestination) -> some View {
        switch destination {
        case .sonos:
            settingsDetailForm(title: destination.title) {
                sonosAccountSection
                speakersSection
                musicServicesSection
            }
        case .hueAmbience:
            settingsDetailForm(title: destination.title) {
                MusicAmbienceSettingsView(
                    store: hueStore,
                    manager: musicAmbience,
                    sonosSpeakers: displayedSpeakers,
                    playbackSnapshot: manager.musicAmbienceSnapshot(),
                    presentSetup: {
                        musicAmbienceSetupPresentation.present()
                    }
                )
            }
        case .externalConnection:
            settingsDetailForm(title: destination.title) {
                liveActivitySection
                hueLightingRelaySection
            }
        case .diagnostics:
            settingsDetailForm(title: destination.title) {
                DiagnosticLogView()
            }
        }
    }

    private func settingsDetailForm<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background {
            backgroundLayer.ignoresSafeArea()
        }
        .settingsDetailMiniPlayerContentInset(manager: manager)
        .preferredColorScheme(.dark)
    }

    private func settingsHubStatus(for destination: SettingsHubDestination) -> String? {
        switch destination {
        case .sonos:
            return "\(sonosAccountStatusSummary) · \(speakersStatusSummary)"
        case .hueAmbience:
            return hueAmbienceHubStatusSummary
        case .externalConnection:
            return "Activity \(liveActivityStyle.displayName) · Relay \(relayStatusTitle)"
        case .diagnostics:
            return "Local logs · category filters"
        }
    }

    private var sonosAccountStatusSummary: String {
        switch auth.sessionState {
        case .connected:
            return "Account connected"
        case .expired:
            return "Session expired"
        case .checking:
            return "Checking account"
        case .disconnected:
            return "Account disconnected"
        }
    }

    private var speakersStatusSummary: String {
        let count = displayedSpeakers.count
        switch count {
        case 0:
            return "No speakers"
        case 1:
            return "1 speaker"
        default:
            return "\(count) speakers"
        }
    }

    private var hueAmbienceHubStatusSummary: String {
        guard let bridge = hueStore.bridge else {
            return "Bridge not paired · Lighting \(hueAmbienceLightingStatusValue)"
        }

        let assignmentCount = hueStore.mappings.count
        let assignments = assignmentCount == 1 ? "1 assignment" : "\(assignmentCount) assignments"
        return "Lighting \(hueAmbienceLightingStatusValue) · \(bridge.name) · \(assignments)"
    }

    private var hueAmbienceLightingStatusValue: String {
        HueAmbienceStatusPresentation.lightingStatusValue(
            musicAmbience.status,
            relayActiveGroups: relay.hueAmbienceActiveGroups
        )
    }

    private var musicAmbienceSetupBinding: Binding<Bool> {
        Binding {
            musicAmbienceSetupPresentation.isPresented
        } set: { isPresented in
            if isPresented {
                musicAmbienceSetupPresentation.present()
            } else {
                musicAmbienceSetupPresentation.dismiss()
            }
        }
    }

    private var inputDrafts: SettingsInputDrafts {
        SettingsInputDrafts(
            relayURL: relayURLDraft
        )
    }

    private func finishEditingFocusedInput() {
        finishEditingInput(focusedInputField)
    }

    private func finishEditingInput(_ field: SettingsInputField?) {
        focusedInputField = inputDrafts.commit(
            focusedField: field,
            relayURL: { relay.setURL($0) }
        )
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            if let image = manager.albumArtImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                Color.black.opacity(0.6)
            } else {
                Color.black
            }
        }
    }

    // MARK: - Sonos Account

    @ViewBuilder
    private var sonosAccountSection: some View {
        Section {
            switch auth.sessionState {
            case .connected:
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected")
                            .font(.subheadline.weight(.semibold))
                        Text("Sonos Cloud session active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        SonosAuth.shared.logout()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }

            case .expired:
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Session Expired")
                            .font(.subheadline.weight(.semibold))
                        Text("Reconnect your Sonos account")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reconnect") {
                        connectSonos(reconnect: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isConnectingSonos)
                }

            case .checking:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Checking")
                            .font(.subheadline.weight(.semibold))
                        Text("Refreshing Sonos Cloud session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

            case .disconnected:
                connectSonosButton
            }
        } header: {
            Text("Sonos Account")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sonos account sign-in is only needed when you want fallback control away from your local network.")
                if let error = auth.lastErrorMessage {
                    Text(error)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var connectSonosButton: some View {
        Button {
            connectSonos()
        } label: {
            HStack {
                Label("Connect Sonos Account",
                      systemImage: "person.crop.circle.badge.plus")
                Spacer()
                if isConnectingSonos {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(isConnectingSonos)
    }

    private func connectSonos(reconnect: Bool = false) {
        isConnectingSonos = true
        Task {
            let window = await UIApplication.shared.sonosPresentationWindow
            let success = if reconnect {
                await auth.reconnect(from: window)
            } else {
                await auth.startLogin(from: window)
            }
            if success {
                await manager.resolveCloudGroupId()
                await manager.refreshState()
                await searchManager.forceReprobe()
            }
            isConnectingSonos = false
        }
    }

    // MARK: - Speakers

    @ViewBuilder
    private var speakersSection: some View {
        Section {
            if displayedSpeakers.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "hifispeaker.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No speakers discovered yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(displayedSpeakers) { speaker in
                    speakerRow(speaker)
                }
            }

            Button {
                manager.showingAddSpeaker = true
            } label: {
                Label("Enter IP Manually", systemImage: "keyboard")
            }
        } header: {
            sectionHeader(title: "Speakers",
                          refresh: { manager.rescan() },
                          isBusy: manager.discovery.isScanning)
        } footer: {
            Text("Tap the refresh icon to rescan your network, or use Enter IP Manually if a speaker can't be found.")
        }
    }

    /// Coordinators only (one row per Sonos room/group) and never invisible
    /// sub/sat satellites. Sorted alphabetically — the Home tab already shows
    /// per-zone playback state, so Settings doesn't need to highlight which
    /// speaker is the "current control target".
    private var displayedSpeakers: [SonosPlayer] {
        let pool = manager.speakers.isEmpty
            ? manager.allSpeakers.filter { $0.isCoordinator && !$0.isInvisible }
            : manager.speakers.filter { !$0.isInvisible }
        return pool.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func speakerRow(_ speaker: SonosPlayer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hifispeaker.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(speaker.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(speaker.playbackIP)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    // MARK: - Music Services

    @ViewBuilder
    private var musicServicesSection: some View {
        Section {
            if searchManager.isProbing {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Detecting linked services…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if searchManager.linkedAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No Music Services Found",
                          systemImage: "music.note.list")
                        .font(.subheadline.weight(.semibold))
                    Text("Connect your Sonos account to discover linked music services for Browse search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(sortedAccounts, id: \.serviceId) { account in
                    serviceRow(account)
                }
            }
        } header: {
            sectionHeader(title: "Music Services",
                          refresh: { Task { await searchManager.forceReprobe() } },
                          isBusy: searchManager.isProbing)
        } footer: {
            Text("Toggle which Sonos Cloud-linked services appear in Browse search results. Local network service metadata is used only for playback hints and badges.")
        }
    }

    // MARK: - Section Header with Inline Refresh

    /// Form `Section` header with an inline refresh glyph on the trailing
    /// edge. Preserves SwiftUI's default header font/casing on the title while
    /// letting the button look like a small affordance next to it.
    private func sectionHeader(title: String,
                                refresh: @escaping () -> Void,
                                isBusy: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            Button(action: refresh) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .textCase(nil)
            .disabled(isBusy)
        }
    }

    private var sortedAccounts: [SonosCloudAPI.CloudMusicServiceAccount] {
        let pinned: Set<String> = ["3079", "52231", "51463", "42247", "49671"]
        return searchManager.linkedAccounts.sorted { a, b in
            let aPinned = pinned.contains(a.serviceId ?? "")
            let bPinned = pinned.contains(b.serviceId ?? "")
            if aPinned != bPinned { return aPinned }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private func serviceRow(_ account: SonosCloudAPI.CloudMusicServiceAccount) -> some View {
        let sid = account.serviceId ?? ""
        let enabled = searchManager.serviceEnabled[sid] ?? true

        return HStack(spacing: 12) {
            CloudServiceBrandMark(
                cloudServiceId: sid,
                displayNameHint: account.displayName,
                dimension: 24,
                symbolUsesTitle3: true
            )
            .foregroundStyle(enabled ? .primary : .secondary)
            .opacity(enabled ? 1 : 0.45)
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .foregroundStyle(enabled ? .primary : .secondary)
                if let nick = account.nickname, nick != account.displayName {
                    Text(nick)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { searchManager.serviceEnabled[sid] ?? true },
                set: { searchManager.setServiceEnabled(serviceId: sid, enabled: $0) }
            ))
            .labelsHidden()
        }
    }

    // MARK: - Live Activity & Relay

    private var liveActivityStyleBinding: Binding<LiveActivityStyle> {
        Binding {
            liveActivityStyle
        } set: { newStyle in
            guard liveActivityStyle != newStyle else { return }
            liveActivityStyle = newStyle
            manager.updateLiveActivityStyle(newStyle)
        }
    }

    @ViewBuilder
    private var liveActivitySection: some View {
        Section {
            Picker("Live Activity Style", selection: liveActivityStyleBinding) {
                ForEach(LiveActivityStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                Image(systemName: liveActivityStyle.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(liveActivityStyle.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(liveActivityStyle.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

        } header: {
            Text(LiveActivitySettingsPresentation.sectionTitle)
        } footer: {
            Text(LiveActivitySettingsPresentation.footer)
        }
    }

    @ViewBuilder
    private var hueLightingRelaySection: some View {
        Section {
            TextField("Auto-discover, or enter http://192.168.50.10:8787", text: $relayURLDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .focused($focusedInputField, equals: .relayURL)
                .onSubmit {
                    finishEditingInput(.relayURL)
                }

            relayStatusRow

            Button {
                // Commit any pending edits (in case the user typed but didn't
                // press return) and force an immediate probe.
                let urlChanged = relay.urlString != relayURLDraft
                finishEditingInput(.relayURL)
                if !urlChanged {
                    Task { await relay.probeNow() }
                }
            } label: {
                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
            }

            ForEach(hueLightingRelayRows) { row in
                HueLightingRelayStatusRow(row: row)
            }
        } header: {
            Text(HueLightingRelayPresentation.sectionTitle)
        } footer: {
            Text(HueLightingRelayPresentation.footer)
        }
    }

    private var hueLightingRelayRows: [HueAmbienceStatusChip] {
        HueLightingRelayPresentation.statusRows(
            relayStatus: relay.status,
            syncStatus: relay.hueAmbienceSyncStatus,
            hasBridge: hueStore.bridge != nil,
            assignmentCount: hueStore.mappings.count
        )
    }

    private var hueRelayAutoSyncKey: String? {
        guard let relayURL = relay.url?.absoluteString,
              let bridgeID = hueStore.bridge?.id,
              !hueStore.mappings.isEmpty else {
            return nil
        }

        let mappingsKey = hueStore.mappings
            .map { mapping in
                [
                    mapping.sonosID,
                    mapping.preferredTarget?.stableKey ?? "none",
                    mapping.fallbackTarget?.stableKey ?? "none",
                    mapping.includedLightIDs.sorted().joined(separator: ","),
                    mapping.excludedLightIDs.sorted().joined(separator: ","),
                    mapping.capability.rawValue,
                ].joined(separator: ":")
            }
            .sorted()
            .joined(separator: "|")

        return [
            relayURL,
            bridgeID,
            String(hueStore.isEnabled),
            hueStore.groupStrategy.rawValue,
            hueStore.stopBehavior.rawValue,
            hueStore.motionStyle.rawValue,
            hueStore.flowSpeed.rawValue,
            String(hueStore.brightnessLevel),
            String(hueStore.saturationLevel),
            mappingsKey,
            String(hueStore.hueAreas.count),
            String(hueStore.hueLights.count),
        ].joined(separator: "||")
    }

    private func autoSyncHueLightingSetupIfNeeded() async {
        guard HueLightingRelayAutoSyncPolicy.shouldSyncAfterConnection(
            relayStatus: relay.status,
            hasBridge: hueStore.bridge != nil,
            assignmentCount: hueStore.mappings.count,
            syncStatus: relay.hueAmbienceSyncStatus
        ),
        let syncKey = hueRelayAutoSyncKey,
        lastHueRelayAutoSyncKey != syncKey else {
            return
        }

        lastHueRelayAutoSyncKey = syncKey
        await relay.pushHueAmbienceConfig(
            store: hueStore,
            sonosSpeakers: displayedSpeakers
        )

        if case .failed = relay.hueAmbienceSyncStatus {
            lastHueRelayAutoSyncKey = nil
        }
    }

    @ViewBuilder
    private var relayStatusRow: some View {
        HStack(spacing: 12) {
            relayStatusIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(relayStatusTitle)
                    .font(.subheadline.weight(.semibold))
                if let detail = relayStatusDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }
            }
        }
    }

    private var relayStatusIndicator: some View {
        let color: Color
        switch relay.status {
        case .connected: color = .green
        case .probing:   color = .yellow
        case .disabled:  color = .secondary
        case .unreachable: color = .red
        }
        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay {
                if case .probing = relay.status {
                    Circle().stroke(Color.yellow, lineWidth: 1).scaleEffect(1.5)
                        .opacity(0.5)
                }
            }
    }

    private var relayStatusTitle: String {
        switch relay.status {
        case .disabled:                       return "Disabled"
        case .probing:                        return "Probing…"
        case .connected(let n) where n == 1:  return "Connected · 1 group"
        case .connected(let n):               return "Connected · \(n) groups"
        case .unreachable:                    return "Unreachable"
        }
    }

    private var relayStatusDetail: String? {
        switch relay.status {
        case .disabled:
            return "Leave the URL blank to search for a relay on this network."
        case .probing:
            if relay.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let message = relay.relayDiscoveryMessage, !message.isEmpty {
                    return "Searching for NAS Relay on the local network…\n\(message)"
                }
                return "Searching for NAS Relay on the local network…"
            }
            return nil
        case .connected:
            return [
                relayActiveURLSummary,
                relayAPNsStatusSummary,
                relaySonosDiscoverySummary
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case .unreachable(let reason):
            return reason
        }
    }

    private var relayActiveURLSummary: String? {
        guard let active = relay.activeURLString else { return nil }
        return relay.isUsingDiscoveredURL
            ? "Auto-discovered \(active)"
            : "Manual URL \(active)"
    }

    private var relayAPNsStatusSummary: String? {
        guard let apns = relay.relayAPNs else { return nil }
        let environment = switch apns.environment {
        case .production: "Production"
        case .sandbox: "Sandbox"
        case .unknown: "Unknown environment"
        }

        switch apns.mode {
        case .ready:
            return "APNs ready · \(environment)"
        case .dryRun:
            let missing = apns.missing.isEmpty ? "configuration missing" : apns.missing.joined(separator: ", ")
            return "APNs dry-run · \(missing)"
        case .unknown:
            return "APNs status unknown · \(environment)"
        }
    }

    private var relaySonosDiscoverySummary: String? {
        guard let sonos = relay.relaySonos else { return nil }
        let mode = switch sonos.discoveryMode {
        case .auto: "Auto Sonos discovery"
        case .seed: "Seed IP Sonos discovery"
        case .unknown: "Sonos discovery"
        }
        let status = switch sonos.discoveryStatus {
        case .idle: "idle"
        case .starting: "starting"
        case .ready: "ready"
        case .failed: "failed"
        case .unknown: "unknown"
        }
        if let error = sonos.discoveryError, !error.isEmpty {
            return "\(mode) · \(status) · \(error)"
        }
        return "\(mode) · \(status)"
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersionString)
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}

private struct SettingsDetailMiniPlayerContentInset: ViewModifier {
    @Bindable var manager: SonosManager
    @State private var isKeyboardVisible = false

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: SettingsDetailFormLayout.bottomContentInset(
                    isMiniPlayerVisible: manager.isConfigured
                        && !manager.showFullPlayer
                        && !isKeyboardVisible,
                    usesSystemAccessory: true
                ))
                .allowsHitTesting(false)
                .onReceive(NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillShowNotification)) { _ in
                    isKeyboardVisible = true
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillHideNotification)) { _ in
                    isKeyboardVisible = false
                }
        }
    }
}

private extension View {
    @ViewBuilder
    func settingsDetailMiniPlayerContentInset(manager: SonosManager) -> some View {
        if #available(iOS 26.0, *) {
            modifier(SettingsDetailMiniPlayerContentInset(manager: manager))
        } else {
            self
        }
    }
}

private extension HueAmbienceTarget {
    var stableKey: String {
        switch self {
        case .entertainmentArea(let id):
            return "entertainmentArea:\(id)"
        case .room(let id):
            return "room:\(id)"
        case .zone(let id):
            return "zone:\(id)"
        case .light(let id):
            return "light:\(id)"
        }
    }
}

private struct HueLightingRelayStatusRow: View {
    let row: HueAmbienceStatusChip

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(row.tone.color)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
                .overlay(alignment: .top) {
                    if row.tone == .working {
                        Circle()
                            .stroke(row.tone.color.opacity(0.55), lineWidth: 1)
                            .frame(width: 16, height: 16)
                            .padding(.top, 2)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title): \(row.value)")
    }
}

private struct SettingsHubDestinationRow: View {
    let destination: SettingsHubDestination
    let status: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: destination.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(destination.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(destination.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Add Speaker Sheet (shared)

/// Sheet used by both the first-run setup screen and the new Settings tab
/// for adding a speaker by IP. Owns its own text field state so either call
/// site can present it without coordinating.
struct AddSpeakerSheet: View {
    @Bindable var manager: SonosManager
    @State private var newSpeakerIP = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Speaker IP Address", text: $newSpeakerIP)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)

                Button {
                    Task {
                        await manager.addSpeaker(ip: newSpeakerIP)
                        if manager.errorMessage == nil {
                            newSpeakerIP = ""
                            dismiss()
                        }
                    }
                } label: {
                    if manager.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newSpeakerIP.isEmpty || manager.isLoading)

                if let error = manager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Add Speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
