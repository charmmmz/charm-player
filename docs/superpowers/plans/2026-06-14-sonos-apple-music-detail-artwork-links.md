# Sonos Apple Music Detail Artwork Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Sonos Apple Music album, artist, and playlist detail-page hero artwork open the matching Apple Music app page, while keeping expanded-player artwork links tap-only so downward drags never trigger Apple Music.

**Architecture:** Add shared Apple Music external-link primitives for resource-kind mapping, URL resolution, URL opening, and detail-artwork resource filtering. Wire the three detail views through the shared helper, and wire the expanded player through a movement-threshold gesture instead of a button-like tap target.

**Tech Stack:** Swift, SwiftUI, MusicKit, XCTest, existing `BrowseItem`, `SearchManager`, `AppleMusicFavoriteResource`, `SonosAppleMusicTrackResolver`, and `UIApplication.shared.open`.

---

## File Structure

- Modify: `SonosWidget/AppleMusicCatalogSearch.swift`
  - Add `AppleMusicExternalResourceKind`.
  - Add song-capable Apple Music URL resolution.
- Create: `SonosWidget/AppleMusicExternalLinkOpener.swift`
  - Shared `UIApplication.shared.open` wrapper with logging.
- Create: `SonosWidget/AppleMusicExternalLinkResolver.swift`
  - Resolve current song and BrowseItem resources into `AppleMusicFavoriteResource`.
  - Identify Apple Music items without trusting `cloudType` alone.
- Create: `SonosWidget/AppleMusicDetailArtworkLink.swift`
  - Filter detail-page resources by allowed type.
  - Resolve and open the Apple Music URL for detail hero artwork.
- Modify: `SonosWidget/LocalMusicDetailViews.swift`
  - Delegate the existing Local Service opener to `AppleMusicExternalLinkOpener`.
  - Disambiguate existing `appleMusicURLString(kind:)` calls after adding the new enum.
- Modify: `SonosWidget/AlbumDetailView.swift`
  - Make album hero artwork tappable only for Apple Music album resources.
- Modify: `SonosWidget/PlaylistDetailView.swift`
  - Make playlist hero artwork tappable only for Apple Music playlist resources.
- Modify: `SonosWidget/ArtistDetailView.swift`
  - Make artist hero artwork tappable only for Apple Music artist resources.
- Modify: `SonosWidget/PlayerView.swift`
  - Restore current-song artwork opening through tap-only gesture.
  - Ignore drags whose translation exceeds 8 points.
- Test: `SonosWidgetTests/AppleMusicCatalogSearchTests.swift`
  - Add enum mapping test.
- Test: `SonosWidgetTests/AppleMusicExternalLinkResolverTests.swift`
  - Add current-song and detail-resource extraction tests.

---

### Task 1: External Resource Kind And Song URL Lookup

**Files:**
- Modify: `SonosWidget/AppleMusicCatalogSearch.swift`
- Test: `SonosWidgetTests/AppleMusicCatalogSearchTests.swift`

- [x] **Step 1: Add the failing mapping test**

Add this test after `testCatalogItemContainerFlagsMatchSearchManagerFactories()`:

```swift
func testExternalResourceKindMapsFavoriteResourceTypes() {
    XCTAssertEqual(AppleMusicExternalResourceKind(.songs), .song)
    XCTAssertEqual(AppleMusicExternalResourceKind(.albums), .album)
    XCTAssertEqual(AppleMusicExternalResourceKind(.artists), .artist)
    XCTAssertEqual(AppleMusicExternalResourceKind(.playlists), .playlist)
}
```

- [x] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -quiet -project /Users/charm/Documents/Workspace/SonosWidget/SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,id=4E9A46E8-6040-4274-AC95-BB75673AA3FF' -only-testing:SonosWidgetTests/AppleMusicCatalogSearchTests/testExternalResourceKindMapsFavoriteResourceTypes
```

Expected: compile failure because `AppleMusicExternalResourceKind` does not exist.

- [x] **Step 3: Implement the resource kind and URL lookup**

Add near `AppleMusicCatalogItemType`:

```swift
enum AppleMusicExternalResourceKind: Equatable, Sendable {
    case song
    case album
    case artist
    case playlist

