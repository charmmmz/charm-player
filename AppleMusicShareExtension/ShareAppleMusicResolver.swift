import Foundation
import MusicKit

struct ShareAppleMusicResolver {
    func resolve(urlString: String) async throws -> ShareAppleMusicPlayable {
        guard let link = ShareAppleMusicLinkParser.parse(urlString) else {
            throw SharePlaybackError.missingAppleMusicLink
        }

        let placeholder = ShareAppleMusicPlayable.placeholder(from: link)
        guard MusicAuthorization.currentStatus == .authorized else {
            return placeholder
        }

        do {
            switch link.kind {
            case .song:
                return try await resolveSong(link: link, fallback: placeholder)
            case .album:
                return try await resolveAlbum(link: link, fallback: placeholder)
            case .playlist:
                return try await resolvePlaylist(link: link, fallback: placeholder)
            case .artist:
                return try await resolveArtist(link: link, fallback: placeholder)
            }
        } catch {
            return placeholder
        }
    }

    private func resolveSong(
        link: ShareAppleMusicLink,
        fallback: ShareAppleMusicPlayable
    ) async throws -> ShareAppleMusicPlayable {
        var request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            equalTo: MusicItemID(link.catalogID)
        )
        request.limit = 1
        guard let song = try await request.response().items.first else {
            return fallback
        }
        return ShareAppleMusicPlayable(
            kind: .song,
            catalogID: link.catalogID,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            artworkURLString: artworkURLString(song.artwork),
            duration: song.duration)
    }

    private func resolveAlbum(
        link: ShareAppleMusicLink,
        fallback: ShareAppleMusicPlayable
    ) async throws -> ShareAppleMusicPlayable {
        var request = MusicCatalogResourceRequest<Album>(
            matching: \.id,
            equalTo: MusicItemID(link.catalogID)
        )
        request.limit = 1
        guard let album = try await request.response().items.first else {
            return fallback
        }
        return ShareAppleMusicPlayable(
            kind: .album,
            catalogID: link.catalogID,
            title: album.title,
            artist: album.artistName,
            album: album.title,
            artworkURLString: artworkURLString(album.artwork),
            duration: nil)
    }

    private func resolvePlaylist(
        link: ShareAppleMusicLink,
        fallback: ShareAppleMusicPlayable
    ) async throws -> ShareAppleMusicPlayable {
        var request = MusicCatalogResourceRequest<Playlist>(
            matching: \.id,
            equalTo: MusicItemID(link.catalogID)
        )
        request.limit = 1
        guard let playlist = try await request.response().items.first else {
            return fallback
        }
        return ShareAppleMusicPlayable(
            kind: .playlist,
            catalogID: link.catalogID,
            title: playlist.name,
            artist: playlist.curatorName ?? "",
            album: "",
            artworkURLString: artworkURLString(playlist.artwork),
            duration: nil)
    }

    private func resolveArtist(
        link: ShareAppleMusicLink,
        fallback: ShareAppleMusicPlayable
    ) async throws -> ShareAppleMusicPlayable {
        var request = MusicCatalogResourceRequest<Artist>(
            matching: \.id,
            equalTo: MusicItemID(link.catalogID)
        )
        request.limit = 1
        guard let artist = try await request.response().items.first else {
            return fallback
        }
        return ShareAppleMusicPlayable(
            kind: .artist,
            catalogID: link.catalogID,
            title: artist.name,
            artist: "",
            album: "",
            artworkURLString: artworkURLString(artist.artwork),
            duration: nil)
    }

    private func artworkURLString(_ artwork: Artwork?) -> String? {
        artwork?.url(width: 600, height: 600)?.absoluteString
    }
}
