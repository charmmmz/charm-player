import SwiftUI

struct FavoriteControlSheet: View {
    let item: BrowseItem
    @Bindable var searchManager: SearchManager
    @Bindable var manager: SonosManager

    @Environment(\.dismiss) private var dismiss
    @State private var appleState: AppleMusicFavoriteSheetState = .loading
    @State private var isChangingSonos = false
    @State private var isChangingAppleMusic = false

    private var sonosFavorited: Bool {
        searchManager.isFavorited(item)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal)
                    .padding(.bottom, 18)

                Divider()

                VStack(spacing: 0) {
                    sonosRow
                    Divider().padding(.leading, 58)
                    appleMusicRow
                }
            }
            .padding(.top, 12)
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: item.id) {
                await loadAppleMusicState()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            artwork
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: item.isArtist ? 32 : 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                if !item.artist.isEmpty {
                    Text(item.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let urlString = item.albumArtURL,
           let url = URL(string: urlString) {
            RemoteArtworkImageView(url: url, contentMode: .fill) { _ in
                artworkPlaceholder
            }
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: item.isContainer ? "music.note.list" : "music.note")
                    .foregroundStyle(.tertiary)
            }
    }

    private var sonosRow: some View {
        FavoriteControlRow(
            iconName: sonosFavorited ? "heart.fill" : "heart",
            iconTint: .red,
            title: "Sonos Favorites",
            subtitle: sonosFavorited ? "Favorited" : "Not favorited",
            isBusy: isChangingSonos,
            buttonTitle: sonosFavorited ? "Remove" : "Add",
            buttonRole: sonosFavorited ? .destructive : nil
        ) {
            Task { await toggleSonosFavorite() }
        }
    }

    @ViewBuilder
    private var appleMusicRow: some View {
        switch appleState {
        case .loading:
            FavoriteControlRow(
                iconName: "apple.logo",
                iconTint: .pink,
                title: "Apple Music Favorites",
                subtitle: "Loading",
                isBusy: true,
                buttonTitle: nil,
                buttonRole: nil,
                action: {}
            )
        case .notAvailable(let message):
            FavoriteControlRow(
                iconName: "apple.logo",
                iconTint: .pink,
                title: "Apple Music Favorites",
                subtitle: message,
                isBusy: false,
                buttonTitle: nil,
                buttonRole: nil,
                action: {}
            )
        case .failed(let message):
            FavoriteControlRow(
                iconName: "apple.logo",
                iconTint: .pink,
                title: "Apple Music Favorites",
                subtitle: message,
                isBusy: isChangingAppleMusic,
                buttonTitle: "Retry",
                buttonRole: nil
            ) {
                Task { await loadAppleMusicState() }
            }
        case .loaded(let isFavorited):
            FavoriteControlRow(
                iconName: "apple.logo",
                iconTint: .pink,
                title: "Apple Music Favorites",
                subtitle: isFavorited ? "Favorited" : "Not favorited",
                isBusy: isChangingAppleMusic,
                buttonTitle: isFavorited ? "Remove" : "Add",
                buttonRole: isFavorited ? .destructive : nil
            ) {
                Task { await toggleAppleMusicFavorite(isCurrentlyFavorited: isFavorited) }
            }
        }
    }

    private func toggleSonosFavorite() async {
        isChangingSonos = true
        defer { isChangingSonos = false }

        if sonosFavorited {
            _ = await searchManager.removeFromFavorites(item: item, manager: manager)
        } else {
            _ = await searchManager.addToFavorites(item: item, manager: manager)
        }
    }

    private func loadAppleMusicState() async {
        guard let resource = searchManager.appleMusicFavoriteResource(for: item) else {
            appleState = .notAvailable("Not available")
            return
        }

        appleState = .loading
        do {
            let isFavorited = try await searchManager.appleMusicFavoriteStatus(for: resource)
            appleState = .loaded(isFavorited)
        } catch {
            appleState = .failed(Self.errorMessage(from: error))
        }
    }

    private func addAppleMusicFavorite() async {
        guard let resource = searchManager.appleMusicFavoriteResource(for: item) else {
            appleState = .notAvailable("Not available")
            return
        }

        isChangingAppleMusic = true
        defer { isChangingAppleMusic = false }

        do {
            try await searchManager.addToAppleMusicFavorites(resource: resource)
            appleState = .loaded(true)
        } catch {
            appleState = .failed(Self.errorMessage(from: error))
        }
    }

    private func toggleAppleMusicFavorite(isCurrentlyFavorited: Bool) async {
        guard let resource = searchManager.appleMusicFavoriteResource(for: item) else {
            appleState = .notAvailable("Not available")
            return
        }

        isChangingAppleMusic = true
        defer { isChangingAppleMusic = false }

        do {
            if isCurrentlyFavorited {
                try await searchManager.removeFromAppleMusicFavorites(resource: resource)
                appleState = .loaded(false)
            } else {
                try await searchManager.addToAppleMusicFavorites(resource: resource)
                appleState = .loaded(true)
            }
        } catch {
            appleState = .failed(Self.errorMessage(from: error))
        }
    }

    private static func errorMessage(from error: Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}

private enum AppleMusicFavoriteSheetState: Equatable {
    case loading
    case loaded(Bool)
    case failed(String)
    case notAvailable(String)
}

private struct FavoriteControlRow<Accessory: View>: View {
    let iconName: String
    let iconTint: Color
    let title: String
    let subtitle: String
    let isBusy: Bool
    let buttonTitle: String?
    let buttonRole: ButtonRole?
    @ViewBuilder let accessory: () -> Accessory
    let action: () -> Void

    init(
        iconName: String,
        iconTint: Color,
        title: String,
        subtitle: String,
        isBusy: Bool,
        buttonTitle: String?,
        buttonRole: ButtonRole?,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        action: @escaping () -> Void
    ) {
        self.iconName = iconName
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.isBusy = isBusy
        self.buttonTitle = buttonTitle
        self.buttonRole = buttonRole
        self.accessory = accessory
        self.action = action
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconTint)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if let buttonTitle {
                Button(role: buttonRole, action: action) {
                    Text(buttonTitle)
                }
                .buttonStyle(.bordered)
            } else {
                accessory()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 14)
    }
}
