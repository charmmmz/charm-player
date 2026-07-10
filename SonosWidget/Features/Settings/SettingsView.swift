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

    static func connectionRow(_ status: RelayManager.Status) -> HueAmbienceStatusChip {
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
    static func lightingSetupRow(
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

    @State var isConnectingSonos = false
    /// Bound to the Live Activity Relay TextField. We only push edits into
    /// `RelayManager` on submit / blur — typing per-character would otherwise
    /// fire a probe with every keystroke.
    @State var relayURLDraft: String = RelayManager.shared.urlString

    /// Re-read the singleton through @Bindable so SwiftUI subscribes to its
    /// observable changes and re-renders the status row.
    @Bindable var relay = RelayManager.shared

    @FocusState var focusedInputField: SettingsInputField?
    @Bindable var auth = SonosAuth.shared
    @Bindable var hueStore = HueAmbienceStore.shared
    @Bindable var musicAmbience = MusicAmbienceManager.shared
    @State var musicAmbienceSetupPresentation = MusicAmbienceSetupPresentationState()
    @State var settingsPath: [SettingsHubDestination] = []
    @State var liveActivityStyle: LiveActivityStyle = SharedStorage.liveActivityStyle
    @State var lastHueRelayAutoSyncKey: String?

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

}