    init(_ favoriteResourceType: AppleMusicFavoriteResourceType) {
        switch favoriteResourceType {
        case .songs: self = .song
        case .albums: self = .album
        case .artists: self = .artist
        case .playlists: self = .playlist
        }
    }
}
```

Add to `AppleMusicCatalogSearchClient`:

```swift
func appleMusicURLString(
    kind: AppleMusicExternalResourceKind,
    catalogID: String
) async throws -> String? {
    try await ensureAuthorized()

    switch kind {
    case .song:
        var request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            equalTo: MusicItemID(catalogID)
        )
        request.limit = 1
        let response = try await request.response()
        return response.items.first?.url?.absoluteString
    case .album:
        return try await appleMusicURLString(kind: LocalMusicAppleMusicURL.Kind.album, catalogID: catalogID)
    case .artist:
        return try await appleMusicURLString(kind: LocalMusicAppleMusicURL.Kind.artist, catalogID: catalogID)
    case .playlist:
        return try await appleMusicURLString(kind: LocalMusicAppleMusicURL.Kind.playlist, catalogID: catalogID)
    }
}
```

- [x] **Step 4: Run the focused test and verify GREEN**

Run the same focused test. Expected: pass.

---

### Task 2: Shared External Link Resolver And Detail Resource Filtering

**Files:**
- Create: `SonosWidget/AppleMusicExternalLinkResolver.swift`
- Create: `SonosWidget/AppleMusicDetailArtworkLink.swift`
- Create: `SonosWidget/AppleMusicExternalLinkOpener.swift`
- Test: `SonosWidgetTests/AppleMusicExternalLinkResolverTests.swift`

- [x] **Step 1: Add failing resolver tests**

Create `SonosWidgetTests/AppleMusicExternalLinkResolverTests.swift`:

```swift
import XCTest
@testable import SonosWidget

final class AppleMusicExternalLinkResolverTests: XCTestCase {
    func testCurrentTrackResourcePrefersNowPlayingObjectID() {
        let resource = AppleMusicExternalLinkResolver.currentTrackResource(
            trackURI: "x-sonos-http:100320209999999999.mp4?sid=204&flags=8224&sn=2",
            nowPlayingObjectID: "song:1440857781"
        )

        XCTAssertEqual(resource, AppleMusicFavoriteResource(id: "1440857781", type: .songs))
    }

    func testCurrentTrackResourceFallsBackToTrackURIStoreID() {
        let resource = AppleMusicExternalLinkResolver.currentTrackResource(
            trackURI: "x-sonos-http:100320201440857781.mp4?sid=204&flags=8224&sn=2",
            nowPlayingObjectID: nil
        )

        XCTAssertEqual(resource, AppleMusicFavoriteResource(id: "1440857781", type: .songs))
    }

    func testDetailArtworkResourceAcceptsAppleMusicAlbumArtistAndPlaylist() {
        let searchManager = SearchManager()

        XCTAssertEqual(
            AppleMusicDetailArtworkLink.resource(
                from: BrowseItem(
                    id: "album:1440864059",
                    title: "Abbey Road",
                    artist: "The Beatles",
                    album: "Abbey Road",
                    uri: "x-rincon-cpcontainer:1004206calbum%3A1440864059?sid=204&flags=8300&sn=2",
                    isContainer: true,
                    serviceId: 204,
                    cloudType: "ALBUM"
                ),
                searchManager: searchManager,
                allowedTypes: [.albums]
            ),
            AppleMusicFavoriteResource(id: "1440864059", type: .albums)
        )

        XCTAssertEqual(
            AppleMusicDetailArtworkLink.resource(
                from: BrowseItem(
                    id: "10052064artist%3A909253",
                    title: "The Beatles",
                    artist: "",
                    album: "",
                    uri: "x-rincon-cpcontainer:artist%3A909253?sid=204&flags=8300&sn=2",
                    isContainer: false,
                    serviceId: 204,
                    cloudType: "ARTIST"
                ),
                searchManager: searchManager,
                allowedTypes: [.artists]
            ),
            AppleMusicFavoriteResource(id: "909253", type: .artists)
        )

        XCTAssertEqual(
            AppleMusicDetailArtworkLink.resource(
                from: BrowseItem(
                    id: "playlist:pl.u-11zBXe4t8ZL1",
                    title: "Late Night Jazz",
                    artist: "Apple Music Jazz",
                    album: "",
                    uri: "x-rincon-cpcontainer:1006206cplaylist%3Apl.u-11zBXe4t8ZL1?sid=204&flags=8300&sn=2",
                    isContainer: true,
                    serviceId: 204,
                    cloudType: "PLAYLIST"
                ),
                searchManager: searchManager,
                allowedTypes: [.playlists]
            ),
            AppleMusicFavoriteResource(id: "pl.u-11zBXe4t8ZL1", type: .playlists)
        )
    }

