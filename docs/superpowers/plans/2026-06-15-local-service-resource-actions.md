# Local Service Resource Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Local Service resource browsing behave like Browse by sharing resource presentation, queue actions, playlist row artwork, and stable card tap targets.

**Architecture:** Add a small shared resource display/action layer that is UI-only, then expose a reusable Local Service Apple Music `BrowseItem` resolver from `SearchManager`. Local Service views keep their current MusicKit navigation and playback routing, but cards, rows, and long-press menus use the shared presentation and the same Sonos queue methods Browse already uses.

**Tech Stack:** Swift 6, SwiftUI, MusicKit, XCTest, Sonos LAN queue APIs through existing `SearchManager` and `SonosManager`.

---

## File Structure

- Create `SonosWidget/MusicResourcePresentation.swift`
  - Pure display/action model shared by Browse and Local Service.
  - Contains resource kind, accessory, menu action, action policy, and playlist row artwork selection helpers.
- Create `SonosWidget/MusicResourceComponents.swift`
  - Shared SwiftUI card/row labels and menu view.
  - Components receive closures and artwork views; they do not perform network work.
- Modify `SonosWidget/SearchManager.swift`
  - Promote Local Service Apple Music `BrowseItem` construction into a reusable resolver.
  - Keep `playLocalAppleMusic` behavior the same by routing through the resolver.
- Modify `SonosWidget/LocalLibraryStore.swift`
  - Add queue action helpers that wrap resolver + `playLocalAppleMusic` / `playNext` / `addToQueue`.
  - Reuse existing `runPlayback` active state and `errorMessage` path.
- Modify `SonosWidget/LocalLibraryView.swift`
  - Replace local-only card/row labels with shared labels.
  - Add Local Service context menus for play now, play next, and add to queue.
  - Wrap each horizontal card in one stable `NavigationLink` or `Button` with a single `contentShape(Rectangle())`.
- Modify `SonosWidget/LocalMusicDetailViews.swift`
  - Add artwork to playlist track rows.
  - Add long-press queue menus to album, playlist, and artist song rows.
- Modify `SonosWidget/SearchView.swift`
  - Route Browse queue menu rows through `MusicResourceContextMenu` while preserving favorite and station-only extras.
- Test `SonosWidgetTests/LocalServiceInteractionTests.swift`
  - Shared action policy tests.
  - Resolver shape tests for song, album, playlist, and station playables.
  - Artwork fallback helper tests.
- Test `SonosWidgetTests/LocalLibraryModelsTests.swift`
  - Stable shared display IDs and tap identity tests.

---

### Task 0: Baseline Guard

**Files:**
- Inspect: `SonosWidget/LocalMusicDetailViews.swift`
- Inspect: `SonosWidget/SearchManager.swift`
- Inspect: `SonosWidget.xcodeproj/project.pbxproj`

- [ ] **Step 1: Capture the current dirty tree before editing**

Run:

```bash
git status --short --branch
```

Expected: the tree is already dirty with existing app/test edits. Record that the implementation must not stage unrelated files such as `Shared/SonosLog.swift`, `SonosWidget/AlbumDetailView.swift`, `SonosWidget/AppleMusicCatalogSearch.swift`, `SonosWidget/ArtistDetailView.swift`, `SonosWidget/PlayerView.swift`, `SonosWidget/PlaylistDetailView.swift`, `SonosWidget/SonosManager.swift`, and the untracked Apple Music detail-link helper files unless later tasks explicitly modify them.

- [ ] **Step 2: Confirm file-system synchronized Xcode groups**

Run:

```bash
rg -n "PBXFileSystemSynchronizedRootGroup|PBXSourcesBuildPhase" SonosWidget.xcodeproj/project.pbxproj
```

Expected: `SonosWidget`, `Shared`, and `SonosWidgetTests` are synchronized root groups, and source build phases are empty. New Swift files placed in `SonosWidget/` and `SonosWidgetTests/` should be picked up without manually editing `project.pbxproj`.

- [ ] **Step 3: Run the narrow existing model tests**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/LocalLibraryModelsTests \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests \
  -only-testing:SonosWidgetTests/LocalServiceAppleMusicPlayableTests
```

Expected: either the selected simulator runs the tests, or Xcode reports that this simulator name is unavailable. If unavailable, run `xcrun simctl list devices available | rg "iPhone"` and reuse an available iPhone simulator name for all later test commands.

---

### Task 1: Shared Resource Presentation Model

**Files:**
- Create: `SonosWidget/MusicResourcePresentation.swift`
- Modify: `SonosWidgetTests/LocalServiceInteractionTests.swift`
- Modify: `SonosWidgetTests/LocalLibraryModelsTests.swift`

- [ ] **Step 1: Write failing tests for action policy, display identity, and artwork fallback**

Append to `SonosWidgetTests/LocalServiceInteractionTests.swift`:

```swift
func testMusicResourceActionPolicyExposesQueueActionsForQueueableSongs() {
    XCTAssertEqual(
        MusicResourceActionPolicy.actions(kind: .song, isQueueable: true),
        [.playNow, .playNext, .addToQueue]
    )
}

func testMusicResourceActionPolicyKeepsArtistsStationFocused() {
    XCTAssertEqual(
        MusicResourceActionPolicy.actions(kind: .artist, isQueueable: true, supportsStation: true),
        [.startStation]
    )
}

