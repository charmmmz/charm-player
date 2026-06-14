import XCTest
@testable import SonosWidget

final class LocalLibraryModelsTests: XCTestCase {
    func testCategoriesExposeStableTitlesAndSymbols() {
        XCTAssertEqual(LocalLibraryCategory.songs.title, "Songs")
        XCTAssertEqual(LocalLibraryCategory.songs.systemImage, "music.note")
        XCTAssertEqual(LocalLibraryCategory.albums.title, "Albums")
        XCTAssertEqual(LocalLibraryCategory.albums.systemImage, "square.stack")
        XCTAssertEqual(LocalLibraryCategory.artists.title, "Artists")
        XCTAssertEqual(LocalLibraryCategory.artists.systemImage, "music.mic")
        XCTAssertEqual(LocalLibraryCategory.playlists.title, "Playlists")
        XCTAssertEqual(LocalLibraryCategory.playlists.systemImage, "music.note.list")
    }

    func testLibraryHomeOrderMatchesAppleMusicStyleEntryList() {
        XCTAssertEqual(LocalLibraryCategory.homeOrder, [
            .playlists,
            .artists,
            .albums,
            .songs
        ])
    }

    func testAlphabetIndexIsHiddenOnlyForPlaylists() {
        XCTAssertFalse(LocalLibraryCategory.playlists.showsAlphabetIndex)
        XCTAssertTrue(LocalLibraryCategory.artists.showsAlphabetIndex)
        XCTAssertTrue(LocalLibraryCategory.albums.showsAlphabetIndex)
        XCTAssertTrue(LocalLibraryCategory.songs.showsAlphabetIndex)
    }

    func testLibrarySectionIndexUsesLeadingLettersAndNumbers() {
        XCTAssertEqual(LocalLibrarySectionIndex.indexTitle(for: "  15 Step"), "#")
        XCTAssertEqual(LocalLibrarySectionIndex.indexTitle(for: "Élan"), "E")
        XCTAssertEqual(LocalLibrarySectionIndex.indexTitle(for: "zebra"), "Z")
        XCTAssertEqual(LocalLibrarySectionIndex.indexTitle(for: "   "), "#")

        XCTAssertEqual(
            LocalLibrarySectionIndex.indexTitles(for: ["zebra", "Élan", "15 Step", "apple"]),
            ["#", "A", "E", "Z"]
        )
    }

    func testSnapshotSummaryIsEmptyOnlyWhenAllSectionsAreEmpty() {
        XCTAssertTrue(
            LocalLibrarySnapshotSummary(
                songCount: 0,
                albumCount: 0,
                artistCount: 0,
                playlistCount: 0
            ).isEmpty
        )

        XCTAssertFalse(
            LocalLibrarySnapshotSummary(
                songCount: 1,
                albumCount: 0,
                artistCount: 0,
                playlistCount: 0
            ).isEmpty
        )
    }

    func testSnapshotSummaryReturnsCountsByCategory() {
        let summary = LocalLibrarySnapshotSummary(
            songCount: 7,
            albumCount: 3,
            artistCount: 2,
            playlistCount: 5
        )

        XCTAssertEqual(summary.count(for: .songs), 7)
        XCTAssertEqual(summary.count(for: .albums), 3)
        XCTAssertEqual(summary.count(for: .artists), 2)
        XCTAssertEqual(summary.count(for: .playlists), 5)
        XCTAssertEqual(summary.totalCount, 17)
    }

    func testLocalServiceSectionsExposeStableLabels() {
        XCTAssertEqual(LocalServiceSectionKind.recentlyAdded.title, "Recently Added")
        XCTAssertEqual(LocalServiceSectionKind.recentlyAdded.systemImage, "clock.badge.plus")
        XCTAssertEqual(LocalServiceSectionKind.recentlyPlayed.title, "Recently Played")
        XCTAssertEqual(LocalServiceSectionKind.recentlyPlayed.systemImage, "clock.arrow.circlepath")
        XCTAssertEqual(LocalServiceSectionKind.recommendations.title, "For You")
        XCTAssertEqual(LocalServiceSectionKind.recommendations.systemImage, "sparkles")
        XCTAssertEqual(LocalServiceSectionKind.library.title, "Your Library")
        XCTAssertEqual(LocalServiceSectionKind.library.systemImage, "music.note.list")
    }

    func testMusicResourcePresentationUsesOneTapIdentityForCardRegions() {
        let resource = MusicResourcePresentation(
            id: "recommendation-playlist-pl.heavy",
            kind: .playlist,
            title: "Heavy Rotation",
            subtitle: "Apple Music for Charm",
            detail: nil,
            fallbackSystemImage: "music.note.list",
            accessory: .chevron,
            isQueueable: true
        )

        XCTAssertEqual(resource.artworkTapID, resource.id)
        XCTAssertEqual(resource.titleTapID, resource.id)
    }

    func testMusicResourcePresentationMapsBrowseItemKindFromCloudType() {
        let item = BrowseItem(
            id: "playlist:pl.new",
            title: "New Music",
            artist: "Apple Music",
            album: "",
            albumArtURL: nil,
            uri: "x-rincon-cpcontainer:1006206c playlist%3Apl.new?sid=204&sn=2",
            isContainer: true,
            serviceId: 204,
            cloudType: "PLAYLIST"
        )

        let resource = MusicResourcePresentation.fromBrowseItem(
            item,
            fallbackSystemImage: "music.note.list",
            accessory: .chevron
        )

        XCTAssertEqual(resource.id, "playlist:pl.new")
        XCTAssertEqual(resource.kind, .playlist)
        XCTAssertEqual(resource.title, "New Music")
        XCTAssertEqual(resource.subtitle, "Apple Music")
        XCTAssertTrue(resource.isQueueable)
    }
}
