import AVFoundation
import Foundation
import MusicKit
import SwiftUI
import UIKit

extension LocalMusicAlbumDetailView {

    func playAlbum(shuffle: Bool, action: LocalMusicDetailAction) {
        guard actionInFlight == nil, !store.isStartingPlayback else { return }
        actionInFlight = action

        Task {
            await setSonosShuffleMode(shuffle)
            if LocalMusicAlbumDetailPresentation.shouldPlayDisplayedTracks(
                currentAlbumID: displayAlbum.id.rawValue,
                currentTrackCount: currentTrackCount,
                completeAlbumID: completeCatalogAlbum?.id.rawValue,
                completeTrackCount: completeAlbumTrackCount
            ) {
                await store.playDisplayedTracksOnSonos(
                    tracks: tracks,
                    displayID: displayID(for: action),
                    albumTitle: displayAlbum.title,
                    manager: manager,
                    searchManager: searchManager)
            } else {
                await store.playOnSonos(
                    playable: albumPlayable,
                    displayID: displayID(for: action),
                    fallbackKind: .album,
                    fallbackTitle: displayAlbum.title,
                    fallbackArtist: displayAlbum.artistName,
                    fallbackAlbum: displayAlbum.title,
                    manager: manager,
                    searchManager: searchManager)
            }
            withAnimation(.easeOut(duration: 0.2)) {
                actionInFlight = nil
            }
        }
    }

    func setSonosShuffleMode(_ enabled: Bool) async {
        guard let ip = manager.selectedSpeaker?.playbackIP else { return }
        let current = try? await SonosAPI.getPlayMode(ip: ip)
        if enabled || current?.shuffle == true {
            try? await SonosAPI.setPlayMode(
                ip: ip,
                shuffle: enabled,
                repeat: current?.repeat ?? .off)
        }
    }
}
