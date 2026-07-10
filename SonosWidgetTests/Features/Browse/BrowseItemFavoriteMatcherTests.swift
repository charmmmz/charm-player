import XCTest
@testable import SonosWidget

final class BrowseItemFavoriteMatcherTests: XCTestCase {
    private func makeMatcher() -> BrowseItemFavoriteMatcher {
        BrowseItemFavoriteMatcher(
            cloudToLocalSid: [
                "52231": 204,
                "2311": 307
            ],
            musicServices: [
                MusicService(
                    id: 204,
                    name: "Apple Music",
                    smapiURI: "https://sonos-music.apple.com/ws/SonosSoap",
                    capabilitiesMask: 1,
                    authType: "AppLink",
                    serviceType: "52231"),
                MusicService(
                    id: 307,
                    name: "Spotify",
                    smapiURI: "https://spotify-v5.ws.sonos.com/smapi",
                    capabilitiesMask: 1,
                    authType: "DeviceLink",
                    serviceType: "2311")
            ]
        )
    }

    func testServiceSignatureUsesDirectLocalServiceId() {
        let item = BrowseItem(
            id: "song:1",
            title: "Song",
            artist: "Artist",
            album: "Album",
            uri: nil,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK"
        )

        XCTAssertEqual(makeMatcher().serviceSignature(for: item), "sid:204")
    }

    func testServiceSignatureCanonicalizesRinconCloudServiceId() {
        let item = BrowseItem(
            id: "FV:2/51",
            title: "Playlist",
            artist: "",
            album: "",
            uri: nil,
            resMD: """
            <DIDL-Lite>
              <item id="1004206cplaylist%3Apl.u-123">
                <desc>SA_RINCON52231_X_#Svc52231-7-Token</desc>
              </item>
            </DIDL-Lite>
            """,
            isContainer: true,
            cloudType: "PLAYLIST"
        )

        XCTAssertEqual(makeMatcher().serviceSignature(for: item), "sid:204")
    }

    func testFavoriteMatchRejectsSameTitleFromDifferentServices() {
        let item = BrowseItem(
            id: "artist:swift",
            title: "Taylor Swift",
            artist: "",
            album: "",
            uri: "x-rincon-cpcontainer:10052064artist%3A159260351?sid=204&flags=8300&sn=2",
            isContainer: true,
            serviceId: 204,
            cloudType: "ARTIST"
        )
        let spotifyFavorite = BrowseItem(
            id: "FV:2/9",
            title: "Taylor Swift",
            artist: "",
            album: "",
            uri: "x-rincon-cpcontainer:10050907spotify%3Aartist%3A06HL4z0CvFAxyc27GXpf02?sid=307&flags=8300&sn=4",
            isContainer: true,
            serviceId: 307,
            cloudType: "ARTIST"
        )

        XCTAssertNil(makeMatcher().favorite(matching: item, in: [spotifyFavorite]))
    }

    func testFavoriteMatchIgnoresURIQueryWhenServiceMatches() {
        let item = BrowseItem(
            id: "album:1440857781",
            title: "Blonde",
            artist: "Frank Ocean",
            album: "",
            uri: "x-rincon-cpcontainer:1004206calbum%3A1440857781?sid=204&flags=8300&sn=2",
            isContainer: true,
            serviceId: 204,
            cloudType: "ALBUM"
        )
        let favorite = BrowseItem(
            id: "FV:2/10",
            title: "Blonde",
            artist: "Frank Ocean",
            album: "",
            uri: "x-rincon-cpcontainer:1004206calbum%3A1440857781?sid=204&flags=1234&sn=7",
            isContainer: true,
            serviceId: 204,
            cloudType: "ALBUM"
        )

        XCTAssertEqual(makeMatcher().favorite(matching: item, in: [favorite]), favorite)
    }
}
