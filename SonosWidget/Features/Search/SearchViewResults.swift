import Observation
import SwiftUI
import UIKit

extension SearchView {

    // MARK: - Search Results (Tabbed)

    var searchResultsContent: some View {
        Group {
            if searchManager.isSearching && searchManager.searchResults.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("Searching…")
                    Spacer()
                }
            } else if searchManager.errorMessage?.isEmpty == false {
                sonosCloudErrorContent
            } else if searchManager.hasSearched && searchManager.searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if searchManager.searchResults.isEmpty {
                Color.clear
            } else {
                VStack(spacing: 0) {
                    serviceTabBar
                    Divider().opacity(0.3)
                    ScrollView {
                        groupedResultsForSelectedTab
                            .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.immediately)
                }
            }
        }
    }

    // MARK: Service Tab Bar

    var serviceTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                serviceTabChip(id: nil, label: "All")
                ForEach(searchManager.searchResults) { group in
                    serviceTabChip(id: group.id, label: group.serviceName)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    func serviceTabChip(id: String?, label: String) -> some View {
        let isSelected = selectedServiceTab == id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedServiceTab = id }
            if let id { Task { await searchManager.loadServiceDetail(serviceId: id) } }
        } label: {
            HStack(spacing: 6) {
                if let id {
                    CloudServiceBrandMark(
                        cloudServiceId: id,
                        displayNameHint: label,
                        dimension: 14,
                        symbolUsesTitle3: false,
                        lightChromeBackdrop: isSelected
                    )
                }
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white : Color.white.opacity(0.1))
            .foregroundStyle(isSelected ? .black : .white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Grouped Results

    enum ResultCategory: String, CaseIterable {
        case artist = "Artists"
        case track = "Songs"
        case album = "Albums"
        case playlist = "Playlists"
        case program = "Stations"
    }

    func categoryFor(_ item: BrowseItem) -> ResultCategory {
        switch item.cloudType {
        case "ARTIST": return .artist
        case "TRACK": return .track
        case "ALBUM": return .album
        case "PLAYLIST": return .playlist
        case "PROGRAM": return .program
        default: return .track
        }
    }

    /// Items for the currently selected tab, grouped by type.
    var groupedResultsForSelectedTab: some View {
        let items: [BrowseItem] = {
            if let sid = selectedServiceTab {
                if let detail = searchManager.serviceDetailResults[sid] {
                    return detail.items
                }
                return searchManager.searchResults.first { $0.id == sid }?.items ?? []
            }
            return searchManager.searchResults.flatMap { $0.items }
        }()

        let grouped = Dictionary(grouping: items) { categoryFor($0) }

        return VStack(alignment: .leading, spacing: 24) {
            if selectedServiceTab == nil && searchManager.searchResults.count > 1 {
                ForEach(searchManager.searchResults) { group in
                    allTabServiceSection(group)
                }
            } else if let sid = selectedServiceTab, searchManager.isLoadingServiceDetail,
                      searchManager.serviceDetailResults[sid] == nil {
                HStack {
                    Spacer()
                    ProgressView("Loading full results…")
                    Spacer()
                }
                .padding(.top, 40)
            } else {
                ForEach(ResultCategory.allCases, id: \.self) { category in
                    if let categoryItems = grouped[category], !categoryItems.isEmpty {
                        resultCategorySection(category: category, items: categoryItems)
                    }
                }
            }
        }
    }

    /// "All" tab: a section for each service with a header, showing grouped results inside.
    @ViewBuilder
    func allTabServiceSection(_ group: SearchManager.ServiceSearchResult) -> some View {
        let grouped = Dictionary(grouping: group.items) { categoryFor($0) }

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                CloudServiceBrandMark(
                    cloudServiceId: group.id,
                    displayNameHint: group.serviceName,
                    dimension: 26,
                    symbolUsesTitle3: true
                )
                    .foregroundStyle(.secondary)
                Text(group.serviceName)
                    .font(.title2.bold())
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { selectedServiceTab = group.id }
                Task { await searchManager.loadServiceDetail(serviceId: group.id) }
            }

            ForEach(ResultCategory.allCases, id: \.self) { category in
                if let categoryItems = grouped[category], !categoryItems.isEmpty {
                    resultCategorySection(category: category,
                                          items: Array(categoryItems.prefix(category == .artist ? 10 : 5)))
                }
            }
        }
    }

    @ViewBuilder
    func resultCategorySection(category: ResultCategory, items: [BrowseItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(category.rawValue)
                .font(.title3.bold())
                .padding(.horizontal)

            switch category {
            case .artist:
                artistHorizontalScroll(items: items)
            case .track, .program:
                songList(items: items)
            case .album, .playlist:
                albumHorizontalScroll(items: items)
            }
        }
    }

    // MARK: Artist Horizontal Scroll (circular images)

    func artistHorizontalScroll(items: [BrowseItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(items) { item in
                    NavigationLink {
                        ArtistDetailView(artistItem: item,
                                         searchManager: searchManager,
                                         manager: manager)
                    } label: {
                        VStack(spacing: 8) {
                            AsyncImage(url: URL(string: item.thumbnailArtworkURL ?? "")) { phase in
                                if let img = phase.image {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Circle().fill(.quaternary)
                                        .overlay {
                                            Image(systemName: "person.fill")
                                                .foregroundStyle(.tertiary)
                                        }
                                }
                            }
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())

                            Text(item.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 120)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        logBrowseNavigation(surface: "ArtistHorizontalScroll", kind: "artist", item: item, nav: item)
                    })
                    .contextMenu { itemContextMenu(item) }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Song List (rows)

    func songList(items: [BrowseItem]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                let isLoading = playingItemId == item.id
                let isDisabled = playingItemId != nil && !isLoading

                Button {
                    playItem(item)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            AsyncImage(url: URL(string: item.thumbnailArtworkURL ?? "")) { phase in
                                if let img = phase.image {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(.quaternary)
                                        .overlay {
                                            Image(systemName: item.cloudType == "PROGRAM"
                                                  ? "antenna.radiowaves.left.and.right"
                                                  : "music.note")
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            if isLoading {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.ultraThinMaterial.opacity(0.85))
                                    .frame(width: 48, height: 48)
                                    .overlay {
                                        ProgressView()
                                            .tint(.white)
                                            .controlSize(.small)
                                    }
                                    .transition(.opacity)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                if item.cloudType == "PROGRAM" {
                                    Text("Station")
                                } else {
                                    if !item.artist.isEmpty { Text(item.artist) }
                                    if !item.album.isEmpty { Text("· \(item.album)") }
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }

                        Spacer()

                        if isLoading {
                            ProgressView()
                                .tint(.secondary)
                                .controlSize(.small)
                        } else {
                            // Tap the ellipsis to open the same action list
                            // a long-press already shows — Play Next / Add to
                            // Queue / Add to Sonos Favorites, etc. Wrapped in
                            // a Menu so tap + long-press both work without
                            // hijacking the outer Button's tap-to-play.
                            Menu {
                                itemContextMenu(item)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .opacity(isDisabled ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .animation(.easeInOut(duration: 0.2), value: playingItemId)
                .contextMenu { itemContextMenu(item) }
            }
        }
    }

    // MARK: Album / Playlist Horizontal Scroll

    func albumHorizontalScroll(items: [BrowseItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(items) { item in
                    if item.cloudType == "ALBUM" {
                        NavigationLink {
                            AlbumDetailView(albumItem: item,
                                            searchManager: searchManager,
                                            manager: manager)
                        } label: {
                            albumScrollCard(item)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            logBrowseNavigation(surface: "AlbumHorizontalScroll", kind: "album", item: item, nav: item)
                        })
                        .contextMenu { itemContextMenu(item) }
                    } else if item.cloudType == "PLAYLIST" {
                        NavigationLink {
                            PlaylistDetailView(playlistItem: item,
                                               searchManager: searchManager,
                                               manager: manager)
                        } label: {
                            albumScrollCard(item)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            logBrowseNavigation(surface: "AlbumHorizontalScroll", kind: "playlist", item: item, nav: item)
                        })
                        .contextMenu { itemContextMenu(item) }
                    } else {
                        let isLoading = playingItemId == item.id
                        let isDisabled = playingItemId != nil && !isLoading

                        Button { playItem(item) } label: {
                            albumScrollCard(item)
                                .opacity(isDisabled ? 0.4 : 1)
                                .overlay {
                                    if isLoading {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(.ultraThinMaterial.opacity(0.85))
                                            .frame(width: 140, height: 140)
                                            .overlay {
                                                ProgressView()
                                                    .tint(.white)
                                                    .controlSize(.regular)
                                            }
                                            .transition(.opacity)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDisabled)
                        .animation(.easeInOut(duration: 0.2), value: playingItemId)
                        .contextMenu { itemContextMenu(item) }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    func albumScrollCard(_ item: BrowseItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: item.thumbnailArtworkURL ?? "")) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: item.cloudType == "PLAYLIST"
                                  ? "music.note.list" : "opticaldisc")
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(item.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            if !item.artist.isEmpty {
                Text(item.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 140)
    }

}
