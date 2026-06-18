import Foundation

enum CloudObjectType: String, Sendable {
    case artist = "ARTIST"
    case album = "ALBUM"
    case playlist = "PLAYLIST"
    case track = "TRACK"
    case program = "PROGRAM"
    case collection = "COLLECTION"

    var isContainer: Bool {
        switch self {
        case .album, .playlist, .collection:
            return true
        case .artist, .track, .program:
            return false
        }
    }

    var favoriteRType: String {
        switch self {
        case .artist, .collection:
            return "shortcut"
        case .album, .playlist, .track, .program:
            return "instantPlay"
        }
    }

    var emitsFavoriteRes: Bool {
        switch self {
        case .artist, .collection:
            return false
        case .album, .playlist, .track, .program:
            return true
        }
    }
}

struct CloudBrowseItemFactory: Sendable {
    let cloudToLocalSid: [String: Int]
    let appleMusicCloudServiceIds: Set<String>

    func artistItem(
        objectId: String,
        name: String,
        artURL: String? = nil,
        cloudServiceId: String,
        accountId: String,
        preserveArtworkSize: Bool = false
    ) -> BrowseItem {
        item(
            type: .artist,
            objectId: objectId,
            title: name,
            artist: "",
            album: "",
            artURL: artURL,
            mimeType: nil,
            cloudServiceId: cloudServiceId,
            accountId: accountId,
            preserveArtworkSize: preserveArtworkSize
        )
    }

    func albumItem(
        objectId: String,
        title: String,
        artist: String,
        artURL: String? = nil,
        cloudServiceId: String,
        accountId: String,
        preserveArtworkSize: Bool = false
    ) -> BrowseItem {
        item(
            type: .album,
            objectId: objectId,
            title: title,
            artist: artist,
            album: title,
            artURL: artURL,
            mimeType: nil,
            cloudServiceId: cloudServiceId,
            accountId: accountId,
            preserveArtworkSize: preserveArtworkSize
        )
    }

    func playlistItem(
        objectId: String,
        title: String,
        artist: String = "",
        artURL: String? = nil,
        cloudServiceId: String,
        accountId: String
    ) -> BrowseItem {
        item(
            type: .playlist,
            objectId: objectId,
            title: title,
            artist: artist,
            album: "",
            artURL: artURL,
            mimeType: nil,
            cloudServiceId: cloudServiceId,
            accountId: accountId
        )
    }

    func trackItem(
        objectId: String,
        title: String,
        artist: String,
        album: String = "",
        artURL: String? = nil,
        mimeType: String? = nil,
        cloudServiceId: String,
        accountId: String
    ) -> BrowseItem {
        item(
            type: .track,
            objectId: objectId,
            title: title,
            artist: artist,
            album: album,
            artURL: artURL,
            mimeType: mimeType,
            cloudServiceId: cloudServiceId,
            accountId: accountId
        )
    }

    func stationItem(
        objectId: String,
        title: String,
        artistName: String = "",
        artURL: String? = nil,
        cloudServiceId: String,
        accountId: String
    ) -> BrowseItem {
        item(
            type: .program,
            objectId: objectId,
            title: title,
            artist: artistName,
            album: "",
            artURL: artURL,
            mimeType: nil,
            cloudServiceId: cloudServiceId,
            accountId: accountId
        )
    }

    func item(
        type: CloudObjectType,
        objectId: String,
        title: String,
        artist: String,
        album: String,
        artURL: String?,
        mimeType: String?,
        cloudServiceId: String,
        accountId: String,
        preserveArtworkSize: Bool = false
    ) -> BrowseItem {
        BrowseItem(
            id: objectId,
            title: title,
            artist: artist,
            album: album,
            albumArtURL: normalizedArtworkURLString(artURL),
            detailArtworkURL: detailArtworkURLString(
                artURL,
                preserveExistingSize: preserveArtworkSize
            ),
            uri: playableURI(
                objectId: objectId,
                serviceId: cloudServiceId,
                accountId: accountId,
                type: type,
                mimeType: mimeType
            ),
            isContainer: type.isContainer,
            serviceId: cloudToLocalSid[cloudServiceId],
            cloudType: type.rawValue
        )
    }

