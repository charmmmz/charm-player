import XCTest
import Network
@testable import SonosWidget

final class LocalServiceInteractionTests: XCTestCase {
    private let sidMappingKey = "CloudLocalSidMapping"

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
            [.play, .shuffle])
    }

    func testAlbumDetailActionsOmitAppleMusicLinkWhenUnavailable() {
        XCTAssertEqual(
            LocalMusicDetailActions.album(hasAppleMusicURL: false),
            [.play, .shuffle])
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
        let playlistURL = URL(string: "https://example.com/playlist.jpg")!

        XCTAssertEqual(
            MusicResourceArtworkSelection.preferredRowArtworkURL(primary: trackURL, fallback: playlistURL),
            trackURL
        )
    }

    func testPlaylistTrackArtworkSelectionFallsBackToPlaylistArtwork() {
        let playlistURL = URL(string: "https://example.com/playlist.jpg")!

        XCTAssertEqual(
            MusicResourceArtworkSelection.preferredRowArtworkURL(primary: nil, fallback: playlistURL),
            playlistURL
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
        XCTAssertTrue(item?.isContainer ?? false)
        XCTAssertEqual(item?.serviceId, 204)
        XCTAssertEqual(item?.cloudType, "PLAYLIST")
        XCTAssertEqual(item?.uri?.isEmpty, false)
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
        let server = try LocalServiceProbeServer()
        try await server.start()
        addTeardownBlock {
            server.cancel()
        }

        let manager = SonosManager()
        manager.selectedSpeaker = SonosPlayer(
            id: "RINCON_TEST",
            name: "Test Speaker",
            ipAddress: "127.0.0.1",
            isCoordinator: true)
        return manager
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
