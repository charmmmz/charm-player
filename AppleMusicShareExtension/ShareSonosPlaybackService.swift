import Foundation

struct ShareSonosPlaybackService {
    func play(
        _ playable: ShareAppleMusicPlayable,
        on group: ShareSpeakerGroup,
        credential: ShareAppleMusicSonosCredential
    ) async throws {
        let ip = group.coordinator.ipAddress
        let uri = try buildPlayableURI(playable: playable, credential: credential)
        let metadata = buildMetadata(playable: playable, uri: uri, credential: credential)

        try? await ShareSonosAPI.removeAllTracksFromQueue(ip: ip)
        let trackNumber = try await ShareSonosAPI.addURIToQueue(
            ip: ip,
            uri: uri,
            metadata: metadata
        )
        try await ShareSonosAPI.setAVTransportToQueue(
            ip: ip,
            speakerUUID: group.coordinator.id
        )
        try await ShareSonosAPI.seekToTrack(ip: ip, trackNumber: trackNumber)
        try await ShareSonosAPI.play(ip: ip)
    }

    private func buildPlayableURI(
        playable: ShareAppleMusicPlayable,
        credential: ShareAppleMusicSonosCredential
    ) throws -> String {
        let sid = credential.localServiceId
        let accountID = credential.accountId
        let encodedObjectID = playable.sonosObjectID.replacingOccurrences(of: ":", with: "%3a")

        switch playable.cloudType {
        case "TRACK":
            return "x-sonos-http:\(encodedObjectID).mp4?sid=\(sid)&flags=8232&sn=\(accountID)"
        case "ALBUM":
            return "x-rincon-cpcontainer:1004206c\(encodedObjectID)?sid=\(sid)&flags=8300&sn=\(accountID)"
        case "PLAYLIST":
            return "x-rincon-cpcontainer:1006206c\(encodedObjectID)?sid=\(sid)&flags=8300&sn=\(accountID)"
        case "ARTIST":
            return "x-rincon-cpcontainer:\(encodedObjectID)?sid=\(sid)&flags=8300&sn=\(accountID)"
        default:
            throw SharePlaybackError.playbackFailed("This Apple Music item is not supported yet.")
        }
    }

    private func buildMetadata(
        playable: ShareAppleMusicPlayable,
        uri: String,
        credential: ShareAppleMusicSonosCredential
    ) -> String {
        let cloudType = playable.cloudType
        let encodedObjectID = playable.sonosObjectID.replacingOccurrences(of: ":", with: "%3a")
        let (itemID, upnpClass, xmlTag) = metadataComponents(
            cloudType: cloudType,
            objectID: encodedObjectID,
            uri: uri
        )
        let username = credential.username?.isEmpty == false
            ? credential.username!
            : "X_#Svc\(credential.cloudServiceId)-\(credential.accountId)-Token"
        let desc = "SA_RINCON\(credential.cloudServiceId)_\(username)"

        var inner = "<dc:title>\(ShareSonosAPI.escapeXML(playable.title))</dc:title>" +
            "<upnp:class>\(upnpClass)</upnp:class>"

        let wantsRichMetadata = cloudType == "TRACK" || cloudType == "ALBUM" || cloudType == "PLAYLIST"
        if wantsRichMetadata {
            if let art = playable.artworkURLString, !art.isEmpty {
                inner += "<upnp:albumArtURI>\(ShareSonosAPI.escapeXML(art))</upnp:albumArtURI>"
            }
            if !playable.artist.isEmpty {
                let artist = ShareSonosAPI.escapeXML(playable.artist)
                inner += "<dc:creator>\(artist)</dc:creator>"
                if cloudType != "PLAYLIST" {
                    inner += "<r:albumArtist>\(artist)</r:albumArtist>"
                }
            }
            if cloudType == "TRACK", !playable.album.isEmpty {
                inner += "<upnp:album>\(ShareSonosAPI.escapeXML(playable.album))</upnp:album>"
            }
        }

        inner += "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">\(desc)</desc>"

        return "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " +
            "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" " +
            "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" +
            "<\(xmlTag) id=\"\(itemID)\" parentID=\"\" restricted=\"true\">" +
            inner +
            "</\(xmlTag)></DIDL-Lite>"
    }

    private func metadataComponents(
        cloudType: String,
        objectID: String,
        uri: String
    ) -> (String, String, String) {
        switch cloudType {
        case "TRACK":
            let flags = extractFlags(from: uri)
            let flagsHex = String(format: "%04x", flags)
            let catalogID = objectID.replacingOccurrences(of: "song%3a", with: "song%3a")
            return (
                "1003\(flagsHex)\(catalogID)",
                "object.item.audioItem.musicTrack",
                "item"
            )
        case "ALBUM":
            return (
                "1004206c\(objectID)",
                "object.container.album.musicAlbum.#AlbumView",
                "item"
            )
        case "PLAYLIST":
            return (
                "1006206c\(objectID)",
                "object.container.playlistContainer",
                "item"
            )
        case "ARTIST":
            return (
                "10052064\(objectID)",
                "object.container.person.musicArtist",
                "item"
            )
        default:
            return (objectID, "object.item.audioItem.musicTrack", "item")
        }
    }

    private func extractFlags(from uri: String) -> Int {
        guard let range = uri.range(of: "flags=") else { return 0 }
        let suffix = uri[range.upperBound...]
        if let ampersand = suffix.firstIndex(of: "&") {
            return Int(suffix[..<ampersand]) ?? 0
        }
        return Int(suffix) ?? 0
    }
}