    func playableURI(
        objectId: String,
        serviceId: String?,
        accountId: String?,
        type: String,
        mimeType: String? = nil
    ) -> String? {
        guard let cloudType = CloudObjectType(rawValue: type) else { return nil }
        return playableURI(
            objectId: objectId,
            serviceId: serviceId,
            accountId: accountId,
            type: cloudType,
            mimeType: mimeType
        )
    }

    func playableURI(
        objectId: String,
        serviceId: String?,
        accountId: String?,
        type: CloudObjectType,
        mimeType: String? = nil
    ) -> String? {
        guard let cloudServiceId = serviceId,
              let accountId,
              let localSid = cloudToLocalSid[cloudServiceId] else {
            return nil
        }

        switch type {
        case .track:
            let trackId = trackURIObjectId(objectId: objectId, cloudServiceId: cloudServiceId)
            let (scheme, fileExtension, flags) = trackURIComponents(
                localSid: localSid,
                mimeType: mimeType
            )
            return SonosPlayableURIBuilder.serviceURI(
                scheme: scheme,
                objectID: trackId,
                localSid: localSid,
                flags: flags,
                accountID: accountId,
                fileExtension: fileExtension
            )
        case .album:
            return SonosPlayableURIBuilder.containerURI(
                prefix: "1004206c",
                objectID: objectId,
                localSid: localSid,
                flags: 8300,
                accountID: accountId
            )
        case .playlist:
            return SonosPlayableURIBuilder.containerURI(
                prefix: "1006206c",
                objectID: objectId,
                localSid: localSid,
                flags: 8300,
                accountID: accountId
            )
        case .program:
            return SonosPlayableURIBuilder.serviceURI(
                scheme: "x-sonosapi-radio",
                objectID: objectId,
                localSid: localSid,
                flags: 8300,
                accountID: accountId
            )
        case .artist:
            return SonosPlayableURIBuilder.containerURI(
                prefix: "",
                objectID: objectId,
                localSid: localSid,
                flags: 8300,
                accountID: accountId
            )
        case .collection:
            return nil
        }
    }

    func browseItem(
        from resource: SonosCloudAPI.CloudResource,
        serviceId: String?,
        accountId: String?
    ) -> BrowseItem? {
        guard let name = resource.name,
              let rawType = resource.type,
              let type = CloudObjectType(rawValue: rawType),
              type != .collection else {
            return nil
        }

        let objectId = resource.id?.objectId ?? UUID().uuidString
        let artistName = resource.artists?.first?.name ?? resource.summary?.content ?? ""
        let albumName = resource.container?.name ?? ""
        let artURL = resource.images?.first?.url ?? resource.container?.images?.first?.url
        let mimeType = resource.defaults.flatMap(Self.decodeMimeType)

        var item = BrowseItem(
            id: objectId,
            title: name,
            artist: artistName,
            album: albumName,
            albumArtURL: normalizedArtworkURLString(artURL),
            detailArtworkURL: detailArtworkURLString(
                artURL,
                preserveExistingSize: true
            ),
            uri: playableURI(
                objectId: objectId,
                serviceId: serviceId,
                accountId: accountId,
                type: type,
                mimeType: mimeType
            ),
            metaXML: nil,
            duration: TimeInterval(resource.durationMs ?? 0) / 1000,
            isContainer: type.isContainer,
            serviceId: serviceId.flatMap { cloudToLocalSid[$0] },
            cloudType: type.rawValue
        )
        item.cloudFavoriteId = nil
        return item
    }