func testMusicResourceActionPolicyOmitsQueueActionsWhenItemCannotResolve() {
    XCTAssertEqual(
        MusicResourceActionPolicy.actions(kind: .playlist, isQueueable: false),
        [.playNow]
    )
}

func testPlaylistTrackArtworkSelectionPrefersTrackArtwork() {
    let trackURL = URL(string: "https://example.com/track.jpg")!
    let playlistURL = URL(string: "https://example.com/playlist.jpg")!

    XCTAssertEqual(
        MusicResourceArtworkSelection.preferredRowArtworkURL(primary: trackURL, fallback: playlistURL),
        trackURL
    )
}

func testPlaylistTrackArtworkSelectionFallsBackToPlaylistArtwork() {
    let playlistURL = URL(string: "https://example.com/playlist.jpg")!

    XCTAssertEqual(
        MusicResourceArtworkSelection.preferredRowArtworkURL(primary: nil, fallback: playlistURL),
        playlistURL
    )
}
```

Append to `SonosWidgetTests/LocalLibraryModelsTests.swift`:

```swift
func testMusicResourcePresentationUsesOneTapIdentityForCardRegions() {
    let resource = MusicResourcePresentation(
        id: "recommendation-playlist-pl.heavy",
        kind: .playlist,
        title: "Heavy Rotation",
        subtitle: "Apple Music for Charm",
        detail: nil,
        fallbackSystemImage: "music.note.list",
        accessory: .chevron,
        isQueueable: true
    )

    XCTAssertEqual(resource.artworkTapID, resource.id)
    XCTAssertEqual(resource.titleTapID, resource.id)
}

func testMusicResourcePresentationMapsBrowseItemKindFromCloudType() {
    let item = BrowseItem(
        id: "playlist:pl.new",
        title: "New Music",
        artist: "Apple Music",
        album: "",
        albumArtURL: nil,
        uri: "x-rincon-cpcontainer:1006206c playlist%3Apl.new?sid=204&sn=2",
        isContainer: true,
        serviceId: 204,
        cloudType: "PLAYLIST"
    )

    let resource = MusicResourcePresentation.fromBrowseItem(
        item,
        fallbackSystemImage: "music.note.list",
        accessory: .chevron
    )

    XCTAssertEqual(resource.id, "playlist:pl.new")
    XCTAssertEqual(resource.kind, .playlist)
    XCTAssertEqual(resource.title, "New Music")
    XCTAssertEqual(resource.subtitle, "Apple Music")
    XCTAssertTrue(resource.isQueueable)
}
```

- [ ] **Step 2: Run tests to verify new symbols are missing**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testMusicResourceActionPolicyExposesQueueActionsForQueueableSongs \
  -only-testing:SonosWidgetTests/LocalLibraryModelsTests/testMusicResourcePresentationUsesOneTapIdentityForCardRegions
```

Expected: build fails with errors naming missing `MusicResourceActionPolicy` and `MusicResourcePresentation`.

- [ ] **Step 3: Add the shared model**

Create `SonosWidget/MusicResourcePresentation.swift`:

```swift
import Foundation

enum MusicResourceKind: Equatable, Sendable {
    case song
    case album
    case artist
    case playlist
    case station
    case collection
    case unknown

    init(cloudType: String?) {
        switch cloudType {
        case "TRACK":
            self = .song
        case "ALBUM":
            self = .album
        case "ARTIST":
            self = .artist
        case "PLAYLIST":
            self = .playlist
        case "PROGRAM":
            self = .station
        case "COLLECTION":
            self = .collection
        default:
            self = .unknown
        }
    }
}

enum MusicResourceAccessory: Equatable, Sendable {
    case play
    case chevron
    case progress
    case none
}

enum MusicResourceMenuAction: Equatable, Hashable, Identifiable, Sendable {
    case playNow
    case playNext
    case addToQueue
    case startStation

    var id: String {
        switch self {
        case .playNow: return "play-now"
        case .playNext: return "play-next"
        case .addToQueue: return "add-to-queue"
        case .startStation: return "start-station"
        }
    }

    var title: String {
        switch self {
        case .playNow: return "Play Now"
        case .playNext: return "Play Next"
        case .addToQueue: return "Add to Queue"
        case .startStation: return "Start Station"
        }
    }

    var systemImage: String {
        switch self {
        case .playNow: return "play.fill"
        case .playNext: return "text.line.first.and.arrowtriangle.forward"
        case .addToQueue: return "text.badge.plus"
        case .startStation: return "antenna.radiowaves.left.and.right"
        }
    }
}

enum MusicResourceActionPolicy {
    static func actions(
        kind: MusicResourceKind,
        isQueueable: Bool,
        supportsStation: Bool = false
    ) -> [MusicResourceMenuAction] {
        if kind == .artist, supportsStation {
            return [.startStation]
        }

        guard isQueueable else {
            return [.playNow]
        }

        return [.playNow, .playNext, .addToQueue]
    }
}

struct MusicResourcePresentation: Identifiable, Sendable {
    let id: String
    let kind: MusicResourceKind
    let title: String
    let subtitle: String
    let detail: String?
    let fallbackSystemImage: String
    let accessory: MusicResourceAccessory
    let isQueueable: Bool

    var artworkTapID: String { id }
    var titleTapID: String { id }

    static func fromBrowseItem(
        _ item: BrowseItem,
        fallbackSystemImage: String,
        accessory: MusicResourceAccessory
    ) -> MusicResourcePresentation {
        MusicResourcePresentation(
            id: item.id,
            kind: MusicResourceKind(cloudType: item.cloudType),
            title: item.title,
            subtitle: item.artist.isEmpty ? item.album : item.artist,
            detail: item.album.isEmpty ? nil : item.album,
            fallbackSystemImage: fallbackSystemImage,
            accessory: accessory,
            isQueueable: item.uri?.isEmpty == false
        )
    }
}

enum MusicResourceArtworkSelection {
    static func preferredRowArtworkURL(primary: URL?, fallback: URL?) -> URL? {
        primary ?? fallback
    }
}
```

