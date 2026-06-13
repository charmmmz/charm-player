import XCTest
@testable import SonosWidget

final class SearchManagerCloudMetadataTests: XCTestCase {
    private let sidMappingKey = "CloudLocalSidMapping"
    private let enabledServicesKey = "SearchEnabledServices"
    private let serviceCatalogKey = "musicServiceCatalogByLocalSid"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: sidMappingKey)
        UserDefaults.standard.removeObject(forKey: enabledServicesKey)
        UserDefaults.standard.removeObject(forKey: serviceCatalogKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: sidMappingKey)
        UserDefaults.standard.removeObject(forKey: enabledServicesKey)
        UserDefaults.standard.removeObject(forKey: serviceCatalogKey)
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

    func testAppleMusicStationTransportUsesProgramMetadataShape() {
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

        let payload = manager.stationTransportPayload(
            radioId: "radio:ra.1740614260",
            stationName: "Apple Music Chill",
            cloudServiceId: "52231",
            accountId: "2",
            artURL: "https://example.com/chill.png",
            resMD: nil)

        XCTAssertEqual(
            payload.uri,
            "x-sonosapi-radio:radio%3ara.1740614260?sid=204&flags=8300&sn=2")
        XCTAssertTrue(payload.metadata.contains("id=\"000c206cradio%3ara.1740614260\""))
        XCTAssertTrue(payload.metadata.contains("object.item.audioItem.audioBroadcast.#programRadio"))
        XCTAssertFalse(payload.metadata.contains("<upnp:albumArtURI>"))
        XCTAssertTrue(payload.metadata.contains("SA_RINCON52231_X_#Svc52231-real-account-Token"))
    }

    func testLiveAppleMusicStationTransportUsesBrowseHLSShape() {
        UserDefaults.standard.set(["52231": 204], forKey: sidMappingKey)
        let manager = SearchManager()

        let payloads = manager.stationTransportPayloads(
            radioId: "radio:ra.1740614260",
            streamObjectID: "CgkIBRoF9NT-vQYQBA",
            isLiveStreamStation: true,
            stationName: "Apple Music Chill",
            cloudServiceId: "52231",
            accountId: "2",
            artURL: "https://example.com/chill.png",
            resMD: nil)

        XCTAssertEqual(
            payloads.map(\.uri),
            [
                "x-sonosapi-stream:hls%3ara.1740614260?sid=204&flags=8292&sn=2",
                "x-sonosapi-radio:radio%3ara.1740614260?sid=204&flags=8300&sn=2"
            ])
        XCTAssertEqual(payloads.map(\.label), ["hlsLiveRadio", "radioID"])
        XCTAssertTrue(payloads[0].metadata.contains("id=\"10092064hls%3ara.1740614260\""))
        XCTAssertTrue(payloads[0].metadata.contains("object.item.audioItem.audioBroadcast"))
        XCTAssertTrue(payloads[0].metadata.contains("<upnp:albumArtURI>https://example.com/chill.png</upnp:albumArtURI>"))
        XCTAssertFalse(payloads[0].uri.contains("CgkIBRoF9NT-vQYQBA"))
    }

    func testLocalMusicServiceAccountsParserIgnoresDeletedAccounts() {
        let xml = """
        <ZPSupportInfo type="User">
          <Accounts Version="8">
            <Account Type="52231" SerialNum="2">
              <UN>apple-user</UN>
              <MD>1</MD>
              <NN>Charm Apple</NN>
              <OADevID></OADevID>
              <Key></Key>
            </Account>
            <Account Type="41735" SerialNum="3" Deleted="1">
              <UN>deleted-user</UN>
              <MD>1</MD>
              <NN>Deleted</NN>
              <OADevID></OADevID>
              <Key></Key>
            </Account>
          </Accounts>
        </ZPSupportInfo>
        """

        XCTAssertEqual(
            SonosAPI.parseLocalMusicServiceAccounts(xml),
            [
                LocalMusicServiceAccount(
                    serviceType: "52231",
                    serialNumber: "2",
                    username: "apple-user",
                    nickname: "Charm Apple")
            ])
    }

    func testInfersLocalMusicServiceAccountsFromFavoriteURIsWhenStatusAccountsIsEmpty() {
        let services = [
            MusicService(
                id: 204,
                name: "Apple Music",
                smapiURI: "https://sonos-music.apple.com/ws/SonosSoap",
                capabilitiesMask: 1,
                authType: "AppLink",
                serviceType: "52231"),
            MusicService(
                id: 165,
                name: "网易云音乐",
                smapiURI: "https://netease.sonoschina.com/server/SonosAPI.php",
                capabilitiesMask: 1,
                authType: "AppLink",
                serviceType: "42247"),
            MusicService(
                id: 254,
                name: "TuneIn",
                smapiURI: "https://legato.radiotime.com/Radio.asmx",
                capabilitiesMask: 1,
                authType: "Anonymous",
                serviceType: "65031")
        ]
        let favorites = [
            BrowseItem(
                id: "FV:2/51",
                title: "After Hours",
                artist: "",
                album: "",
                uri: "x-rincon-cpcontainer:1004206calbum%3a1499378108?sid=204&flags=8300&sn=2",
                isContainer: true),
            BrowseItem(
                id: "FV:2/7",
                title: "我喜欢的音乐",
                artist: "",
                album: "",
                uri: "x-rincon-cpcontainer:1006706cMYMUSIC%3afav?sid=165&flags=28780&sn=3",
                isContainer: true),
            BrowseItem(
                id: "FV:2/22",
                title: "Radio",
                artist: "",
                album: "",
                uri: "x-sonosapi-stream:s123?sid=254&flags=8292&sn=0",
                isContainer: false)
        ]

        XCTAssertEqual(
            SonosAPI.inferLocalMusicServiceAccounts(from: favorites, musicServices: services),
            [
                LocalMusicServiceAccount(
                    serviceType: "52231",
                    serialNumber: "2",
                    username: "X_#Svc52231-2-Token",
                    nickname: "Apple Music"),
                LocalMusicServiceAccount(
                    serviceType: "42247",
                    serialNumber: "3",
                    username: "X_#Svc42247-3-Token",
                    nickname: "网易云音乐")
            ])
    }

    func testCloudLinkedAccountsBuildLocalSidMappingForAppleMusicFactories() {
        let manager = SearchManager()
        manager.musicServices = [
            MusicService(
                id: 204,
                name: "Apple Music",
                smapiURI: "https://sonos-music.apple.com/ws/SonosSoap",
                capabilitiesMask: 1,
                authType: "AppLink",
                serviceType: "52231")
        ]
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

        manager.rebuildLocalServiceIdMapping()

        let item = manager.makeTrackItem(
            objectId: "song:1440857781",
            title: "Nikes",
            artist: "Frank Ocean",
            album: "Blonde",
            mimeType: "audio/mp4",
            cloudServiceId: "52231",
            accountId: "2")

        XCTAssertEqual(
            item.uri,
            "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2")
        XCTAssertEqual(item.serviceId, 204)
    }

    func testLocalCatalogMetadataIsSnapshottedWithoutCreatingSearchServices() {
        let manager = SearchManager()
        manager.musicServices = [
            MusicService(
                id: 204,
                name: "Apple Music",
                smapiURI: "https://sonos-music.apple.com/ws/SonosSoap",
                capabilitiesMask: 1,
                authType: "AppLink",
                serviceType: "52231",
                manifestURI: "https://cf.ws.sonos.com/p/m/apple",
                presentationMapURI: "https://cf.ws.sonos.com/p/pmap/apple")
        ]

        manager.rebuildLocalServiceIdMapping()

        XCTAssertEqual(SharedStorage.serviceNamesByLocalSid["204"], "Apple Music")
        XCTAssertEqual(
            SharedStorage.musicServiceCatalogByLocalSid["204"],
            MusicServiceCatalogMetadata(
                name: "Apple Music",
                serviceType: "52231",
                manifestURI: "https://cf.ws.sonos.com/p/m/apple",
                presentationMapURI: "https://cf.ws.sonos.com/p/pmap/apple"))
        XCTAssertTrue(manager.activeLocalSearchServices.isEmpty)
    }

    func testMusicServiceParserDerivesServiceTypeLikeSoCoWhenTypeListIsMissing() {
        let xml = """
        <Services SchemaVersion="1">
          <Service Id="9" Name="Spotify" Version="1.1"
            Uri="https://spotify.ws.sonos.com/smapi"
            SecureUri="https://spotify.ws.sonos.com/smapi"
            ManifestUri="https://cf.ws.sonos.com/p/m/spotify-manifest"
            PresentationMapUri="https://cf.ws.sonos.com/p/pmap/spotify"
            ContainerType="MService" Capabilities="2563" MaxMessagingChars="0">
            <Policy Auth="DeviceLink" PollInterval="30" />
          </Service>
          <Service Id="2" Name="Deezer" Version="1.1"
            Uri="https://deezer.ws.sonos.com/services/smapi"
            SecureUri="https://deezer.ws.sonos.com/services/smapi"
            ContainerType="MService" Capabilities="563" MaxMessagingChars="0">
            <Policy Auth="UserId" PollInterval="300" />
          </Service>
        </Services>
        """

        let services = SonosAPI.parseMusicServices(xml)

        XCTAssertEqual(services.first { $0.name == "Spotify" }?.serviceType, "2311")
        XCTAssertEqual(services.first { $0.name == "Deezer" }?.serviceType, "519")
        XCTAssertEqual(
            services.first { $0.name == "Spotify" }?.manifestURI,
            "https://cf.ws.sonos.com/p/m/spotify-manifest")
        XCTAssertEqual(
            services.first { $0.name == "Spotify" }?.presentationMapURI,
            "https://cf.ws.sonos.com/p/pmap/spotify")
    }

    func testActiveLocalSearchServicesStayEmptyWithoutCloudAccounts() {
        let manager = SearchManager()
        manager.linkedAccounts = []
        manager.musicServices = [
            MusicService(
                id: 204,
                name: "Apple Music",
                smapiURI: "https://example.com/apple",
                capabilitiesMask: 1,
                authType: "DeviceLink",
                serviceType: "52231"),
            MusicService(
                id: 174,
                name: "TIDAL",
                smapiURI: "https://example.com/tidal",
                capabilitiesMask: 1,
                authType: "DeviceLink",
                serviceType: "44551"),
            MusicService(
                id: 254,
                name: "TuneIn",
                smapiURI: "https://example.com/tunein",
                capabilitiesMask: 1,
                authType: "Anonymous",
                serviceType: "65031"),
            MusicService(
                id: 163,
                name: "Spreaker",
                smapiURI: "https://example.com/spreaker",
                capabilitiesMask: 513,
                authType: "Anonymous",
                serviceType: "41735")
        ]
        manager.localMusicServiceAccounts = [
            LocalMusicServiceAccount(
                serviceType: "52231",
                serialNumber: "2",
                username: "apple-user",
                nickname: nil)
        ]

        XCTAssertEqual(
            manager.activeLocalSearchServices.map(\.name),
            [])
    }

    func testDIDLBuilderSerializesTrackMetadataWithResourceAndServiceDescriptor() {
        let metadata = SonosDIDLBuilder.document([
            SonosDIDLElement(
                tag: "item",
                id: "10032028song%3a1440857781",
                parentID: "",
                title: "Nikes & Nights",
                upnpClass: "object.item.audioItem.musicTrack",
                resources: [
                    SonosDIDLResource(
                        uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
                        protocolInfo: "sonos.com-http:*:audio/mp4:*")
                ],
                creator: "Frank Ocean",
                album: "Blonde",
                albumArtist: "Frank Ocean",
                albumArtURI: "https://example.com/a&b.jpg",
                desc: "SA_RINCON52231_X_#Svc52231-2-Token")
        ])

        XCTAssertTrue(metadata.hasPrefix("<DIDL-Lite "))
        XCTAssertTrue(metadata.contains("<dc:title>Nikes &amp; Nights</dc:title>"))
        XCTAssertTrue(metadata.contains("<dc:creator>Frank Ocean</dc:creator>"))
        XCTAssertTrue(metadata.contains("<upnp:album>Blonde</upnp:album>"))
        XCTAssertTrue(metadata.contains("<r:albumArtist>Frank Ocean</r:albumArtist>"))
        XCTAssertTrue(metadata.contains("<upnp:class>object.item.audioItem.musicTrack</upnp:class>"))
        XCTAssertTrue(metadata.contains("<upnp:albumArtURI>https://example.com/a&amp;b.jpg</upnp:albumArtURI>"))
        XCTAssertTrue(metadata.contains("<res protocolInfo=\"sonos.com-http:*:audio/mp4:*\">x-sonos-http:song%3a1440857781.mp4?sid=204&amp;flags=8232&amp;sn=2</res>"))
        XCTAssertTrue(metadata.contains("<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">SA_RINCON52231_X_#Svc52231-2-Token</desc>"))
    }

    func testPlayableURIBuilderBuildsCanonicalServiceURIs() {
        XCTAssertEqual(
            SonosPlayableURIBuilder.serviceURI(
                scheme: "x-sonos-http",
                objectID: "song:1440857781",
                localSid: 204,
                flags: 8232,
                accountID: "2",
                fileExtension: ".mp4"),
            "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2")

        XCTAssertEqual(
            SonosPlayableURIBuilder.containerURI(
                prefix: "1004206c",
                objectID: "album:1440668749",
                localSid: 204,
                flags: 8300,
                accountID: "2"),
            "x-rincon-cpcontainer:1004206calbum%3a1440668749?sid=204&flags=8300&sn=2")
    }

    func testAddMultipleURIsToQueueBodiesChunkItemsLikeSoCo() {
        let items = (1...17).map { index in
            SonosQueuedURI(
                uri: "x-sonos-http:track\(index)?sid=204&flags=8232&sn=2",
                metadata: "<DIDL-Lite><item id=\"\(index)\" /></DIDL-Lite>")
        }

        let bodies = SonosAPI.addMultipleURIsToQueueBodies(items: items)

        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("<NumberOfURIs>16</NumberOfURIs>"))
        XCTAssertTrue(bodies[1].contains("<NumberOfURIs>1</NumberOfURIs>"))
        XCTAssertTrue(bodies[0].contains("<EnqueuedURIs>x-sonos-http:track1?sid=204&amp;flags=8232&amp;sn=2 x-sonos-http:track2?sid=204&amp;flags=8232&amp;sn=2"))
        XCTAssertTrue(bodies[0].contains("<EnqueuedURIsMetaData>&lt;DIDL-Lite&gt;&lt;item id=&quot;1&quot; /&gt;&lt;/DIDL-Lite&gt; &lt;DIDL-Lite&gt;&lt;item id=&quot;2&quot; /&gt;&lt;/DIDL-Lite&gt;"))
        XCTAssertTrue(bodies[0].contains("<ContainerURI></ContainerURI>"))
        XCTAssertTrue(bodies[0].contains("<ContainerMetaData></ContainerMetaData>"))
        XCTAssertTrue(bodies[0].contains("<DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued>"))
        XCTAssertTrue(bodies[0].contains("<EnqueueAsNext>0</EnqueueAsNext>"))
    }
}
