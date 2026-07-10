import SwiftUI
struct HueMappingRow: View {
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