- [ ] **Step 4: Run model tests**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testMusicResourceActionPolicyExposesQueueActionsForQueueableSongs \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testMusicResourceActionPolicyKeepsArtistsStationFocused \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testMusicResourceActionPolicyOmitsQueueActionsWhenItemCannotResolve \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testPlaylistTrackArtworkSelectionPrefersTrackArtwork \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testPlaylistTrackArtworkSelectionFallsBackToPlaylistArtwork \
  -only-testing:SonosWidgetTests/LocalLibraryModelsTests/testMusicResourcePresentationUsesOneTapIdentityForCardRegions \
  -only-testing:SonosWidgetTests/LocalLibraryModelsTests/testMusicResourcePresentationMapsBrowseItemKindFromCloudType
```

Expected: all seven tests pass.

- [ ] **Step 5: Commit the pure shared model**

```bash
git add SonosWidget/MusicResourcePresentation.swift SonosWidgetTests/LocalServiceInteractionTests.swift SonosWidgetTests/LocalLibraryModelsTests.swift
git commit -m "feat: add shared music resource presentation model"
```

---

### Task 2: Shared Resource Components

**Files:**
- Create: `SonosWidget/MusicResourceComponents.swift`
- Modify: `SonosWidget/SearchView.swift`

- [ ] **Step 1: Add shared SwiftUI labels and menu**

Create `SonosWidget/MusicResourceComponents.swift`:

```swift
import SwiftUI

struct MusicResourceCardLabel<ArtworkContent: View>: View {
    let resource: MusicResourcePresentation
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let isDimmed: Bool
    let isLoading: Bool
    @ViewBuilder let artwork: () -> ArtworkContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                artwork()
                    .frame(width: width, height: height)

