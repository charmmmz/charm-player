import XCTest
@testable import SonosWidget

final class BrowseItemPlaybackResolverTests: XCTestCase {
    private func makeResolver() -> BrowseItemPlaybackResolver {
        BrowseItemPlaybackResolver(
            cloudToLocalSid: ["52231": 204],
            localToCloudSid: [204: "52231"],
            musicServices: [
                MusicService(
                    id: 204,
                    name: "Apple Music",
                    smapiURI: "https://sonos-music.apple.com/ws/SonosSoap",
                    capabilitiesMask: 1,
                    authType: "AppLink",
                    serviceType: "52231")
            ])
    }

    func testParsesCloudIdsFromDirectURI() {
        let item = BrowseItem(
            id: "album:123",
            title: "Album",
            artist: "Artist",
            album: "",
            uri: "x-rincon-cpcontainer:1004206c album%3A123?sid=204&flags=8300&sn=2",
            isContainer: true,
            serviceId: 204,
            cloudType: "ALBUM"
        )

        let ids = makeResolver().parseCloudIds(from: item)

        XCTAssertEqual(
            ids,
            BrowseItemPlaybackResolver.CloudIds(
                objectId: "album%3A123",
                cloudServiceId: "52231",
                accountId: "2"
            )
        )
    }

    func testParsesCloudIdsFromDIDLMetadataFallback() {
        let item = BrowseItem(
            id: "FV:2/51",
            title: "Playlist",
            artist: "",
            album: "",
            uri: nil,
            resMD: """
            <DIDL-Lite>
              <container id="1004206cplaylist%3Apl.u-123">
                <desc>SA_RINCON52231_X_#Svc52231-7-Token</desc>
              </container>
            </DIDL-Lite>
            """,
            isContainer: true,
            cloudType: "PLAYLIST"
        )

        let ids = makeResolver().parseCloudIds(from: item)

        XCTAssertEqual(
            ids,
            BrowseItemPlaybackResolver.CloudIds(
                objectId: "playlist%3Apl.u-123",
                cloudServiceId: "52231",
                accountId: "7"
            )
        )
    }

    func testFavoriteTransportURIBuildsFromResMDAndSeedServiceParams() {
        let seed = BrowseItem(
            id: "song:1440857781",
            title: "Song",
            artist: "Artist",
            album: "Album",
            uri: "x-sonos-http:song%3A1440857781.mp4?sid=204&flags=8232&sn=2",
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK"
        )
        let resMD = """
        <DIDL-Lite>
          <item id="1004206calbum%3A1440857781"></item>
        </DIDL-Lite>
        """

        let uri = makeResolver().favoriteTransportURI(
            resMD: resMD,
            seedItems: [seed],
            defaultFlags: 8300
        )

        XCTAssertEqual(
            uri,
            "x-rincon-cpcontainer:1004206calbum%3A1440857781?sid=204&flags=8300&sn=2"
        )
    }

    func testFavoriteTransportURIFallsBackToBareContainerWithoutSeedServiceParams() {
        let resMD = """
        <DIDL-Lite>
          <item id="1004206cplaylist%3Apl.u-123"></item>
        </DIDL-Lite>
        """

        let uri = makeResolver().favoriteTransportURI(
            resMD: resMD,
            seedItems: [],
            defaultFlags: 8300
        )

        XCTAssertEqual(uri, "x-rincon-cpcontainer:1004206cplaylist%3Apl.u-123")
    }
}
