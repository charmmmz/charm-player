import AVFoundation
import SwiftUI
import UIKit

extension NowPlayingOverlay {

    // MARK: - Track Info

    var trackInfoView: some View {
        let isTV = manager.trackInfo?.source == .tv
        return VStack(spacing: 4) {
            nowPlayingTitleLabel(lineLimit: 1, usesShadow: true)

            // For TV input the codec ("Dolby Atmos · MAT") is already
            // shown by the format badge in `tvFormatPanel` below, so
            // skip the artist/album subtitle rows entirely — repeating
            // it here just creates visual noise and the user already
            // complained about the duplicate Dolby Atmos label.
            if !isTV {
                if let artistNav = artistBrowseItem {
                    Button {
                        navigateFromNowPlaying(kind: .artist, item: artistNav)
                    } label: {
                        Text(manager.trackInfo?.artist ?? "—")
                            .font(MusicDetailHeaderTypography.nowPlayingArtistStyle.font)
                            .fontWeight(.regular)
                            .foregroundStyle(.white.opacity(MusicDetailHeaderTypography.artistOpacity))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(manager.trackInfo?.artist ?? "—")
                        .font(MusicDetailHeaderTypography.nowPlayingArtistStyle.font)
                        .fontWeight(.regular)
                        .foregroundStyle(.white.opacity(MusicDetailHeaderTypography.artistOpacity))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
                }

                if let albumNav = albumBrowseItem {
                    Button {
                        navigateFromNowPlaying(kind: .album, item: albumNav)
                    } label: {
                        Text(manager.trackInfo?.album ?? "")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(manager.trackInfo?.album ?? "")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                }
            }
        }
    }

    @ViewBuilder
    func nowPlayingTitleLabel(lineLimit: Int, usesShadow: Bool) -> some View {
        if NowPlayingAppleMusicLinkPolicy.shouldLinkTitle(
            canOpenAppleMusicTrack: canOpenCurrentAppleMusicTrack
        ) {
            Button {
                openCurrentAppleMusicTrack()
            } label: {
                nowPlayingTitleText(lineLimit: lineLimit, usesShadow: usesShadow)
            }
            .buttonStyle(.plain)
            .disabled(isOpeningAppleMusicLink)
            .accessibilityLabel("Open current song in Apple Music")
        } else {
            nowPlayingTitleText(lineLimit: lineLimit, usesShadow: usesShadow)
        }
    }

    func nowPlayingTitleText(lineLimit: Int, usesShadow: Bool) -> some View {
        Text(manager.trackInfo?.title ?? "Not Playing")
            .font(.title3.bold())
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .shadow(
                color: usesShadow ? .black.opacity(0.45) : .clear,
                radius: usesShadow ? 6 : 0,
                y: usesShadow ? 1 : 0
            )
    }

    // MARK: - Now Playing Navigation

    func navigateFromNowPlaying(kind: PlayerDetailRoute.Kind, item: BrowseItem) {
        let route: PlayerDetailRoute
        switch kind {
        case .artist:
            route = .artist(item)
        case .album:
            route = .album(item)
        }

        logPlayerNavigation(kind: kind.logName, item: item)
        navigateToDetail(route)
    }

    func logPlayerNavigation(kind: String, item: BrowseItem) {
        SonosLog.debug(
            .navItem,
            "Player navigation tapped kind=\(kind) " +
            "track='\(manager.trackInfo?.title ?? "nil")' " +
            "artist='\(manager.trackInfo?.artist ?? "nil")' " +
            "album='\(manager.trackInfo?.album ?? "nil")' " +
            "itemId=\(SonosLog.playbackLinkValue(item.id, maxLength: 640)) " +
            "cloudType='\(item.cloudType ?? "nil")' serviceId=\(item.serviceId.map(String.init) ?? "nil") " +
            "itemArt=\(SonosLog.playbackLinkValue(item.albumArtURL, maxLength: 640)) " +
            "itemDetail=\(SonosLog.playbackLinkValue(item.detailArtworkURL, maxLength: 640)) " +
            "nowPlayingArt=\(SonosLog.playbackLinkValue(nowPlayingInfo?.images?.tile1x1, maxLength: 640)) " +
            "trackInfoArt=\(SonosLog.playbackLinkValue(manager.trackInfo?.albumArtURL, maxLength: 640)) " +
            "uri=\(SonosLog.playbackLinkValue(item.uri, maxLength: 640))")
    }

    var currentAppleMusicTrackResource: AppleMusicFavoriteResource? {
        guard manager.trackInfo?.source == .appleMusic else { return nil }
        let nowPlayingObjectID = nowPlayingInfo?.item?.resource?.id?.objectId
            ?? nowPlayingInfo?.item?.id
        return AppleMusicExternalLinkResolver.currentTrackResource(
            trackURI: manager.trackInfo?.trackURI,
            nowPlayingObjectID: nowPlayingObjectID
        )
    }

    var canOpenCurrentAppleMusicTrack: Bool {
        currentAppleMusicTrackResource != nil || currentAppleMusicTrackURL != nil || hasCurrentAppleMusicTrackSearchMetadata
    }

    var hasCurrentAppleMusicTrackSearchMetadata: Bool {
        guard manager.trackInfo?.source == .appleMusic,
              let info = manager.trackInfo else { return false }
        return meaningfulAppleMusicSearchValue(info.title) != nil
            && meaningfulAppleMusicSearchValue(info.artist) != nil
    }

    var currentAppleMusicLinkLookupID: String {
        guard manager.trackInfo?.source == .appleMusic,
              let info = manager.trackInfo else {
            return "not-apple-music"
        }
        let nowPlayingObjectID = nowPlayingInfo?.item?.resource?.id?.objectId
            ?? nowPlayingInfo?.item?.id
            ?? ""
        return [
            info.trackURI ?? "",
            nowPlayingObjectID,
            info.title,
            info.artist,
            info.album
        ].joined(separator: "|")
    }

    @MainActor
    func refreshCurrentAppleMusicTrackURL() async {
        currentAppleMusicTrackURL = nil
        guard hasCurrentAppleMusicTrackSearchMetadata,
              let info = manager.trackInfo else { return }

        let lookupID = currentAppleMusicLinkLookupID
        do {
            let url = try await AppleMusicExternalLinkFallbackResolver().songURL(
                directResource: currentAppleMusicTrackResource,
                title: info.title,
                artist: info.artist,
                album: info.album
            )
            guard currentAppleMusicLinkLookupID == lookupID else { return }
            currentAppleMusicTrackURL = url
        } catch {
            guard currentAppleMusicLinkLookupID == lookupID else { return }
            SonosLog.debug(
                .nowPlaying,
                "Apple Music current track URL preload failed title='\(info.title)' artist='\(info.artist)' error=\(error)"
            )
        }
    }

    func meaningfulAppleMusicSearchValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "—",
              trimmed.localizedCaseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }
        return trimmed
    }