                if isLoading {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial.opacity(0.88))
                        .overlay {
                            ProgressView()
                                .tint(.white)
                        }
                }
            }
            .frame(width: width, height: height)

            Text(resource.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(height: 34, alignment: .topLeading)

            Text(resource.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .opacity(isDimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(resource.title)
    }
}

struct MusicResourceRowLabel<ArtworkContent: View>: View {
    let resource: MusicResourcePresentation
    @ViewBuilder let artwork: () -> ArtworkContent

    var body: some View {
        HStack(spacing: 12) {
            artwork()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(resource.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(resource.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let detail = resource.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            accessory
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var accessory: some View {
        switch resource.accessory {
        case .play:
            Image(systemName: "play.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 32, height: 32)
        case .progress:
            ProgressView()
                .frame(width: 32, height: 32)
        case .none:
            EmptyView()
        }
    }
}

struct MusicResourceContextMenu: View {
    let actions: [MusicResourceMenuAction]
    let perform: (MusicResourceMenuAction) -> Void

    var body: some View {
        ForEach(actions) { action in
            Button {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }
}
```

- [ ] **Step 2: Route Browse queue menu actions through the shared menu**

In `SonosWidget/SearchView.swift`, update the non-artist queue section inside `itemContextMenu(_:)` from the three explicit queue `Button`s to:

```swift
MusicResourceContextMenu(
    actions: MusicResourceActionPolicy.actions(
        kind: MusicResourceKind(cloudType: item.cloudType),
        isQueueable: item.uri != nil
    )
) { action in
    switch action {
    case .playNow:
        playItem(item)
    case .playNext:
        Task { await searchManager.playNext(item: item, manager: manager) }
    case .addToQueue:
        Task { await searchManager.addToQueue(item: item, manager: manager) }
    case .startStation:
        startStationForItem(item)
    }
}
```

Keep the existing favorite `Divider()` and favorite `Button` immediately after this shared menu.

- [ ] **Step 3: Run a Browse compile check**

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'generic/platform=iOS'
```

Expected: build succeeds. If it fails because `MusicResourceContextMenu` is unavailable to `SearchView`, confirm `MusicResourceComponents.swift` is inside the synchronized `SonosWidget/` root group and rerun.

- [ ] **Step 4: Commit shared UI primitives**

```bash
git add SonosWidget/MusicResourceComponents.swift SonosWidget/SearchView.swift
git commit -m "feat: share music resource menu and labels"
```

---

### Task 3: Reusable Local Service Queue Resolver

**Files:**
- Modify: `SonosWidget/SearchManager.swift`
- Modify: `SonosWidget/LocalLibraryStore.swift`
- Modify: `SonosWidgetTests/LocalServiceInteractionTests.swift`

- [ ] **Step 1: Write failing resolver shape tests**

Append to `SonosWidgetTests/LocalServiceInteractionTests.swift`:

```swift
@MainActor
func testLocalServiceSongResolverBuildsPlayableBrowseItem() {
    let manager = SearchManager()
    let playable = LocalServiceAppleMusicPlayable(
        kind: .song,
        catalogID: "song:1440857781",
        title: "Nikes",
        artist: "Frank Ocean",
        album: "Blonde",
        artworkURLString: "https://example.com/cover.jpg",
        duration: 312
    )

    let item = manager.localServiceBrowseItem(
        for: playable,
        cloudServiceId: "204",
        accountId: "sn_2"
    )

    XCTAssertEqual(item?.id, "song:1440857781")
    XCTAssertEqual(item?.cloudType, "TRACK")
    XCTAssertEqual(item?.title, "Nikes")
    XCTAssertEqual(item?.artist, "Frank Ocean")
    XCTAssertEqual(item?.album, "Blonde")
    XCTAssertEqual(item?.albumArtURL, "https://example.com/cover.jpg")
    XCTAssertEqual(item?.duration, 312)
    XCTAssertFalse(item?.uri?.isEmpty ?? true)
    XCTAssertFalse(item?.isContainer ?? true)
}

@MainActor
func testLocalServiceContainerResolverBuildsQueueablePlaylistItem() {
    let manager = SearchManager()
    let playable = LocalServiceAppleMusicPlayable(
        kind: .playlist,
        catalogID: "playlist:pl.new",
        title: "New Music",
        artist: "Apple Music",
        album: "",
        artworkURLString: nil,
        duration: nil
    )

    let item = manager.localServiceBrowseItem(
        for: playable,
        cloudServiceId: "204",
        accountId: "sn_2"
    )

    XCTAssertEqual(item?.id, "playlist:pl.new")
    XCTAssertEqual(item?.cloudType, "PLAYLIST")
    XCTAssertEqual(item?.favoriteCategory, .playlist)
    XCTAssertTrue(item?.isContainer ?? false)
    XCTAssertFalse(item?.uri?.isEmpty ?? true)
}

@MainActor
func testLocalServiceStationResolverBuildsProgramItem() {
    let manager = SearchManager()
    let playable = LocalServiceAppleMusicPlayable(
        kind: .station,
        catalogID: "radio:ra.1740614260",
        title: "Apple Music Chill",
        artist: "",
        album: "",
        artworkURLString: nil,
        duration: nil
    )

    let item = manager.localServiceBrowseItem(
        for: playable,
        cloudServiceId: "204",
        accountId: "sn_2"
    )

    XCTAssertEqual(item?.id, "radio:ra.1740614260")
    XCTAssertEqual(item?.cloudType, "PROGRAM")
    XCTAssertEqual(item?.favoriteCategory, .station)
    XCTAssertFalse(item?.uri?.isEmpty ?? true)
}
```

- [ ] **Step 2: Run resolver tests to verify access is still private**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testLocalServiceSongResolverBuildsPlayableBrowseItem
```

Expected: build fails because `localServiceBrowseItem` is private.

- [ ] **Step 3: Promote resolver and reuse it in play-now**

In `SonosWidget/SearchManager.swift`, change:

```swift
private func localServiceBrowseItem(
```

to:

```swift
func localServiceBrowseItem(
```

Add this method just above `playLocalAppleMusic(_:,manager:)`:

```swift
func resolveLocalAppleMusicBrowseItem(
    _ playable: LocalServiceAppleMusicPlayable,
    manager: SonosManager
) async -> BrowseItem? {
    configure(speakerIP: manager.selectedSpeaker?.playbackIP)

    guard manager.selectedSpeaker != nil else {
        errorMessage = HandoffTransferError.noSelectedSpeaker.localizedDescription
        return nil
    }

    if manager.transportBackend == .unknown {
        _ = await manager.probeBackend()
    }

    if manager.transportBackend == .cloud {
        errorMessage = SonosControlError
            .unsupportedInCloudMode(feature: "Adding Local Service items to the queue")
            .localizedDescription
        return nil
    }

    if !hasProbed {
        await probeLinkedServices()
    }
    await refreshServiceIdMappingIfNeeded()

    guard let account = linkedAccounts.first(where: { isAppleMusicAccount($0) }),
          let serviceId = account.serviceId,
          let accountId = account.accountId else {
        errorMessage = LocalServiceSonosPlaybackError.appleMusicAccountMissing.localizedDescription
        return nil
    }

    guard cloudToLocalSid[serviceId] != nil else {
        errorMessage = LocalServiceSonosPlaybackError.localServiceMappingMissing.localizedDescription
        return nil
    }

    guard let item = localServiceBrowseItem(
        for: playable,
        cloudServiceId: serviceId,
        accountId: accountId
    ), item.uri?.isEmpty == false else {
        errorMessage = LocalServiceSonosPlaybackError.noPlayableCatalogID.localizedDescription
        return nil
    }

    return item
}
```

Then replace the duplicated guard block inside `playLocalAppleMusic(_:,manager:)` with:

```swift
guard let item = await resolveLocalAppleMusicBrowseItem(playable, manager: manager) else {
    return false
}
```

Keep the existing station direct-play branch and `playNowInternal(item:manager:)` branch below that guard.

- [ ] **Step 4: Extract the Local Library playback operation and add queue action helper**

In `SonosWidget/LocalLibraryStore.swift`, replace the body of `playOnSonos(...)` with a call to a private throwing operation:

```swift
func playOnSonos(
    playable: LocalServiceAppleMusicPlayable?,
    displayID: String,
    fallbackKind: LocalServiceAppleMusicPlayable.Kind? = nil,
    fallbackTitle: String? = nil,
    fallbackArtist: String? = nil,
    fallbackAlbum: String? = nil,
    manager: SonosManager,
    searchManager: SearchManager
) async {
    await runPlayback(id: displayID) {
        try await startOnSonos(
            playable: playable,
            fallbackKind: fallbackKind,
            fallbackTitle: fallbackTitle,
            fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum,
            manager: manager,
            searchManager: searchManager
        )
    }
}
```

Add this private operation directly below `playOnSonos(...)`:

```swift
private func startOnSonos(
    playable: LocalServiceAppleMusicPlayable?,
    fallbackKind: LocalServiceAppleMusicPlayable.Kind? = nil,
    fallbackTitle: String? = nil,
    fallbackArtist: String? = nil,
    fallbackAlbum: String? = nil,
    manager: SonosManager,
    searchManager: SearchManager
) async throws {
    var didAttemptPlayback = false
    if let playable {
        didAttemptPlayback = true
        let didStart = await searchManager.playLocalAppleMusic(playable, manager: manager)
        if didStart { return }
    }

    if let fallbackKind,
       let fallbackTitle,
       let catalogPlayable = await catalogFallbackPlayable(
        kind: fallbackKind,
        title: fallbackTitle,
        artist: fallbackArtist,
        album: fallbackAlbum
       ),
       catalogPlayable.id != playable?.id {
        didAttemptPlayback = true
        let didStart = await searchManager.playLocalAppleMusic(catalogPlayable, manager: manager)
        if didStart { return }
    }

    if !didAttemptPlayback {
        throw LocalServiceSonosPlaybackError.noPlayableCatalogID
    }
    throw LocalServiceSonosPlaybackError.playbackFailed(searchManager.errorMessage)
}
```

Add this public helper below `startOnSonos(...)`:

```swift
func performSonosQueueAction(
    _ action: MusicResourceMenuAction,
    playable: LocalServiceAppleMusicPlayable?,
    displayID: String,
    fallbackKind: LocalServiceAppleMusicPlayable.Kind? = nil,
    fallbackTitle: String? = nil,
    fallbackArtist: String? = nil,
    fallbackAlbum: String? = nil,
    manager: SonosManager,
    searchManager: SearchManager
) async {
    await runPlayback(id: displayID) {
        switch action {
        case .playNow:
            try await startOnSonos(
                playable: playable,
                fallbackKind: fallbackKind,
                fallbackTitle: fallbackTitle,
                fallbackArtist: fallbackArtist,
                fallbackAlbum: fallbackAlbum,
                manager: manager,
                searchManager: searchManager
            )

        case .playNext, .addToQueue:
            let resolvedPlayable: LocalServiceAppleMusicPlayable?
            if let playable {
                resolvedPlayable = playable
            } else if let fallbackKind, let fallbackTitle {
                resolvedPlayable = await catalogFallbackPlayable(
                    kind: fallbackKind,
                    title: fallbackTitle,
                    artist: fallbackArtist,
                    album: fallbackAlbum
                )
            } else {
                resolvedPlayable = nil
            }

            guard let resolvedPlayable else {
                throw LocalServiceSonosPlaybackError.noPlayableCatalogID
            }

            guard let item = await searchManager.resolveLocalAppleMusicBrowseItem(
                resolvedPlayable,
                manager: manager
            ) else {
                throw LocalServiceSonosPlaybackError.playbackFailed(searchManager.errorMessage)
            }

            switch action {
            case .playNext:
                await searchManager.playNext(item: item, manager: manager)
            case .addToQueue:
                await searchManager.addToQueue(item: item, manager: manager)
            case .playNow, .startStation:
                break
            }

            if let message = searchManager.errorMessage {
                throw LocalServiceSonosPlaybackError.playbackFailed(message)
            }

        case .startStation:
            try await startOnSonos(
                playable: playable,
                fallbackKind: fallbackKind,
                fallbackTitle: fallbackTitle,
                fallbackArtist: fallbackArtist,
                fallbackAlbum: fallbackAlbum,
                manager: manager,
                searchManager: searchManager
            )
        }
    }
}
```

- [ ] **Step 5: Run resolver and existing playable tests**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testLocalServiceSongResolverBuildsPlayableBrowseItem \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testLocalServiceContainerResolverBuildsQueueablePlaylistItem \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testLocalServiceStationResolverBuildsProgramItem \
  -only-testing:SonosWidgetTests/LocalServiceAppleMusicPlayableTests
```

Expected: tests pass and `playLocalAppleMusic` still compiles.

- [ ] **Step 6: Commit resolver and queue action bridge**

```bash
git add SonosWidget/SearchManager.swift SonosWidget/LocalLibraryStore.swift SonosWidgetTests/LocalServiceInteractionTests.swift
git commit -m "feat: resolve local music resources for Sonos queue actions"
```

---

### Task 4: Local Service Home and Library Rows

**Files:**
- Modify: `SonosWidget/LocalLibraryView.swift`

- [ ] **Step 1: Add Local Service helpers in `LocalLibraryView`**

Inside `LocalLibraryView`, add these helpers before `card(_:)`:

```swift
private func localResource(
    id: String,
    kind: MusicResourceKind,
    title: String,
    subtitle: String,
    detail: String?,
    fallbackSystemImage: String,
    accessory: MusicResourceAccessory,
    isQueueable: Bool
) -> MusicResourcePresentation {
    MusicResourcePresentation(
        id: id,
        kind: kind,
        title: title,
        subtitle: subtitle,
        detail: detail,
        fallbackSystemImage: fallbackSystemImage,
        accessory: accessory,
        isQueueable: isQueueable
    )
}

private func resource(for item: LocalServiceCardItem) -> MusicResourcePresentation {
    localResource(
        id: item.id,
        kind: item.resourceKind,
        title: item.title,
        subtitle: item.subtitle,
        detail: nil,
        fallbackSystemImage: item.fallbackSystemImage,
        accessory: item.resourceKind == .song || item.resourceKind == .station ? .play : .chevron,
        isQueueable: item.playable != nil
    )
}

@ViewBuilder
private func localResourceContextMenu(
    playable: LocalServiceAppleMusicPlayable?,
    displayID: String,
    kind: MusicResourceKind,
    fallbackKind: LocalServiceAppleMusicPlayable.Kind?,
    fallbackTitle: String,
    fallbackArtist: String? = nil,
    fallbackAlbum: String? = nil
) -> some View {
    MusicResourceContextMenu(
        actions: MusicResourceActionPolicy.actions(
            kind: kind,
            isQueueable: playable != nil || fallbackKind != nil,
            supportsStation: kind == .artist
        )
    ) { action in
        Task {
            await store.performSonosQueueAction(
                action,
                playable: playable,
                displayID: displayID,
                fallbackKind: fallbackKind,
                fallbackTitle: fallbackTitle,
                fallbackArtist: fallbackArtist,
                fallbackAlbum: fallbackAlbum,
                manager: manager,
                searchManager: searchManager
            )
        }
    }
}
```

- [ ] **Step 2: Extend `LocalServiceCardItem` with resource kind and playable**

Inside the private `LocalServiceCardItem` enum, add:

```swift
var resourceKind: MusicResourceKind {
    switch self {
    case .song:
        return .song
    case .album:
        return .album
    case .artist:
        return .artist
    case .playlist:
        return .playlist
    case .station:
        return .station
    case .recentlyPlayed(let item):
        switch item {
        case .album: return .album
        case .playlist: return .playlist
        case .station: return .station
        @unknown default: return .unknown
        }
    case .recommendation(let item):
        switch item {
        case .album: return .album
        case .playlist: return .playlist
        case .station: return .station
        @unknown default: return .unknown
        }
    }
}

var playable: LocalServiceAppleMusicPlayable? {
    switch self {
    case .song(let song):
        return LocalServiceAppleMusicPlayable.make(song: song)
    case .album(let album):
        return LocalServiceAppleMusicPlayable.make(album: album)
    case .artist(let artist):
        return LocalServiceAppleMusicPlayable.make(artist: artist)
    case .playlist(let playlist):
        return LocalServiceAppleMusicPlayable.make(playlist: playlist)
    case .station(let station):
        return LocalServiceAppleMusicPlayable.make(station: station)
    case .recentlyPlayed(let item):
        return LocalServiceAppleMusicPlayable.make(recentlyPlayed: item)
    case .recommendation(let item):
        return LocalServiceAppleMusicPlayable.make(recommendation: item)
    }
}
```

- [ ] **Step 3: Replace `cardContent(_:)` with the shared card label**

Replace the body of `cardContent(_:)` with:

```swift
private func cardContent(_ item: LocalServiceCardItem) -> some View {
    let artworkSize = item.cardArtworkSize
    let resource = resource(for: item)
    let isLoading = store.isStartingPlayback && store.activePlaybackItemID == item.playbackID
    let isDimmed = store.isStartingPlayback && store.activePlaybackItemID != item.playbackID

    return MusicResourceCardLabel(
        resource: resource,
        width: artworkSize.width,
        height: artworkSize.height,
        cornerRadius: 8,
        isDimmed: isDimmed,
        isLoading: isLoading
    ) {
        LocalLibraryArtworkTile(
            artwork: item.artwork,
            artworkURL: item.catalogArtworkURL(using: store),
            fallbackSystemImage: item.fallbackSystemImage,
            diagnosticLabel: item.artworkDiagnosticLabel,
            artworkContentMode: LocalServiceCardArtworkMetrics.contentMode(
                isStationLike: item.isStationLike,
                maximumWidth: item.artwork?.maximumWidth,
                maximumHeight: item.artwork?.maximumHeight
            )
        )
        .id(resource.artworkTapID)
    }
    .id(resource.titleTapID)
}
```

- [ ] **Step 4: Add one stable tap target and context menu to every card wrapper**

For every `NavigationLink` and `Button` returned by `card(_:)`, `recentlyPlayedCard(_:item:)`, and `recommendationCard(_:item:)`, add:

```swift
.contentShape(Rectangle())
.contextMenu {
    localResourceContextMenu(
        playable: item.playable,
        displayID: item.playbackID,
        kind: item.resourceKind,
        fallbackKind: item.playable?.kind,
        fallbackTitle: item.title,
        fallbackArtist: item.subtitle,
        fallbackAlbum: item.title
    )
}
```

For station cards keep `.disabled(store.isStartingPlayback)` on the `Button`; the context menu still appears and will show `Play Now`, `Play Next`, and `Add to Queue` only when the station resolves to a playable item.

- [ ] **Step 5: Replace `rowContent(...)` with shared row label**

Inside `rowContent(...)`, build a resource and return `MusicResourceRowLabel`:

```swift
let resource = MusicResourcePresentation(
    id: "\(title)|\(subtitle)|\(detail ?? "")",
    kind: .unknown,
    title: title,
    subtitle: subtitle,
    detail: detail,
    fallbackSystemImage: fallbackSystemImage,
    accessory: accessory.musicResourceAccessory,
    isQueueable: false
)

return MusicResourceRowLabel(resource: resource) {
    rowArtwork(
        artwork: artwork,
        artworkURL: artworkURL,
        fallbackSystemImage: fallbackSystemImage,
        diagnosticLabel: diagnosticLabel,
        style: artworkStyle
    )
}
.padding(.horizontal)
```

Add this mapping near `LocalServiceRowAccessory`:

```swift
private extension LocalServiceRowAccessory {
    var musicResourceAccessory: MusicResourceAccessory {
        switch self {
        case .play: return .play
        case .chevron: return .chevron
        case .progress: return .progress
        }
    }
}
```

- [ ] **Step 6: Add context menus to library category rows**

For song `playRow`, album `NavigationLink`, artist `NavigationLink` or `playRow`, and playlist `NavigationLink`, add context menus using the same helper:

```swift
.contextMenu {
    localResourceContextMenu(
        playable: LocalServiceAppleMusicPlayable.make(song: song),
        displayID: song.id.rawValue,
        kind: .song,
        fallbackKind: .song,
        fallbackTitle: song.title,
        fallbackArtist: song.artistName,
        fallbackAlbum: song.albumTitle
    )
}
```

Use `.album`, `.artist`, and `.playlist` with the matching `LocalServiceAppleMusicPlayable.make(...)` call and display ID for the other category rows.

- [ ] **Step 7: Build Local Library changes**

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'generic/platform=iOS'
```

Expected: build succeeds. Confirm no changes were made to `SonosWidget.xcodeproj/project.pbxproj`.

- [ ] **Step 8: Commit Local Service home and category row updates**

```bash
git add SonosWidget/LocalLibraryView.swift
git commit -m "feat: add local service queue actions to library resources"
```

---

### Task 5: Detail Rows, Playlist Artwork, and Queue Menus

**Files:**
- Modify: `SonosWidget/LocalMusicDetailViews.swift`

- [ ] **Step 1: Update `LocalMusicTrackRow` to accept artwork**

Change the `LocalMusicTrackRow` declaration to:

```swift
private struct LocalMusicTrackRow: View {
    let track: Track
    let index: Int
    let numberStyle: LocalMusicTrackNumberStyle
    let isPlaying: Bool
    let artworkURL: URL?
    let fallbackArtworkURL: URL?
    let contextMenuActions: [MusicResourceMenuAction]
    let menuAction: (MusicResourceMenuAction) -> Void
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 12) {
                rowLeadingArtwork

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isPlaying {
                    ProgressView()
                        .frame(width: 36)
                } else {
                    Text(durationText(track.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .contextMenu {
            MusicResourceContextMenu(actions: contextMenuActions, perform: menuAction)
        }
    }

    @ViewBuilder
    private var rowLeadingArtwork: some View {
        let selectedURL = MusicResourceArtworkSelection.preferredRowArtworkURL(
            primary: artworkURL,
            fallback: fallbackArtworkURL
        )

        if let selectedURL {
            LocalMusicDetailRemoteArtworkView(
                url: selectedURL,
                diagnosticLabel: "track-row title='\(track.title)' id='\(track.id.rawValue)'"
            )
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text(trackNumber)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44, alignment: .center)
        }
    }

    private var trackNumber: String {
        LocalMusicTrackNumberLabel.text(
            trackNumber: track.trackNumber,
            index: index,
            style: numberStyle
        )
    }
}
```

- [ ] **Step 2: Update `LocalMusicSongRow` to accept queue menus**

Add these properties:

```swift
let contextMenuActions: [MusicResourceMenuAction]
let menuAction: (MusicResourceMenuAction) -> Void
```

Add this modifier to the `Button`:

```swift
.contextMenu {
    MusicResourceContextMenu(actions: contextMenuActions, perform: menuAction)
}
```

- [ ] **Step 3: Pass playlist fallback artwork to playlist track rows**

In `LocalMusicPlaylistDetailView.trackList`, update each `LocalMusicTrackRow` call to:

```swift
LocalMusicTrackRow(
    track: track,
    index: index,
    numberStyle: .listPosition,
    isPlaying: store.isStartingPlayback && store.activePlaybackItemID == track.id.rawValue,
    artworkURL: track.artwork.flatMap { LocalMusicArtworkURL.url(for: $0, shortSidePixels: 120) },
    fallbackArtworkURL: coverURL,
    contextMenuActions: MusicResourceActionPolicy.actions(kind: .song, isQueueable: true)
) { action in
    Task {
        await store.performSonosQueueAction(
            action,
            playable: LocalServiceAppleMusicPlayable.make(track: track),
            displayID: track.id.rawValue,
            fallbackKind: .song,
            fallbackTitle: track.title,
            fallbackArtist: track.artistName,
            fallbackAlbum: track.albumTitle,
            manager: manager,
            searchManager: searchManager
        )
    }
} action: {
    await store.playOnSonos(
        playable: LocalServiceAppleMusicPlayable.make(track: track),
        displayID: track.id.rawValue,
        fallbackKind: .song,
        fallbackTitle: track.title,
        fallbackArtist: track.artistName,
        fallbackAlbum: track.albumTitle,
        manager: manager,
        searchManager: searchManager
    )
}
```

- [ ] **Step 4: Pass album artwork fallback to album track rows**

In `LocalMusicAlbumDetailView.trackList`, use the same call shape as Step 3, with `numberStyle: .albumTrackNumber` and `fallbackArtworkURL: coverURL`.

- [ ] **Step 5: Add queue menus to artist song rows**

In `LocalMusicArtistDetailView.songList`, update each `LocalMusicSongRow` call to pass:

```swift
contextMenuActions: MusicResourceActionPolicy.actions(kind: .song, isQueueable: true)
```

and:

```swift
{ action in
    Task {
        await store.performSonosQueueAction(
            action,
            playable: LocalServiceAppleMusicPlayable.make(song: song),
            displayID: song.id.rawValue,
            fallbackKind: .song,
            fallbackTitle: song.title,
            fallbackArtist: song.artistName,
            fallbackAlbum: song.albumTitle,
            manager: manager,
            searchManager: searchManager
        )
    }
}
```

Keep the existing primary tap action as play-now.

- [ ] **Step 6: Run detail row model tests and build**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testPlaylistTrackArtworkSelectionPrefersTrackArtwork \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests/testPlaylistTrackArtworkSelectionFallsBackToPlaylistArtwork
```

Expected: both tests pass.

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'generic/platform=iOS'
```

Expected: build succeeds.

- [ ] **Step 7: Commit detail row queue and artwork updates**

```bash
git add SonosWidget/LocalMusicDetailViews.swift SonosWidgetTests/LocalServiceInteractionTests.swift
git commit -m "feat: add artwork and queue menus to local music detail rows"
```

---

### Task 6: Final Verification

**Files:**
- Verify: `SonosWidget/MusicResourcePresentation.swift`
- Verify: `SonosWidget/MusicResourceComponents.swift`
- Verify: `SonosWidget/SearchManager.swift`
- Verify: `SonosWidget/LocalLibraryStore.swift`
- Verify: `SonosWidget/LocalLibraryView.swift`
- Verify: `SonosWidget/LocalMusicDetailViews.swift`
- Verify: `SonosWidget/SearchView.swift`

- [ ] **Step 1: Run all local service and shared resource tests**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/LocalLibraryModelsTests \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests \
  -only-testing:SonosWidgetTests/LocalServiceAppleMusicPlayableTests \
  -only-testing:SonosWidgetTests/LocalMusicTrackNumberLabelTests
```

Expected: all selected tests pass.

- [ ] **Step 2: Run a full Debug build**

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -configuration Debug \
  -destination 'generic/platform=iOS'
```

Expected: build succeeds.

- [ ] **Step 3: Manual device verification**

Run the app on the connected iPhone and verify:

```text
1. Local Service home: long-press a Recently Played album, recommendation playlist, and station card.
2. Confirm Play Now, Play Next, and Add to Queue appear for queueable resources.
3. Tap the cover and title area of the same recommendation card; both open the same detail screen.
4. Your Library > Playlists: playlist rows show artwork.
5. Playlist detail: every track row shows track artwork or the playlist cover fallback.
6. Long-press a playlist track and use Add to Queue; the track appears in Sonos queue.
7. Browse tab: long-press an existing Browse resource and confirm Play Now, Play Next, Add to Queue, and favorite actions still work.
```

- [ ] **Step 4: Inspect final diff**

Run:

```bash
git diff --stat HEAD
git diff -- SonosWidget/MusicResourcePresentation.swift SonosWidget/MusicResourceComponents.swift SonosWidget/SearchManager.swift SonosWidget/LocalLibraryStore.swift SonosWidget/LocalLibraryView.swift SonosWidget/LocalMusicDetailViews.swift SonosWidget/SearchView.swift SonosWidgetTests/LocalServiceInteractionTests.swift SonosWidgetTests/LocalLibraryModelsTests.swift
```

Expected: diff only contains the files from this plan plus any pre-existing dirty files that were intentionally touched by these tasks. Do not stage unrelated changes.

- [ ] **Step 5: Final commit if Task commits were squashed during execution**

If the worker executed without the per-task commits above, create one feature commit:

```bash
git add SonosWidget/MusicResourcePresentation.swift SonosWidget/MusicResourceComponents.swift SonosWidget/SearchManager.swift SonosWidget/LocalLibraryStore.swift SonosWidget/LocalLibraryView.swift SonosWidget/LocalMusicDetailViews.swift SonosWidget/SearchView.swift SonosWidgetTests/LocalServiceInteractionTests.swift SonosWidgetTests/LocalLibraryModelsTests.swift
git commit -m "feat: align local service resource actions with browse"
```

Expected: commit succeeds with only the files named in the command.

---

## Self-Review

Spec coverage:

- Local Service resources expose Browse-like queue actions: Task 3 and Task 4.
- Queue actions use Browse queue path after resolving local Apple Music resources to `BrowseItem`: Task 3.
- Playlist detail rows show artwork with playlist fallback: Task 5.
- Horizontal card cover/title navigation stays tied to one item: Task 1 presentation identity and Task 4 single tap target.
- Existing Browse actions continue to work: Task 2 and Task 6 Browse manual verification.
- Relevant tests and build run: Task 1, Task 3, Task 5, and Task 6.

Placeholder scan:

- The plan names concrete files, commands, code snippets, expected results, and commit messages.

Type consistency:

- `MusicResourceMenuAction`, `MusicResourceActionPolicy`, `MusicResourcePresentation`, and `MusicResourceArtworkSelection` are defined in Task 1 before use in later tasks.
- `MusicResourceCardLabel`, `MusicResourceRowLabel`, and `MusicResourceContextMenu` are defined in Task 2 before use in Local Service views.
- `SearchManager.resolveLocalAppleMusicBrowseItem` and `LocalLibraryStore.performSonosQueueAction` are defined in Task 3 before use in Task 4 and Task 5.
