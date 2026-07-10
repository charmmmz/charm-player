import SwiftUI
import UIKit

extension SettingsView {

    // MARK: - Sonos Account

    @ViewBuilder
    var sonosAccountSection: some View {
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

    var connectSonosButton: some View {
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

    func connectSonos(reconnect: Bool = false) {
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
    var speakersSection: some View {
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
    var displayedSpeakers: [SonosPlayer] {
        let pool = manager.speakers.isEmpty
            ? manager.allSpeakers.filter { $0.isCoordinator && !$0.isInvisible }
            : manager.speakers.filter { !$0.isInvisible }
        return pool.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func speakerRow(_ speaker: SonosPlayer) -> some View {
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
    var musicServicesSection: some View {
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

}
