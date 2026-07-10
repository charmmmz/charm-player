import AVFoundation
import SwiftUI


extension AlbumDetailView {

    // MARK: - Data Loading

    func loadAlbum() async {
        guard response == nil else { isLoading = false; return }
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            errorText = "Not logged in to Sonos Cloud"
            isLoading = false
            return
        }

        let serviceIdStr: String? = {
            if let sid = albumItem.serviceId {
                return searchManager.cloudServiceId(forLocalSid: sid)
            }
            return searchManager.activeServiceIds.first
        }()

        guard let serviceId = serviceIdStr else {
            errorText = "No music service linked"
            isLoading = false
            return
        }

        let accountId = accountIdFromURI(albumItem.uri) ?? searchManager.linkedAccounts
            .first { $0.serviceId == serviceId }?.accountId ?? "2"
        guard let browseAlbumId = await resolvedAlbumBrowseID(
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId
        ) else {
            SonosLog.error(
                .albumDetail,
                "No browseable album id for rawId='\(albumItem.id)' " +
                "title='\(albumItem.title)' artist='\(albumItem.artist)'")
            errorText = "Album ID unavailable"
            isLoading = false
            return
        }
        resolvedAlbumID = browseAlbumId
        SonosLog.debug(
            .albumDetail,
            "browseAlbum rawId='\(albumItem.id)' normalizedId='\(browseAlbumId)' " +
            "title='\(albumItem.title)' artist='\(albumItem.artist)' " +
            "serviceId='\(serviceId)' accountId='\(accountId)' uri='\(albumItem.uri ?? "nil")'")

        do {
            response = try await SonosCloudAPI.browseAlbum(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId,
                albumId: browseAlbumId)
            logArtworkSelection(trigger: "browseAlbumResponse")
            isLoading = false
        } catch is CancellationError {
            SonosLog.debug(.albumDetail, "Load cancelled (tab switch)")
        } catch {
            SonosLog.error(.albumDetail, "Load failed: \(error)")
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    func resolvedAlbumBrowseID(
        token: String,
        householdId: String,
        serviceId: String,
        accountId: String
    ) async -> String? {
        if let directID = SonosAlbumBrowseID.concreteAlbumID(from: albumItem.id) {
            return directID
        }

        SonosLog.info(
            .albumDetail,
            "Resolving missing album id via search rawId='\(albumItem.id)' " +
            "title='\(albumItem.title)' artist='\(albumItem.artist)'")

        do {
            let searchResult = try await SonosCloudAPI.searchService(
                token: token,
                householdId: householdId,
                serviceId: serviceId,
                accountId: accountId,
                term: albumItem.title,
                count: 50
            )
            let resolvedID = SonosAlbumSearchResolver.preferredAlbumID(
                in: searchResult,
                title: albumItem.title,
                artist: albumItem.artist
            )
            SonosLog.info(
                .albumDetail,
                "Resolved missing album id title='\(albumItem.title)' id='\(resolvedID ?? "nil")'")
            return resolvedID
        } catch is CancellationError {
            return nil
        } catch {
            SonosLog.error(.albumDetail, "Album id search resolution failed: \(error)")
            return nil
        }
    }

    func accountIdFromURI(_ uri: String?) -> String? {
        guard let queryPart = uri?.split(separator: "?").last else { return nil }
        for param in queryPart.split(separator: "&") {
            let kv = param.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "sn" {
                return String(kv[1])
            }
        }
        return nil
    }

    // MARK: - Playback

    func playAlbum() {
        guard playingItemId == nil else { return }
        playingItemId = "play-all"

        Task {
            if let ip = manager.selectedSpeaker?.playbackIP {
                let current = try? await SonosAPI.getPlayMode(ip: ip)
                if current?.shuffle == true {
                    try? await SonosAPI.setPlayMode(ip: ip, shuffle: false,
                                                    repeat: current?.repeat ?? .off)
                }
            }
            await searchManager.playNow(item: playbackAlbumItem, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    func playAlbumShuffled() {
        guard playingItemId == nil else { return }
        playingItemId = "shuffle"

        Task {
            if let ip = manager.selectedSpeaker?.playbackIP {
                let current = try? await SonosAPI.getPlayMode(ip: ip)
                try? await SonosAPI.setPlayMode(ip: ip, shuffle: true,
                                                repeat: current?.repeat ?? .off)
            }
            await searchManager.playNow(item: playbackAlbumItem, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    func playTrack(_ track: SonosCloudAPI.AlbumTrackItem) {
        guard playingItemId == nil else { return }
        playingItemId = track.id

        let item = browseItemFromTrack(track)
        Task {
            await searchManager.playNow(item: item, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    func toggleFavorite() {
        Task {
            if isFavorited {
                let ok = await searchManager.removeFromFavorites(item: albumItem, manager: manager)
                if ok { isFavorited = false }
                showToast(ok ? "Removed from Favorites" : "Failed to remove")
            } else {
                let ok = await searchManager.addToFavorites(item: albumItem, manager: manager)
                if ok { isFavorited = true }
                showToast(ok ? "Added to Favorites" : "Failed to add")
            }
        }
    }
}
