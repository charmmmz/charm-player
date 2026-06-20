enum SettingsHubDestination: String, CaseIterable, Hashable, Identifiable {
    case sonos
    case hueAmbience
    case hubSetup
    case diagnostics

    static let primary: [SettingsHubDestination] = [
        .sonos,
        .hueAmbience,
        .hubSetup,
        .diagnostics,
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .sonos:
            return "Sonos"
        case .hueAmbience:
            return "Hue Ambience"
        case .hubSetup:
            return "Hub Setup"
        case .diagnostics:
            return "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .sonos:
            return "Account, speakers, and music services"
        case .hueAmbience:
            return "Music and game lighting"
        case .hubSetup:
            return "Hue Bridge, NAS Relay, and NAS Agent"
        case .diagnostics:
            return "Logs and troubleshooting"
        }
    }

    var systemImage: String {
        switch self {
        case .sonos:
            return "hifispeaker.2.fill"
        case .hueAmbience:
            return "sparkles"
        case .hubSetup:
            return "externaldrive.connected.to.line.below"
        case .diagnostics:
            return "doc.text.magnifyingglass"
        }
    }
}