    func albumTrackItem(
        from item: SonosCloudAPI.AlbumTrackItem,
        fallbackAlbumTitle: String,
        fallbackArtist: String? = nil,
        fallbackArtURL: String? = nil,
        fallbackServiceId: String? = nil,
        fallbackAccountId: String? = nil
    ) -> BrowseItem {
        let objectId = scopedObjectId(
            from: item.resource?.id?.objectId ?? item.id,
            scope: "track"
        )
        let title = Self.firstNonEmpty([item.title]) ?? ""
        let artist = Self.firstNonEmpty([
            item.artists?.first?.name,
            fallbackArtist,
            item.subtitle
        ]) ?? ""
        let album = Self.firstNonEmpty([fallbackAlbumTitle]) ?? ""
        let artURL = item.images?.tile1x1 ?? fallbackArtURL
        let duration = item.duration.flatMap(TimeInterval.init) ?? 0
        let resolvedCloudServiceId = item.resource?.id?.serviceId ?? fallbackServiceId
        let resolvedAccountId = item.resource?.id?.accountId ?? fallbackAccountId
        let mimeType = item.resource?.defaults.flatMap(Self.decodeMimeType)

        guard let cloudServiceId = resolvedCloudServiceId,
              let accountId = resolvedAccountId else {
            return BrowseItem(
                id: objectId,
                title: title,
                artist: artist,
                album: album,
                albumArtURL: normalizedArtworkURLString(artURL),
                detailArtworkURL: detailArtworkURLString(
                    artURL,
                    preserveExistingSize: true
                ),
                duration: duration,
                isContainer: false,
                serviceId: resolvedCloudServiceId.flatMap { cloudToLocalSid[$0] },
                cloudType: CloudObjectType.track.rawValue
            )
        }

        var browseItem = trackItem(
            objectId: objectId,
            title: title,
            artist: artist,
            album: album,
            artURL: artURL,
            mimeType: mimeType,
            cloudServiceId: cloudServiceId,
            accountId: accountId
        )
        browseItem.duration = duration
        return browseItem
    }

    func albumTrackContainerItem(from item: SonosCloudAPI.AlbumTrackItem) -> BrowseItem {
        let cloudType = albumTrackContainerType(item.resource?.type ?? item.type)
        let objectId = containerObjectId(
            from: item.resource?.id?.objectId ?? item.id,
            type: cloudType
        )
        let cloudServiceId = item.resource?.id?.serviceId
        let accountId = item.resource?.id?.accountId

        return BrowseItem(
            id: objectId,
            title: Self.firstNonEmpty([item.title]) ?? "",
            artist: Self.firstNonEmpty([item.subtitle]) ?? "",
            album: "",
            albumArtURL: normalizedArtworkURLString(item.images?.tile1x1),
            detailArtworkURL: detailArtworkURLString(
                item.images?.tile1x1,
                preserveExistingSize: true
            ),
            uri: playableURI(
                objectId: objectId,
                serviceId: cloudServiceId,
                accountId: accountId,
                type: cloudType
            ),
            isContainer: true,
            serviceId: cloudServiceId.flatMap { cloudToLocalSid[$0] },
            cloudType: cloudType.rawValue
        )
    }

    func cloudFavoriteItem(from favorite: SonosCloudAPI.CloudFavorite) -> BrowseItem {
        let cloudType = cloudType(forFavoriteResourceType: favorite.resource?.type)
        let cloudServiceId = favorite.service?.id?.serviceId
        var item = BrowseItem(
            id: favorite.id,
            title: favorite.name,
            artist: favorite.description ?? "",
            album: "",
            albumArtURL: normalizedArtworkURLString(favorite.imageUrl),
            detailArtworkURL: detailArtworkURLString(
                favorite.imageUrl,
                preserveExistingSize: true
            ),
            uri: nil,
            metaXML: nil,
            resMD: nil,
            isContainer: cloudType == CloudObjectType.album.rawValue ||
                cloudType == CloudObjectType.playlist.rawValue,
            serviceId: cloudServiceId.flatMap { cloudToLocalSid[$0] },
            cloudType: cloudType
        )
        item.cloudFavoriteId = favorite.id
        return item
    }

