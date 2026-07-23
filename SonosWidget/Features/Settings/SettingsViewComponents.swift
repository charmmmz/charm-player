import SwiftUI
import UIKit
struct SettingsDetailMiniPlayerContentInset: ViewModifier {
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

extension View {
    @ViewBuilder
    func settingsDetailMiniPlayerContentInset(manager: SonosManager) -> some View {
        if #available(iOS 26.0, *) {
            modifier(SettingsDetailMiniPlayerContentInset(manager: manager))
        } else {
            self
        }
    }
}

extension HueAmbienceTarget {
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

struct HueLightingRelayStatusRow: View {
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

struct SettingsHubDestinationRow: View {
    let destination: SettingsHubDestination
    let status: String?

    var body: some View {
        HStack(spacing: 12) {
            SettingsHubDestinationMark(destination: destination)

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

private struct SettingsHubDestinationMark: View {
    let destination: SettingsHubDestination

    var body: some View {
        Group {
            switch destination {
            case .sonos:
                Image("SonosWordmark")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 1)
            case .hueAmbience:
                Image("HueWordmark")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.primary)
            case .externalConnection, .diagnostics:
                Image(systemName: destination.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: 42, height: 28)
        .accessibilityHidden(true)
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