    func testDetailArtworkResourceRejectsNonAppleMusicAndMismatchedTypes() {
        let searchManager = SearchManager()
        let spotifyAlbum = BrowseItem(
            id: "album:spotify-album",
            title: "Other Album",
            artist: "Other Artist",
            album: "Other Album",
            uri: "x-sonos-spotify:spotify%3Aalbum%3Aabc?sid=9&flags=8300&sn=1",
            isContainer: true,
            serviceId: 9,
            cloudType: "ALBUM"
        )
        let appleMusicPlaylist = BrowseItem(
            id: "playlist:pl.u-11zBXe4t8ZL1",
            title: "Late Night Jazz",
            artist: "Apple Music Jazz",
            album: "",
            uri: "x-rincon-cpcontainer:1006206cplaylist%3Apl.u-11zBXe4t8ZL1?sid=204&flags=8300&sn=2",
            isContainer: true,
            serviceId: 204,
            cloudType: "PLAYLIST"
        )

        XCTAssertNil(
            AppleMusicDetailArtworkLink.resource(
                from: spotifyAlbum,
                searchManager: searchManager,
                allowedTypes: [.albums]
            )
        )
        XCTAssertNil(
            AppleMusicDetailArtworkLink.resource(
                from: appleMusicPlaylist,
                searchManager: searchManager,
                allowedTypes: [.albums]
            )
        )
    }
}
```

- [x] **Step 2: Run resolver tests and verify RED**

Run:

```bash
xcodebuild test -quiet -project /Users/charm/Documents/Workspace/SonosWidget/SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,id=4E9A46E8-6040-4274-AC95-BB75673AA3FF' -only-testing:SonosWidgetTests/AppleMusicExternalLinkResolverTests
```

Expected: compile failure because resolver/helper types do not exist.

- [x] **Step 3: Implement shared resolver, detail helper, and opener**

Create `AppleMusicExternalLinkResolver.swift` with current-song extraction, `resource(from:)`, `appleMusicURL(for:)`, and Apple Music source detection.

Create `AppleMusicDetailArtworkLink.swift`:

```swift
import Foundation

enum AppleMusicDetailArtworkLink {
    static func resource(
        from item: BrowseItem,
        searchManager: SearchManager,
        allowedTypes: Set<AppleMusicFavoriteResourceType>
    ) -> AppleMusicFavoriteResource? {
        guard let resource = AppleMusicExternalLinkResolver.appleMusicResource(
            from: item,
            searchManager: searchManager
        ),
              allowedTypes.contains(resource.type) else {
            return nil
        }
        return resource
    }

