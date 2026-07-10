import Observation
import SwiftUI
import UIKit

struct SearchView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager
    @State var searchText = ""
    /// nil = "All", otherwise the serviceId string
    @State var selectedServiceTab: String?
    /// Tracks which item is currently being loaded for playback
    @State var playingItemId: String?
    @State var favoriteSheetItem: BrowseItem?
    @State var isReconnectingSonos = false
    @State var pullRefreshController = BrowsePullRefreshController()
    @Bindable var auth = SonosAuth.shared

    let browseScrollCoordinateSpaceName = "browse-scroll"

    var body: some View {
        NavigationStack {
            Group {
                if !manager.isConfigured {
                    ContentUnavailableView("No Speaker Connected",
                                           systemImage: "hifispeaker.slash",
                                           description: Text("Connect to a Sonos speaker in the Player tab first."))
                } else if searchText.isEmpty {
                    browseContent
                } else {
                    searchResultsContent
                }
            }
            .background {
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
                .ignoresSafeArea()
            }
            // Hide the "Search" navigation title entirely (both the large and
            // inline forms). The `.searchable` field is already self-
            // explanatory; a redundant title just costs vertical space.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .scrollContentBackground(.hidden)
            .preferredColorScheme(.dark)
            .searchable(text: $searchText, prompt: "Search songs, artists, albums…")
            .onSubmit(of: .search) {
                // Preserve the currently-selected service tab across searches
                // so the user doesn't get yanked back to "All" every time they
                // retype a query. The onChange(lastSearchQuery) below takes
                // care of re-fetching the tab's results for the new query.
                searchManager.search(query: searchText)
            }
            .onChange(of: searchManager.lastSearchQuery) { _, _ in
                // search() clears serviceDetailResults before fetching; if
                // a service tab is selected we proactively repopulate it so
                // switching back doesn't require a second tap.
                if let sid = selectedServiceTab {
                    Task { await searchManager.loadServiceDetail(serviceId: sid) }
                }
            }
            .onAppear {
                searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
                Task {
                    async let browse: () = loadBrowseForCurrentBackend()
                    async let probe: () = searchManager.probeLinkedServices()
                    _ = await (browse, probe)
                }
            }
            .onChange(of: manager.selectedSpeaker?.ipAddress) { _, _ in
                searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
                searchManager.resetProbe()
                Task { await loadBrowseForCurrentBackend(forceRefresh: true) }
            }
            .onChange(of: manager.transportBackend) { _, _ in
                // Flipping between LAN and Cloud changes where Sonos Favorites
                // come from. Re-load so the list matches the active backend.
                Task { await loadBrowseForCurrentBackend(forceRefresh: true) }
            }
            .onChange(of: manager.currentCloudGroupId) { _, gid in
                // Cloud group id resolves asynchronously after the backend
                // flips to .cloud — if the Browse tab was already on screen,
                // the initial `loadBrowseForCurrentBackend()` call took the
                // LAN fallback with an empty IP and silently left the page
                // blank. Re-fire as soon as the id is ready.
                if gid != nil { Task { await loadBrowseForCurrentBackend(forceRefresh: true) } }
            }
            .confirmationDialog("Start Station",
                                isPresented: $searchManager.showStationPicker,
                                titleVisibility: .visible) {
                ForEach(searchManager.stationOptions) { option in
                    Button(option.name) {
                        guard let mgr = searchManager.pendingStationManager else { return }
                        Task { await searchManager.playStationOption(option, manager: mgr) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $favoriteSheetItem) { item in
                FavoriteControlSheet(item: item, searchManager: searchManager, manager: manager)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    func playItem(_ item: BrowseItem) {
        guard playingItemId == nil else { return }
        playingItemId = item.id
        Task {
            await searchManager.playNow(item: item, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    var sonosCloudErrorContent: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Sonos Cloud",
                systemImage: "exclamationmark.triangle",
                description: Text(searchManager.errorMessage ?? "")
            )
            if auth.sessionState == .expired || auth.sessionState == .disconnected {
                Button {
                    reconnectSonos()
                } label: {
                    HStack(spacing: 8) {
                        if isReconnectingSonos {
                            ProgressView().controlSize(.small)
                        }
                        Text(isReconnectingSonos ? "Reconnecting..." : sonosCloudConnectTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isReconnectingSonos)
            }
        }
        .padding(.horizontal)
    }

    var sonosCloudConnectTitle: String {
        auth.sessionState == .expired ? "Reconnect" : "Connect"
    }

    func reconnectSonos() {
        isReconnectingSonos = true
        Task {
            let window = await UIApplication.shared.sonosPresentationWindow
            let success = await auth.reconnect(from: window)
            if success {
                searchManager.errorMessage = nil
                await manager.resolveCloudGroupId()
                await manager.refreshState()
                await searchManager.forceReprobe()
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await loadBrowseForCurrentBackend(forceRefresh: true)
                } else {
                    searchManager.search(query: searchText)
                }
            } else if let authError = auth.lastErrorMessage {
                searchManager.errorMessage = authError
            }
            isReconnectingSonos = false
        }
    }

    /// Dispatches Browse-tab content loading based on whether we're LAN or
    /// remote. In remote mode we hand SearchManager a cloud context so it can
    /// source Sonos Favorites from the Control API's `listFavorites` endpoint.
    ///
    /// Important: never fall through to the LAN path while we're in cloud
    /// mode — `SonosAPI.browseFavorites(ip: "")` would just time out and
    /// leave the page blank. When cloud prerequisites (token, household id,
    /// group id) aren't ready yet, we bail and rely on the `onChange`
    /// handlers above to re-fire once they resolve.
    func loadBrowseForCurrentBackend(forceRefresh: Bool = false) async {
        switch manager.transportBackend {
        case .cloud:
            guard let token = await SonosAuth.shared.validAccessToken(),
                  let householdId = SonosAuth.shared.householdId else {
                searchManager.errorMessage = SonosCloudError.unauthorized.localizedDescription
                return
            }
            // Group id usually resolves shortly after the backend flips —
            // kick a resolve if we don't have it yet so the Browse tab
            // doesn't sit empty waiting for the next poll.
            if manager.currentCloudGroupId == nil {
                await manager.resolveCloudGroupId()
            }
            guard let gid = manager.currentCloudGroupId else { return }
            await searchManager.loadBrowseContent(
                cloudMode: true,
                cloudContext: .init(token: token, householdId: householdId, groupId: gid),
                forceRefresh: forceRefresh)
        case .lan:
            await searchManager.loadBrowseContent(forceRefresh: forceRefresh)
        case .unknown:
            // Backend probe hasn't finished yet — `onChange(transportBackend)`
            // re-triggers this func once it flips to .lan or .cloud.
            return
        }
    }

    func startStationForItem(_ item: BrowseItem) {
        guard playingItemId == nil else { return }
        playingItemId = item.id
        Task {
            await searchManager.startStation(item: item, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    func handleFavoriteAction(_ item: BrowseItem) {
        if searchManager.appleMusicFavoriteResource(for: item) != nil {
            favoriteSheetItem = item
            return
        }

        Task { await toggleSonosFavorite(item) }
    }

    func toggleSonosFavorite(_ item: BrowseItem) async {
        if searchManager.isFavorited(item) {
            _ = await searchManager.removeFromFavorites(item: item, manager: manager)
        } else {
            _ = await searchManager.addToFavorites(item: item, manager: manager)
        }
    }

    func toggleAppleMusicFavorite(_ item: BrowseItem) async {
        _ = await searchManager.toggleAppleMusicFavorites(for: item)
    }

}
