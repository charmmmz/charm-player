import SwiftUI
import UIKit

extension SettingsView {

    // MARK: - Section Header with Inline Refresh

    /// Form `Section` header with an inline refresh glyph on the trailing
    /// edge. Preserves SwiftUI's default header font/casing on the title while
    /// letting the button look like a small affordance next to it.
    func sectionHeader(title: String,
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

    var sortedAccounts: [SonosCloudAPI.CloudMusicServiceAccount] {
        let pinned: Set<String> = ["3079", "52231", "51463", "42247", "49671"]
        return searchManager.linkedAccounts.sorted { a, b in
            let aPinned = pinned.contains(a.serviceId ?? "")
            let bPinned = pinned.contains(b.serviceId ?? "")
            if aPinned != bPinned { return aPinned }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    func serviceRow(_ account: SonosCloudAPI.CloudMusicServiceAccount) -> some View {
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

    var liveActivityStyleBinding: Binding<LiveActivityStyle> {
        Binding {
            liveActivityStyle
        } set: { newStyle in
            guard liveActivityStyle != newStyle else { return }
            liveActivityStyle = newStyle
            manager.updateLiveActivityStyle(newStyle)
        }
    }

    @ViewBuilder
    var liveActivitySection: some View {
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
    var hueLightingRelaySection: some View {
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

    var hueLightingRelayRows: [HueAmbienceStatusChip] {
        HueLightingRelayPresentation.statusRows(
            relayStatus: relay.status,
            syncStatus: relay.hueAmbienceSyncStatus,
            hasBridge: hueStore.bridge != nil,
            assignmentCount: hueStore.mappings.count
        )
    }

    var hueRelayAutoSyncKey: String? {
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

    func autoSyncHueLightingSetupIfNeeded() async {
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
    var relayStatusRow: some View {
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

    var relayStatusIndicator: some View {
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

    var relayStatusTitle: String {
        switch relay.status {
        case .disabled:                       return "Disabled"
        case .probing:                        return "Probing…"
        case .connected(let n) where n == 1:  return "Connected · 1 group"
        case .connected(let n):               return "Connected · \(n) groups"
        case .unreachable:                    return "Unreachable"
        }
    }

    var relayStatusDetail: String? {
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

    var relayActiveURLSummary: String? {
        guard let active = relay.activeURLString else { return nil }
        return relay.isUsingDiscoveredURL
            ? "Auto-discovered \(active)"
            : "Manual URL \(active)"
    }

    var relayAPNsStatusSummary: String? {
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

    var relaySonosDiscoverySummary: String? {
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
    var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersionString)
        }
    }

    var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