    @MainActor
    static func open(
        resource: AppleMusicFavoriteResource,
        title: String,
        context: String
    ) async {
        do {
            guard let url = try await AppleMusicExternalLinkResolver.appleMusicURL(for: resource) else {
                SonosLog.debug(
                    .localService,
                    "Apple Music detail artwork lookup produced no URL context=\(context) title='\(title)' id='\(resource.id)' type='\(resource.type.rawValue)'")
                return
            }
            AppleMusicExternalLinkOpener.open(url, context: "\(context) title='\(title)' id='\(resource.id)'")
        } catch {
            SonosLog.error(
                .localService,
                "Apple Music detail artwork lookup failed context=\(context) title='\(title)' id='\(resource.id)' type='\(resource.type.rawValue)' error=\(error)")
        }
    }
}
```

Create `AppleMusicExternalLinkOpener.swift` with `UIApplication.shared.open`.

- [x] **Step 4: Run resolver tests and verify GREEN**

Run the resolver tests again. Expected: pass.

---

### Task 3: Wire Album, Playlist, And Artist Hero Artwork

**Files:**
- Modify: `SonosWidget/AlbumDetailView.swift`
- Modify: `SonosWidget/PlaylistDetailView.swift`
- Modify: `SonosWidget/ArtistDetailView.swift`

- [x] **Step 1: Update `AlbumDetailView`**

Add `@State private var isOpeningAppleMusicLink = false`, an `appleMusicArtworkResource` property using `AppleMusicDetailArtworkLink.resource(... allowedTypes: [.albums])`, wrap only the hero artwork in a plain `Button` when the resource exists, and call:

```swift
await AppleMusicDetailArtworkLink.open(
    resource: resource,
    title: albumTitle,
    context: "sonos-album-artwork"
)
```

- [x] **Step 2: Update `PlaylistDetailView`**

Use the same pattern with `allowedTypes: [.playlists]` and context `sonos-playlist-artwork`.

- [x] **Step 3: Update `ArtistDetailView`**

Use the same pattern with `allowedTypes: [.artists]` and context `sonos-artist-artwork`. Preserve the circular avatar shape and existing station badge overlay.

- [x] **Step 4: Build the app target**

Run:

```bash
xcodebuild build -quiet -project /Users/charm/Documents/Workspace/SonosWidget/SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,id=4E9A46E8-6040-4274-AC95-BB75673AA3FF'
```

Expected: build succeeds.

---

### Task 4: Restore Expanded Player Song Link With Tap-Only Gesture

**Files:**
- Modify: `SonosWidget/PlayerView.swift`

- [x] **Step 1: Add player link state and resource**

Add:

```swift
@State private var isOpeningAppleMusicLink = false
private let appleMusicArtworkTapThreshold: CGFloat = 8
```

Add `currentAppleMusicTrackResource` using `AppleMusicExternalLinkResolver.currentTrackResource(trackURI:nowPlayingObjectID:)`.

- [x] **Step 2: Add tap-only gesture**

Add a helper:

```swift
private var appleMusicArtworkTapGesture: some Gesture {
    DragGesture(minimumDistance: 0)
        .onEnded { value in
            let dx = value.translation.width
            let dy = value.translation.height
            guard hypot(dx, dy) <= appleMusicArtworkTapThreshold else { return }
            openCurrentAppleMusicTrack()
        }
}
```

Attach it with `.simultaneousGesture(appleMusicArtworkTapGesture)` only when `currentAppleMusicTrackResource != nil`. Do not use `Button` for the expanded player artwork.

- [x] **Step 3: Add opener**

Add `openCurrentAppleMusicTrack()` that resolves `AppleMusicExternalLinkResolver.appleMusicURL(for:)` and opens through `AppleMusicExternalLinkOpener`.

- [x] **Step 4: Build the app target**

Run the simulator build command from Task 3. Expected: build succeeds.

---

### Task 5: Local Service Opener Reuse And Final Verification

**Files:**
- Modify: `SonosWidget/LocalMusicDetailViews.swift`
- Test: focused tests from Tasks 1 and 2

- [x] **Step 1: Reuse shared opener in Local Service**

Replace the body of `openLocalMusicAppleMusicURL(_:,context:)` with:

```swift
AppleMusicExternalLinkOpener.open(url, context: context)
```

Disambiguate any existing `appleMusicURLString(kind: .album/.artist, catalogID:)` calls as `LocalMusicAppleMusicURL.Kind.album` and `.artist` if Swift reports ambiguity.

- [x] **Step 2: Run focused tests**

Run:

```bash
xcodebuild test -quiet -project /Users/charm/Documents/Workspace/SonosWidget/SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,id=4E9A46E8-6040-4274-AC95-BB75673AA3FF' -only-testing:SonosWidgetTests/AppleMusicCatalogSearchTests -only-testing:SonosWidgetTests/AppleMusicExternalLinkResolverTests
```

Expected: both suites pass.

- [x] **Step 3: Run app build**

Run:

```bash
xcodebuild build -quiet -project /Users/charm/Documents/Workspace/SonosWidget/SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,id=4E9A46E8-6040-4274-AC95-BB75673AA3FF'
```

Expected: build succeeds.

- [ ] **Step 4: Manual device verification**

Status: deployed the final Debug build to device `AD89415F-DB55-5D1E-BEF7-F78EA165C3DD` and launched it; manual tap/drag checks remain to be performed on the physical device.

Deploy to device with:

```bash
/Users/charm/.codex/skills/ios-device-deploy/scripts/deploy_ios_device.sh --scheme SonosWidget --device AD89415F-DB55-5D1E-BEF7-F78EA165C3DD
```

Manual checks:

1. Tap expanded-player artwork on an Apple Music song and confirm Apple Music opens the song.
2. Drag the expanded player downward and confirm Apple Music does not open.
3. Open Apple Music album, artist, and playlist detail pages in Sonos and tap hero artwork.
4. Confirm equivalent non-Apple-Music detail pages do not expose the external Apple Music action.
