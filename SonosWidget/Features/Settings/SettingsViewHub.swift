import SwiftUI
import UIKit

extension SettingsView {

    // MARK: - Settings Hub

    var settingsHubSection: some View {
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
    func settingsDestinationView(for destination: SettingsHubDestination) -> some View {
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

    func settingsDetailForm<Content: View>(
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

    func settingsHubStatus(for destination: SettingsHubDestination) -> String? {
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

    var sonosAccountStatusSummary: String {
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

    var speakersStatusSummary: String {
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

    var hueAmbienceHubStatusSummary: String {
        guard let bridge = hueStore.bridge else {
            return "Bridge not paired · Lighting \(hueAmbienceLightingStatusValue)"
        }

        let assignmentCount = hueStore.mappings.count
        let assignments = assignmentCount == 1 ? "1 assignment" : "\(assignmentCount) assignments"
        return "Lighting \(hueAmbienceLightingStatusValue) · \(bridge.name) · \(assignments)"
    }

    var hueAmbienceLightingStatusValue: String {
        HueAmbienceStatusPresentation.lightingStatusValue(
            musicAmbience.status,
            relayActiveGroups: relay.hueAmbienceActiveGroups
        )
    }

    var musicAmbienceSetupBinding: Binding<Bool> {
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

    var inputDrafts: SettingsInputDrafts {
        SettingsInputDrafts(
            relayURL: relayURLDraft
        )
    }

    func finishEditingFocusedInput() {
        finishEditingInput(focusedInputField)
    }

    func finishEditingInput(_ field: SettingsInputField?) {
        focusedInputField = inputDrafts.commit(
            focusedField: field,
            relayURL: { relay.setURL($0) }
        )
    }

    // MARK: - Background

    var backgroundLayer: some View {
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

}