    var animatedArtworkLookupID: String {
        [
            animatedArtworkIdentity.map { identity in
                [
                    identity.trackURI ?? "",
                    identity.title,
                    identity.artist,
                    identity.album
                ].joined(separator: "|")
            } ?? "none",
            currentAppleMusicAnimatedArtworkLookupURL?.absoluteString ?? "",
            RelayManager.shared.activeURLString ?? ""
        ].joined(separator: "||")
    }

    var animatedArtworkIdentity: AnimatedNowPlayingArtworkState.Identity? {
        guard let info = manager.trackInfo,
              info.isLiveStream != true,
              let title = meaningfulAppleMusicSearchValue(info.title),
              let artist = meaningfulAppleMusicSearchValue(info.artist),
              let album = meaningfulAppleMusicSearchValue(info.album) else {
            return nil
        }
        return AnimatedNowPlayingArtworkState.Identity(
            trackURI: info.trackURI,
            title: title,
            artist: artist,
            album: album
        )
    }

    var currentAppleMusicAnimatedArtworkLookupURL: URL? {
        guard manager.trackInfo?.source == .appleMusic else { return nil }
        return currentAppleMusicTrackURL
    }

    func refreshAnimatedArtwork() {
        guard let identity = animatedArtworkIdentity else {
            animatedArtworkState.reset()
            animatedArtworkReadyURL = nil
            fullScreenAnimatedArtworkReadyURL = nil
            return
        }

        animatedArtworkState.resolve(
            identity: identity,
            albumURL: currentAppleMusicAnimatedArtworkLookupURL,
            relayBaseURL: RelayManager.shared.url,
            source: manager.trackInfo?.source
        )
    }

    var currentTrackBrowseItemForSonosFavorite: BrowseItem? {
        guard let item = currentTrackBrowseItem,
              item.playbackDescriptor.directURI != nil else { return nil }
        return item
    }

    var currentTrackBrowseItem: BrowseItem? {
        guard let info = manager.trackInfo,
              let title = meaningfulAppleMusicSearchValue(nowPlayingInfo?.item?.title)
                ?? meaningfulAppleMusicSearchValue(info.title),
              let nowPlayingItem = nowPlayingInfo?.item,
              let rawObjectId = nowPlayingItem.resource?.id?.objectId ?? nowPlayingItem.id,
              !rawObjectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let serviceId = nowPlayingItem.resource?.id?.serviceId,
              let accountId = nowPlayingItem.resource?.id?.accountId else {
            return nil
        }

        var item = searchManager.makeTrackItem(
            objectId: rawObjectId,
            title: title,
            artist: meaningfulAppleMusicSearchValue(nowPlayingItem.artists?.first?.name)
                ?? meaningfulAppleMusicSearchValue(info.artist)
                ?? "",
            album: meaningfulAppleMusicSearchValue(nowPlayingItem.albumName)
                ?? meaningfulAppleMusicSearchValue(info.album)
                ?? "",
            artURL: nowPlayingItem.images?.tile1x1
                ?? nowPlayingInfo?.images?.tile1x1
                ?? info.albumArtURL,
            cloudServiceId: serviceId,
            accountId: accountId
        )
        item.duration = info.durationSeconds
        return item
    }

