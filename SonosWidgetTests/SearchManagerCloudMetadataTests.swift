import XCTest
@testable import SonosWidget

final class SearchManagerCloudMetadataTests: XCTestCase {
    private let sidMappingKey = "CloudLocalSidMapping"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: sidMappingKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: sidMappingKey)
        super.tearDown()
    }

    func testCloudMetadataUsesLinkedAccountUsernameWhenUsernameCacheIsEmpty() {
        UserDefaults.standard.set(["52231": 204], forKey: sidMappingKey)
        let manager = SearchManager()
        manager.linkedAccounts = [
            SonosCloudAPI.CloudMusicServiceAccount(
                id: nil,
                serviceId: "52231",
                integrationId: nil,
                accountId: "2",
                nickname: nil,
                name: "Apple Music",
                username: "X_#Svc52231-real-account-Token",
                isGuest: false)
        ]
        let item = BrowseItem(
            id: "song:1440857781",
            title: "Nikes",
            artist: "Frank Ocean",
            album: "Blonde",
            albumArtURL: nil,
            uri: "x-sonos-http:song%3A1440857781.mp4?sid=204&flags=8232&sn=2",
            duration: 312,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK")

        let metadata = manager.buildCloudDIDLMetadata(
            item: item,
            localSid: 204,
            accountId: "2")

        XCTAssertTrue(metadata.contains("SA_RINCON52231_X_#Svc52231-real-account-Token"))
        XCTAssertFalse(metadata.contains("-0-Token"))
    }

    func testCloudMetadataFallsBackToAccountIdInsteadOfZeroToken() {
        UserDefaults.standard.set(["52231": 204], forKey: sidMappingKey)
        let manager = SearchManager()
        let item = BrowseItem(
            id: "song:1440857781",
            title: "Nikes",
            artist: "Frank Ocean",
            album: "Blonde",
            albumArtURL: nil,
            uri: "x-sonos-http:song%3A1440857781.mp4?sid=204&flags=8232&sn=2",
            duration: 312,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK")

        let metadata = manager.buildCloudDIDLMetadata(
            item: item,
            localSid: 204,
            accountId: "2")

        XCTAssertTrue(metadata.contains("SA_RINCON52231_X_#Svc52231-2-Token"))
        XCTAssertFalse(metadata.contains("-0-Token"))
    }

    func testAppleMusicTrackFactoryUsesNamespacedTrackObjectID() {
        UserDefaults.standard.set(["52231": 204], forKey: sidMappingKey)
        let manager = SearchManager()

        let item = manager.makeTrackItem(
            objectId: "song:1440857781",
            title: "Nikes",
            artist: "Frank Ocean",
            album: "Blonde",
            artURL: nil,
            mimeType: "audio/mp4",
            cloudServiceId: "52231",
            accountId: "2")

        XCTAssertEqual(item.id, "song:1440857781")
        XCTAssertEqual(
            item.uri,
            "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2")
    }

    func testTrackMetadataPrefixesNamespacedAppleMusicTrackWithFlags() {
        UserDefaults.standard.set(["52231": 204], forKey: sidMappingKey)
        let manager = SearchManager()
        let item = BrowseItem(
            id: "song:1440857781",
            title: "Nikes",
            artist: "Frank Ocean",
            album: "Blonde",
            albumArtURL: nil,
            uri: "x-sonos-http:song%3A1440857781.mp4?sid=204&flags=8232&sn=2",
            duration: 312,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK")

        let metadata = manager.buildCloudDIDLMetadata(
            item: item,
            localSid: 204,
            accountId: "2")

        XCTAssertTrue(metadata.contains("id=\"10032028song%3a1440857781\""))
        XCTAssertFalse(metadata.contains("id=\"100320281440857781\""))
        XCTAssertFalse(metadata.contains("10032028100320201440857781"))
    }

    func testAppleMusicAlbumFactoryUsesNamespacedAlbumObjectID() {
        UserDefaults.standard.set(["52231": 204], forKey: sidMappingKey)
        let manager = SearchManager()

        let item = manager.makeAlbumItem(
            objectId: "album:1440668749",
            title: "Late Registration",
            artist: "Kanye West",
            artURL: nil,
            cloudServiceId: "52231",
            accountId: "2")

        XCTAssertEqual(item.id, "album:1440668749")
        XCTAssertEqual(
            item.uri,
            "x-rincon-cpcontainer:1004206calbum%3a1440668749?sid=204&flags=8300&sn=2")

        let metadata = manager.buildCloudDIDLMetadata(
            item: item,
            localSid: 204,
            accountId: "2")

        XCTAssertTrue(metadata.contains("id=\"1004206calbum%3a1440668749\""))
        XCTAssertFalse(metadata.contains("id=\"1004206c1440668749\""))
    }
}
