enum SettingsInputField: Hashable {
    case relayURL
}

struct SettingsInputDrafts {
    var relayURL: String

    func commit(
        focusedField: SettingsInputField?,
        relayURL saveRelayURL: (String) -> Void
    ) -> SettingsInputField? {
        switch focusedField {
        case .relayURL:
            saveRelayURL(relayURL)
        case nil:
            break
        }

        return nil
    }
}
