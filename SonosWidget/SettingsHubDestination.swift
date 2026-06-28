enum SettingsHubDestination: String, CaseIterable, Hashable, Identifiable {
    case sonos
    case externalConnection
    case hueAmbience
    case diagnostics

    static let primary: [SettingsHubDestination] = [
        .sonos,
        .externalConnection,
        .hueAmbience,
        .diagnostics,
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .sonos:
            return "Sonos"
        case .externalConnection:
            return "External Connection"
        case .hueAmbience:
            return "Hue Ambience"
        case .diagnostics:
            return "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .sonos:
            return "Account, speakers, and music services"
        case .externalConnection:
            return "Hue Bridge and Live Activity Relay"
        case .hueAmbience:
            return "Music lighting"
        case .diagnostics:
            return "Logs and troubleshooting"
        }
    }

    var systemImage: String {
        switch self {
        case .sonos:
            return "hifispeaker.2.fill"
        case .externalConnection:
            return "externaldrive.connected.to.line.below"
        case .hueAmbience:
            return "sparkles"
        case .diagnostics:
            return "doc.text.magnifyingglass"
        }
    }
}
