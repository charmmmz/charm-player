import XCTest
import Network
@testable import SonosWidget

final class LocalServiceInteractionTests: XCTestCase {
    private let sidMappingKey = "CloudLocalSidMapping"
    private static var sharedProbeServer: LocalServiceProbeServer?

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: sidMappingKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: sidMappingKey)
        super.tearDown()
    }

    func testAlbumDetailActionsKeepAppleMusicLinkOnArtwork() {
        XCTAssertEqual(
            LocalMusicDetailActions.album(hasAppleMusicURL: true),
            [.play, .shuffle, .favorite])
    }

    func testAlbumDetailActionsOmitAppleMusicLinkWhenUnavailable() {
        XCTAssertEqual(
            LocalMusicDetailActions.album(hasAppleMusicURL: false),
            [.play, .shuffle, .favorite])
    }

    func testArtistDetailActionsKeepAppleMusicLinkOnArtwork() {
        XCTAssertEqual(
            LocalMusicDetailActions.artist(hasAppleMusicURL: true),
            [.playStation])
    }

    func testArtistDetailActionsOmitAppleMusicLinkWhenUnavailable() {
        XCTAssertEqual(
            LocalMusicDetailActions.artist(hasAppleMusicURL: false),
            [.playStation])
    }

    func testPlaylistDetailActionsKeepAppleMusicLinkOnArtwork() {
        XCTAssertEqual(
            LocalMusicDetailActions.playlist(hasAppleMusicURL: true),
            [.play, .shuffle])
    }

    func testAppleMusicURLFallsBackToAlbumCatalogID() {
        let playable = LocalServiceAppleMusicPlayable(
            kind: .album,
            catalogID: "album:1440864059",
            title: "Blonde",
            artist: "Frank Ocean",
            album: "Blonde",
            artworkURLString: nil,
            duration: nil)

        XCTAssertEqual(
            LocalMusicAppleMusicURL.url(
                existingURL: nil,
                playable: playable,
                kind: .album)?.absoluteString,
            "https://music.apple.com/us/album/blonde/1440864059")
    }

    func testAppleMusicURLRejectsLibraryAlbumIDFallback() {
        let playable = LocalServiceAppleMusicPlayable(
            kind: .album,
            catalogID: "album:l.library-album-id",
            title: "Blonde",
            artist: "Frank Ocean",
            album: "Blonde",
            artworkURLString: nil,
            duration: nil)

        XCTAssertNil(
            LocalMusicAppleMusicURL.url(
                existingURL: nil,
                playable: playable,
                kind: .album))
    }

    func testAppleMusicURLRejectsLibraryArtistIDFallback() {
        let playable = LocalServiceAppleMusicPlayable(
            kind: .artist,
            catalogID: "artist:r.library-artist-id",
            title: "Frank Ocean",
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil)

        XCTAssertNil(
            LocalMusicAppleMusicURL.url(
                existingURL: nil,
                playable: playable,
                kind: .artist))
    }

    func testAppleMusicURLPrefersExistingURL() {
        let existingURL = URL(string: "https://music.apple.com/us/album/existing/1")!

        XCTAssertEqual(
            LocalMusicAppleMusicURL.url(
                existingURL: existingURL,
                playable: nil,
                kind: .album),
            existingURL)
    }

    func testAppleMusicURLIgnoresUnsupportedExistingURL() {
        let existingURL = URL(string: "https://music.apple.com/us/library/albums/l.library-album-id")!

        XCTAssertNil(
            LocalMusicAppleMusicURL.url(
                existingURL: existingURL,
                playable: nil,
                kind: .album))
    }

    func testExternalAppleMusicURLCanRequireCatalogURL() {
        let existingURL = URL(string: "https://music.apple.com/us/album/existing/1")!
        let catalogURL = URL(string: "https://music.apple.com/us/album/catalog/2")!

        XCTAssertNil(
            LocalMusicAppleMusicURL.externalURL(
                existingURL: existingURL,
                catalogURL: nil,
                kind: .album,
                requiresCatalogURL: true))
        XCTAssertEqual(
            LocalMusicAppleMusicURL.externalURL(
                existingURL: existingURL,
                catalogURL: catalogURL,
                kind: .album,
                requiresCatalogURL: true),
            catalogURL)
    }

    func testArtistPrimaryActionNavigatesToDetails() {
        XCTAssertEqual(
            LocalServiceLibraryInteraction.primaryAction(for: .artist),
            .navigate)
    }

    func testSongAndStationPrimaryActionsStillPlay() {
        XCTAssertEqual(
            LocalServiceLibraryInteraction.primaryAction(for: .song),
            .play)
        XCTAssertEqual(
            LocalServiceLibraryInteraction.primaryAction(for: .station),
            .play)
    }

    func testCatalogSearchContainersNavigateAndSongsStillPlay() {
        XCTAssertEqual(
            LocalServiceCatalogSearchInteraction.primaryAction(for: .song),
            .play)
        XCTAssertEqual(
            LocalServiceCatalogSearchInteraction.primaryAction(for: .album),
            .navigate)
        XCTAssertEqual(
            LocalServiceCatalogSearchInteraction.primaryAction(for: .artist),
            .navigate)
        XCTAssertEqual(
            LocalServiceCatalogSearchInteraction.primaryAction(for: .playlist),
            .navigate)
    }

    func testSearchScopesExposeLibraryAndAppleMusicTitles() {
        XCTAssertEqual(LocalServiceSearchScope.allCases, [.library, .appleMusic])
        XCTAssertEqual(LocalServiceSearchScope.library.title, "Library")
        XCTAssertEqual(LocalServiceSearchScope.appleMusic.title, "Apple Music")
    }

    func testSearchPresentationPromptsNameActiveScope() {
        XCTAssertEqual(
            LocalServiceSearchPresentation.prompt(for: .library),
            "Search Library")
        XCTAssertEqual(
            LocalServiceSearchPresentation.prompt(for: .appleMusic),
            "Search in Apple Music")
    }

    func testAppleMusicSearchCategoriesAppearOnlyAfterSubmit() {
        XCTAssertFalse(
            LocalServiceSearchPresentation.showsCatalogCategories(
                scope: .appleMusic,
                hasSubmittedSearch: false))
        XCTAssertFalse(
            LocalServiceSearchPresentation.showsCatalogCategories(
                scope: .library,
                hasSubmittedSearch: true))
        XCTAssertTrue(
            LocalServiceSearchPresentation.showsCatalogCategories(
                scope: .appleMusic,
                hasSubmittedSearch: true))
    }

    func testLibrarySearchDoesNotShowGenericSearchResultsHeading() {
        XCTAssertFalse(
            LocalServiceSearchPresentation.showsGenericSearchResultsHeading(
                scope: .library,
                hasSubmittedSearch: true))
    }

    func testAppleMusicSearchCategoryOrderMatchesAppleMusicTabs() {
        XCTAssertEqual(
            LocalServiceSearchPresentation.catalogCategoryOrder,
            [.artists, .albums, .songs, .playlists])
    }

    func testPlaybackFallbackPolicyBlocksCatalogFallbackAfterPrimaryPlaylistAttempt() {
        XCTAssertFalse(
            LocalServicePlaybackFallbackPolicy.shouldAttemptCatalogFallback(
                primaryKind: .playlist,
                fallbackKind: .playlist))
    }

    func testPlaybackFallbackPolicyAllowsSongFallbackAfterPrimarySongAttempt() {
        XCTAssertTrue(
            LocalServicePlaybackFallbackPolicy.shouldAttemptCatalogFallback(
                primaryKind: .song,
                fallbackKind: .song))
    }

    func testPlaybackFallbackPolicyAllowsFallbackWhenNoPrimaryPlayableExists() {
        XCTAssertTrue(
            LocalServicePlaybackFallbackPolicy.shouldAttemptCatalogFallback(
                primaryKind: nil,
                fallbackKind: .playlist))
    }

    func testReplaceQueueBackgroundFillCancellationPolicyCancelsBeforeLocalForegroundPlayback() {
        XCTAssertTrue(
            ReplaceQueueBackgroundFillCancellationPolicy.shouldCancelBeforeForegroundPlayback(
                transport: .localUPnP))
    }

    func testReplaceQueueBackgroundFillCancellationPolicyKeepsCloudPlaybackUntouched() {
        XCTAssertFalse(
            ReplaceQueueBackgroundFillCancellationPolicy.shouldCancelBeforeForegroundPlayback(
                transport: .cloud))
    }

    func testSearchContextLabelEmphasizesScope() {
        XCTAssertEqual(
            LocalServiceSearchPresentation.contextLabel(
                for: "  daniel  ",
                scope: .appleMusic),
            "daniel in Apple Music")
        XCTAssertEqual(
            LocalServiceSearchPresentation.contextLabel(
                for: "  daniel  ",
                scope: .library),
            "daniel in Library")
    }

    func testSubmittedSearchFieldDisplaySplitsTermFromScopeHint() {
        XCTAssertEqual(
            LocalServiceSearchPresentation.submittedFieldDisplay(
                for: "  Daniel  ",
                scope: .appleMusic),
            LocalServiceSubmittedSearchFieldDisplay(
                term: "Daniel",
                scopeHint: " in Apple Music")
        )
        XCTAssertEqual(
            LocalServiceSearchPresentation.submittedFieldDisplay(
                for: "  Daniel  ",
                scope: .library),
            LocalServiceSubmittedSearchFieldDisplay(
                term: "Daniel",
                scopeHint: " in Library")
        )
    }

    func testCatalogSearchResultsGroupByLibraryCategoryOrder() {
        let results = LocalServiceCatalogSearchResults(items: [
            AppleMusicCatalogSearchItem(
                id: "song-1",
                type: .song,
                title: "Song",
                artist: "Artist",
                album: "Album",
                artworkURLString: nil,
                duration: nil),
            AppleMusicCatalogSearchItem(
                id: "album-1",
                type: .album,
                title: "Album",
                artist: "Artist",
                album: "Album",
                artworkURLString: nil,
                duration: nil),
            AppleMusicCatalogSearchItem(
                id: "artist-1",
                type: .artist,
                title: "Artist",
                artist: "",
                album: "",
                artworkURLString: nil,
                duration: nil),
            AppleMusicCatalogSearchItem(
                id: "playlist-1",
                type: .playlist,
                title: "Playlist",
                artist: "Apple Music",
                album: "",
                artworkURLString: nil,
                duration: nil)
        ])

        XCTAssertEqual(results.count(for: .playlists), 1)
        XCTAssertEqual(results.count(for: .artists), 1)
        XCTAssertEqual(results.count(for: .albums), 1)
        XCTAssertEqual(results.count(for: .songs), 1)
        XCTAssertEqual(results.visibleCategories, [.playlists, .artists, .albums, .songs])
    }

    func testCatalogSearchRowTextDoesNotRepeatSelectedCategoryTypes() {
        let album = AppleMusicCatalogSearchItem(
            id: "album-1",
            type: .album,
            title: "In Rainbows",
            artist: "Radiohead",
            album: "In Rainbows",
            artworkURLString: nil,
            duration: nil)
        let artist = AppleMusicCatalogSearchItem(
            id: "artist-1",
            type: .artist,
            title: "Radiohead",
            artist: "",
            album: "",
            artworkURLString: nil,
            duration: nil)
        let playlist = AppleMusicCatalogSearchItem(
            id: "playlist-1",
            type: .playlist,
            title: "Imagine Dragons Essentials",
            artist: "Apple Music Alternative",
            album: "",
            artworkURLString: nil,
            duration: nil)
        let song = AppleMusicCatalogSearchItem(
            id: "song-1",
            type: .song,
            title: "15 Step",
            artist: "Radiohead",
            album: "In Rainbows",
            artworkURLString: nil,
            duration: nil)

        XCTAssertEqual(
            LocalServiceSearchPresentation.catalogRowText(for: album),
            LocalServiceCatalogRowText(subtitle: "Radiohead", detail: nil)
        )
        XCTAssertEqual(
            LocalServiceSearchPresentation.catalogRowText(for: artist),
            LocalServiceCatalogRowText(subtitle: nil, detail: nil)
        )
        XCTAssertEqual(
            LocalServiceSearchPresentation.catalogRowText(for: playlist),
            LocalServiceCatalogRowText(subtitle: "Apple Music Alternative", detail: nil)
        )
        XCTAssertEqual(
            LocalServiceSearchPresentation.catalogRowText(for: song),
            LocalServiceCatalogRowText(subtitle: "Radiohead", detail: "In Rainbows")
        )
    }

    func testArtistAlbumSummariesUseFirstSongArtworkAndStableAlbumOrder() {
        let summaries = LocalMusicArtistAlbumSummaryBuilder.summaries(from: [
            LocalMusicArtistAlbumSummaryInput(
                id: "song-3",
                title: "Third",
                artistName: "The Artist",
                albumTitle: "Beta",
                artworkURL: URL(string: "https://example.com/beta.jpg")),
            LocalMusicArtistAlbumSummaryInput(
                id: "song-1",
                title: "First",
                artistName: "The Artist",
                albumTitle: "Alpha",
                artworkURL: URL(string: "https://example.com/alpha.jpg")),
            LocalMusicArtistAlbumSummaryInput(
                id: "song-2",
                title: "Second",
                artistName: "The Artist",
                albumTitle: "Alpha",
                artworkURL: nil)
        ])

        XCTAssertEqual(summaries.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(summaries.map(\.songCount), [2, 1])
        XCTAssertEqual(summaries.first?.artworkURL?.absoluteString, "https://example.com/alpha.jpg")
    }

    func testArtistAlbumSummariesUseArtistScopedAlbumIDs() {
        let summaries = LocalMusicArtistAlbumSummaryBuilder.summaries(from: [
            LocalMusicArtistAlbumSummaryInput(
                id: "song-1",
                title: "First",
                artistName: "The Artist",
                albumTitle: "Alpha",
                artworkURL: nil)
        ])

        XCTAssertEqual(summaries.first?.id, "artist-album:The Artist:Alpha")
    }

    func testArtistAlbumArtworkLookupItemsUseAlbumSearchMetadata() {
        let summary = LocalMusicArtistAlbumSummary(
            id: "artist-album:The Artist:Alpha",
            title: "Alpha",
            artistName: "The Artist",
            artworkURL: nil,
            songCount: 2)

        let items = LocalMusicArtistAlbumSummaryBuilder.artworkLookupItems(from: [summary])

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "artist-album:The Artist:Alpha")
        XCTAssertEqual(items.first?.kind, .album)
        XCTAssertEqual(items.first?.title, "Alpha")
        XCTAssertEqual(items.first?.artist, "The Artist")
        XCTAssertEqual(items.first?.album, "Alpha")
        XCTAssertEqual(items.first?.hasMusicKitArtwork, false)
        XCTAssertNil(items.first?.directArtworkURLString)
    }

    func testPlaylistTrackArtworkLookupUsesSongSearchMetadata() {
        let item = LocalMusicPlaylistTrackArtworkLookup.lookupItem(
            title: "Miss Misery",
            artistName: "Elliott Smith",
            albumTitle: "Good Will Hunting",
            directArtworkURLString: nil)

        XCTAssertEqual(item.id, "playlist-track:elliott smith:good will hunting:miss misery")
        XCTAssertEqual(item.kind, .song)
        XCTAssertEqual(item.title, "Miss Misery")
        XCTAssertEqual(item.artist, "Elliott Smith")
        XCTAssertEqual(item.album, "Good Will Hunting")
        XCTAssertEqual(item.hasMusicKitArtwork, false)
        XCTAssertNil(item.directArtworkURLString)
    }

    func testPlaylistTrackArtworkLookupStorageIDIsCaseInsensitive() {
        let first = LocalMusicPlaylistTrackArtworkLookup.storageID(
            title: " Miss   Misery ",
            artistName: "Elliott Smith",
            albumTitle: "Good Will Hunting")
        let second = LocalMusicPlaylistTrackArtworkLookup.storageID(
            title: "miss misery",
            artistName: "elliott smith",
            albumTitle: "good will hunting")

        XCTAssertEqual(first, second)
    }

    func testPlaylistTrackArtworkSelectionPrefersCatalogArtworkOverPlaylistCover() {
        let catalogURL = URL(string: "https://example.com/catalog-track.jpg")!
        let playlistURL = URL(string: "https://example.com/playlist.jpg")!

        XCTAssertEqual(
            LocalMusicPlaylistTrackArtworkLookup.selectedArtworkURL(
                trackArtworkURL: nil,
                catalogArtworkURL: catalogURL,
                playlistArtworkURL: playlistURL),
            catalogURL
        )
    }

    func testPlaylistTrackArtworkSelectionIgnoresUnviewableTrackArtwork() {
        let trackURL = URL(string: "musicKit://artwork/library/item/120x120")!
        let catalogURL = URL(string: "https://example.com/catalog-track.jpg")!

        XCTAssertEqual(
            LocalMusicPlaylistTrackArtworkLookup.selectedArtworkURL(
                trackArtworkURL: trackURL,
                catalogArtworkURL: catalogURL,
                playlistArtworkURL: nil),
            catalogURL
        )
    }

    func testPlaylistTrackArtworkSelectionExtractsLoadableArtworkFromMusicKitLibraryURL() {
        let trackURL = URL(
            string: "musicKit://artwork/library/ABC/120x120?aat=https%3A%2F%2Fis1-ssl.mzstatic.com%2Fimage%2Fthumb%2FMusic125%2Fv4%2Fcover%2F600x600bb.jpg&at=item&id=1054366"
        )!

        XCTAssertEqual(
            LocalMusicPlaylistTrackArtworkLookup.selectedArtworkURL(
                trackArtworkURL: trackURL,
                catalogArtworkURL: nil,
                playlistArtworkURL: nil
            )?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/cover/120x120bb.jpg"
        )
    }

    func testPlaylistTrackArtworkSelectionDoesNotUsePlaylistCoverAsRowFallback() {
        let playlistURL = URL(string: "https://example.com/playlist.jpg")!

        XCTAssertNil(
            LocalMusicPlaylistTrackArtworkLookup.selectedArtworkURL(
                trackArtworkURL: nil,
                catalogArtworkURL: nil,
                playlistArtworkURL: playlistURL)
        )
    }

    func testPlaylistTrackRowsExposeVisibleMenuButtonWhenMenuActionsAreAvailable() {
        XCTAssertTrue(
            LocalMusicTrackRowMenuPolicy.showsVisibleMenuButton(
                leadingPolicy: .playlistTrack,
                isPlaying: false,
                contextMenuActions: [.playNow, .playNext, .addToQueue])
        )
    }

    func testMusicResourceActionPolicyExposesQueueActionsForQueueableSongs() {
        XCTAssertEqual(
            MusicResourceActionPolicy.actions(kind: .song, isQueueable: true),
            [.playNow, .playNext, .addToQueue]
        )
    }

    func testMusicResourceActionPolicyKeepsArtistsStationFocused() {
        XCTAssertEqual(
            MusicResourceActionPolicy.actions(kind: .artist, isQueueable: true, supportsStation: true),
            [.startStation]
        )
    }

    func testMusicResourceActionPolicyOmitsQueueActionsWhenItemCannotResolve() {
        XCTAssertEqual(
            MusicResourceActionPolicy.actions(kind: .playlist, isQueueable: false),
            [.playNow]
        )
    }

    func testPlaylistTrackArtworkSelectionPrefersTrackArtwork() {
        let trackURL = URL(string: "https://example.com/track.jpg")!
        let fallbackURL = URL(string: "https://example.com/fallback.jpg")!

        XCTAssertEqual(
            MusicResourceArtworkSelection.preferredRowArtworkURL(primary: trackURL, fallback: fallbackURL),
            trackURL
        )
    }

    func testPlaylistTrackArtworkSelectionUsesProvidedFallbackArtwork() {
        let fallbackURL = URL(string: "https://example.com/fallback.jpg")!

        XCTAssertEqual(
            MusicResourceArtworkSelection.preferredRowArtworkURL(primary: nil, fallback: fallbackURL),
            fallbackURL
        )
    }

    func testAlbumTrackLeadingPolicyNeverShowsArtwork() {
        let trackURL = URL(string: "https://example.com/track.jpg")!
        let albumURL = URL(string: "https://example.com/album.jpg")!

        XCTAssertNil(
            MusicResourceTrackLeadingPolicy.albumTrack.selectedArtworkURL(
                primaryArtworkURL: trackURL,
                fallbackArtworkURL: albumURL)
        )
    }

    func testPlaylistTrackLeadingPolicyPrefersTrackArtwork() {
        let trackURL = URL(string: "https://example.com/track.jpg")!
        let playlistURL = URL(string: "https://example.com/playlist.jpg")!

        XCTAssertEqual(
            MusicResourceTrackLeadingPolicy.playlistTrack.selectedArtworkURL(
                primaryArtworkURL: trackURL,
                fallbackArtworkURL: playlistURL),
            trackURL
        )
    }

    func testPlaylistTrackLeadingPolicyFallsBackToProvidedArtwork() {
        let fallbackURL = URL(string: "https://example.com/fallback.jpg")!

        XCTAssertEqual(
            MusicResourceTrackLeadingPolicy.playlistTrack.selectedArtworkURL(
                primaryArtworkURL: nil,
                fallbackArtworkURL: fallbackURL),
            fallbackURL
        )
    }

    func testSongLocalServicePlayableResolvesToPlayableBrowseItem() async throws {
        let searchManager = localServiceSearchManager()
        let manager = try await localServiceSonosManager()
        let playable = LocalServiceAppleMusicPlayable(
            kind: .song,
            catalogID: "song:1440857781",
            title: "Nikes",
            artist: "Frank Ocean",
            album: "Blonde",
            artworkURLString: "https://example.com/nikes.jpg",
            duration: 312)

        let item = await searchManager.resolveLocalAppleMusicBrowseItem(playable, manager: manager)

        XCTAssertEqual(item?.id, "song:1440857781")
        XCTAssertEqual(item?.title, "Nikes")
        XCTAssertEqual(item?.artist, "Frank Ocean")
        XCTAssertEqual(item?.album, "Blonde")
        XCTAssertEqual(item?.albumArtURL, "https://example.com/nikes.jpg")
        XCTAssertEqual(item?.duration, 312)
        XCTAssertFalse(item?.isContainer ?? true)
        XCTAssertEqual(item?.serviceId, 204)
        XCTAssertEqual(item?.cloudType, "TRACK")
        XCTAssertEqual(item?.uri?.isEmpty, false)
    }

    func testPlaylistLocalServicePlayableResolvesToQueueableContainerBrowseItem() async throws {
        let searchManager = localServiceSearchManager()
        let manager = try await localServiceSonosManager()
        let playable = LocalServiceAppleMusicPlayable(
            kind: .playlist,
            catalogID: "playlist:pl.abc123",
            title: "Sunday Queue",
            artist: "Charm",
            album: "",
            artworkURLString: "https://example.com/playlist.jpg",
            duration: nil)

        let item = await searchManager.resolveLocalAppleMusicBrowseItem(playable, manager: manager)

        XCTAssertEqual(item?.id, "playlist:pl.abc123")
        XCTAssertEqual(item?.title, "Sunday Queue")
        XCTAssertEqual(item?.albumArtURL, "https://example.com/playlist.jpg")
        XCTAssertEqual(item?.includeAlbumArtInCloudMetadata, false)
        XCTAssertTrue(item?.isContainer ?? false)
        XCTAssertEqual(item?.serviceId, 204)
        XCTAssertEqual(item?.cloudType, "PLAYLIST")
        XCTAssertEqual(item?.uri?.isEmpty, false)

        let unwrappedItem = try XCTUnwrap(item)
        let metadata = searchManager.buildCloudDIDLMetadata(
            item: unwrappedItem,
            localSid: 204,
            accountId: "2")
        XCTAssertFalse(metadata.contains("<upnp:albumArtURI>"))
    }

    func testStationLocalServicePlayableResolvesToProgramRadioBrowseItem() async throws {
        let searchManager = localServiceSearchManager()
        let manager = try await localServiceSonosManager()
        let playable = LocalServiceAppleMusicPlayable(
            kind: .station,
            catalogID: "radio:ra.1740614260",
            title: "Apple Music Chill",
            artist: "",
            album: "",
            artworkURLString: "https://example.com/chill.jpg",
            duration: nil,
            stationPlaybackKind: .tracks)

        let item = await searchManager.resolveLocalAppleMusicBrowseItem(playable, manager: manager)

        XCTAssertEqual(item?.id, "radio:ra.1740614260")
        XCTAssertEqual(item?.title, "Apple Music Chill")
        XCTAssertFalse(item?.isContainer ?? true)
        XCTAssertEqual(item?.serviceId, 204)
        XCTAssertEqual(item?.cloudType, "PROGRAM")
        XCTAssertEqual(item?.uri?.isEmpty, false)
    }

    @MainActor
    func testPlayNextReturnsFalseWhenBrowseItemHasNoPlayableURI() async {
        let searchManager = SearchManager()
        let manager = SonosManager()
        manager.selectedSpeaker = SonosPlayer(
            id: "RINCON_TEST",
            name: "Test Speaker",
            ipAddress: "127.0.0.1",
            isCoordinator: true)
        let item = BrowseItem(
            id: "song:no-uri",
            title: "No URI",
            artist: "Artist",
            album: "Album",
            uri: nil,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK")

        let didQueue = await searchManager.playNext(item: item, manager: manager)

        XCTAssertFalse(didQueue)
        XCTAssertEqual(
            searchManager.errorMessage,
            LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription)
    }

    private func localServiceSearchManager() -> SearchManager {
        let searchManager = SearchManager()
        searchManager.musicServices = [
            MusicService(
                id: 204,
                name: "Apple Music",
                smapiURI: "https://sonos-music.apple.com/ws/SonosSoap",
                capabilitiesMask: 1,
                authType: "AppLink",
                serviceType: "52231")
        ]
        searchManager.linkedAccounts = [Self.appleMusicAccount()]
        searchManager.rebuildLocalServiceIdMapping()
        return searchManager
    }

    private func localServiceSonosManager() async throws -> SonosManager {
        _ = try await Self.localServiceProbeServer()

        let manager = SonosManager()
        manager.selectedSpeaker = SonosPlayer(
            id: "RINCON_TEST",
            name: "Test Speaker",
            ipAddress: "127.0.0.1",
            isCoordinator: true)
        return manager
    }

    private static func localServiceProbeServer() async throws -> LocalServiceProbeServer {
        if let sharedProbeServer {
            return sharedProbeServer
        }

        let server = try LocalServiceProbeServer()
        try await server.start()
        sharedProbeServer = server
        return server
    }

    private static func appleMusicAccount() -> SonosCloudAPI.CloudMusicServiceAccount {
        SonosCloudAPI.CloudMusicServiceAccount(
            id: nil,
            serviceId: "52231",
            integrationId: nil,
            accountId: "2",
            nickname: nil,
            name: "Apple Music",
            username: "X_#Svc52231-test-account-Token",
            isGuest: false)
    }
}

private final class LocalServiceProbeServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalServiceProbeServer")

    init() throws {
        listener = try NWListener(using: .tcp, on: 1400)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: self.queue)
            }
            listener.start(queue: queue)
        }
    }

    func cancel() {
        listener.cancel()
    }
}
