import SwiftUI
struct HueLightSelectionSheet: View {
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