    func normalizedArtworkURLString(
        _ value: String?,
        preserveExistingSize: Bool = false
    ) -> String? {
        ArtworkURLNormalizer.loadableURLString(
            from: value,
            shortSidePixels: preserveExistingSize ? nil : 400,
            preserveExistingAppleArtworkSize: preserveExistingSize
        )
    }

    func detailArtworkURLString(
        _ value: String?,
        preserveExistingSize: Bool
    ) -> String? {
        guard preserveExistingSize else { return nil }
        return ArtworkURLNormalizer.loadableURLString(
            from: value,
            preserveExistingAppleArtworkSize: true
        )
    }

    private func albumTrackContainerType(_ resourceType: String?) -> CloudObjectType {
        switch resourceType {
        case CloudObjectType.album.rawValue:
            return .album
        case CloudObjectType.playlist.rawValue:
            return .playlist
        default:
            return .collection
        }
    }

    private func cloudType(forFavoriteResourceType resourceType: String?) -> String? {
        switch resourceType {
        case "album":
            return CloudObjectType.album.rawValue
        case "playlist":
            return CloudObjectType.playlist.rawValue
        case "track":
            return CloudObjectType.track.rawValue
        case "artist":
            return CloudObjectType.artist.rawValue
        case "station":
            return CloudObjectType.program.rawValue
        default:
            return nil
        }
    }

    private func containerObjectId(from rawId: String?, type: CloudObjectType) -> String {
        switch type {
        case .album:
            return scopedObjectId(from: rawId, scope: "album")
        case .playlist:
            return scopedObjectId(from: rawId, scope: "playlist")
        case .artist:
            return scopedObjectId(from: rawId, scope: "artist")
        case .track:
            return scopedObjectId(from: rawId, scope: "track")
        case .program, .collection:
            return Self.trimmedObjectId(rawId)
        }
    }

    private func scopedObjectId(from rawId: String?, scope: String) -> String {
        let base = Self.trimmedObjectId(rawId)
        guard !base.isEmpty else { return "" }
        let parts = base.components(separatedBy: ":")
        guard let scopeIndex = parts.firstIndex(where: {
            $0.caseInsensitiveCompare(scope) == .orderedSame
        }), scopeIndex < parts.index(before: parts.endIndex) else {
            return base
        }
        return parts[scopeIndex...].joined(separator: ":")
    }

    private static func trimmedObjectId(_ rawId: String?) -> String {
        guard let rawId else { return "" }
        let trimmed = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let fragmentStart = trimmed.firstIndex(of: "#") {
            return String(trimmed[..<fragmentStart])
        }
        return trimmed
    }

    private func trackURIObjectId(objectId: String, cloudServiceId: String) -> String {
        guard appleMusicCloudServiceIds.contains(cloudServiceId) else { return objectId }
        if let storeID = SonosAppleMusicTrackResolver.storeID(fromObjectID: objectId) {
            return "song:\(storeID)"
        }
        return objectId
    }

    private func trackURIComponents(localSid: Int, mimeType: String?) -> (String, String, Int) {
        switch localSid {
        case 12:
            return ("x-sonos-spotify", "", 8224)
        default:
            let (fileExtension, flags) = Self.extensionAndFlags(for: mimeType)
            return ("x-sonos-http", fileExtension, flags)
        }
    }

    private static func extensionAndFlags(for mimeType: String?) -> (String, Int) {
        switch mimeType {
        case "audio/aac", "audio/mp4", "audio/x-m4a":
            return (".mp4", 8232)
        case "audio/mpeg", "audio/mp3":
            return (".mp3", 8224)
        case "audio/flac":
            return (".flac", 8224)
        default:
            return (".unknown", 0)
        }
    }

    private static func decodeMimeType(from defaults: String) -> String? {
        guard let data = Data(base64Encoded: defaults),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["mimeType"] as? String
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