    var artistBrowseItem: BrowseItem? {
        if let artist = nowPlayingInfo?.item?.artists?.first,
           let objectId = artist.objectId,
           let serviceId = nowPlayingInfo?.item?.resource?.id?.serviceId,
           let accountId = nowPlayingInfo?.item?.resource?.id?.accountId {
            return searchManager.makeArtistItem(
                objectId: objectId, name: artist.name ?? "",
                cloudServiceId: serviceId, accountId: accountId)
        }
        // Fallback for live radio: nowPlaying lookup failed (track id is the
        // radio station URI, not a song id) but we still have the artist
        // name from the broadcast metadata. Build a search-by-name artist
        // item so tapping navigates into ArtistDetailView, which already
        // resolves Apple Music artists by name via `searchService`.
        return liveStreamArtistBrowseItem
    }

    var albumBrowseItem: BrowseItem? {
        if let item = nowPlayingInfo?.item,
           let albumId = item.albumId,
           let serviceId = item.resource?.id?.serviceId,
           let accountId = item.resource?.id?.accountId {
            return searchManager.makeAlbumItem(
                objectId: albumId,
                title: item.albumName ?? manager.trackInfo?.album ?? "",
                artist: manager.trackInfo?.artist ?? "",
                artURL: nowPlayingInfo?.images?.tile1x1,
                cloudServiceId: serviceId, accountId: accountId,
                preserveArtworkSize: true)
        }
        // Same fallback as `artistBrowseItem`: in a live broadcast we have
        // the album name from broadcast metadata even if the per-track
        // nowPlaying lookup couldn't run, so feed it to AlbumDetailView and
        // let its existing search-by-name path resolve the real album id.
        return liveStreamAlbumBrowseItem
    }

    /// Build an artist `BrowseItem` for Apple Music live broadcasts where we
    /// only have the artist *name* (no per-track id). The detail view's
    /// `searchService` flow resolves the real artist id from the name. We
    /// pull `sid` / `sn` from whatever URI the speaker is currently on
    /// (e.g. `x-sonosapi-radio:radio:rsa.LiveRadio1?sid=204&sn=2`).
    var liveStreamArtistBrowseItem: BrowseItem? {
        guard let artistName = manager.trackInfo?.artist, !artistName.isEmpty,
              let ids = liveStreamCloudIds else { return nil }
        return searchManager.makeArtistItem(
            objectId: artistName,
            name: artistName,
            cloudServiceId: ids.cloudSid,
            accountId: ids.accountId)
    }

    var liveStreamAlbumBrowseItem: BrowseItem? {
        guard let albumName = manager.trackInfo?.album, !albumName.isEmpty,
              let artistName = manager.trackInfo?.artist, !artistName.isEmpty,
              let ids = liveStreamCloudIds else { return nil }
        return searchManager.makeAlbumItem(
            objectId: albumName,
            title: albumName,
            artist: artistName,
            artURL: manager.trackInfo?.albumArtURL,
            cloudServiceId: ids.cloudSid,
            accountId: ids.accountId,
            preserveArtworkSize: true)
    }

    var liveStreamCloudIds: (cloudSid: String, accountId: String)? {
        guard let trackURI = manager.trackInfo?.trackURI else { return nil }
        var localSid: Int?
        var sn: String?
        if let queryPart = trackURI.split(separator: "?").last {
            for param in queryPart.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                if kv[0] == "sid" { localSid = Int(kv[1]) }
                if kv[0] == "sn" { sn = String(kv[1]) }
            }
        }
        guard let sid = localSid,
              let cloudSid = searchManager.cloudServiceId(forLocalSid: sid),
              let accountId = sn else { return nil }
        return (cloudSid, accountId)
    }

    func fetchNowPlaying(trackURI: String) async {
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else { return }

        var localSid: Int?
        var accountId = "2"
        if let queryPart = trackURI.split(separator: "?").last {
            for param in queryPart.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                if kv[0] == "sid" { localSid = Int(kv[1]) }
                if kv[0] == "sn" { accountId = String(kv[1]) }
            }
        }

        guard let sid = localSid,
              let cloudSid = searchManager.cloudServiceId(forLocalSid: sid) else {
            nowPlayingInfo = nil
            return
        }

        guard let objectId = SonosAppleMusicTrackResolver
            .cloudTrackObjectIDForNowPlaying(fromTrackURI: trackURI) else {
            nowPlayingInfo = nil
            return
        }

        do {
            let response = try await SonosCloudAPI.nowPlaying(
                token: token, householdId: householdId,
                serviceId: cloudSid, accountId: accountId,
                trackObjectId: objectId)
            // Drop the result if the current track has moved on during the
            // request — we don't want an older lookup overwriting a newer
            // song's info when two track-changes happen back-to-back.
            guard manager.trackInfo?.trackURI == trackURI else { return }
            nowPlayingInfo = response
        } catch {
            SonosLog.error(.nowPlaying, "Fetch failed: \(error)")
            if manager.trackInfo?.trackURI == trackURI {
                nowPlayingInfo = nil
            }
        }
    }

}
