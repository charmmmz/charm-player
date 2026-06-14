# Sonos Apple Music Detail Artwork Links Design

## Goal

Make Sonos Apple Music album, artist, and playlist detail-page artwork reliably open the corresponding Apple Music app page, and prevent the expanded player artwork from opening Apple Music when the user is dragging the player downward to shrink or dismiss it.

## Scope

This design focuses on Sonos resource detail pages:

- `AlbumDetailView`
- `ArtistDetailView`
- `PlaylistDetailView`

The only intended detail-page interaction is tapping the large hero artwork. This pass does not add Apple Music deep links to track rows, inner list artwork, search result cards, favorite cards, Local Service grids, or the mini-player.

The expanded player fix is limited to gesture correctness: the existing current-song artwork link remains, but it should fire only for a clear tap.

## Current State

The current `Add Apple Music artwork deep links` work added a reusable `AppleMusicExternalLinkResolver`, a shared `AppleMusicExternalLinkOpener`, and first-pass artwork links. The expanded player currently opens the Apple Music song page from `currentAppleMusicTrackResource`. The detail pages use `AppleMusicExternalLinkResolver.appleMusicResource(from:searchManager:)` and call `appleMusicURL(for:)` before opening.

The current weak spots are:

- The detail-page resource path needs explicit coverage for album, artist, and playlist BrowseItems so Apple Music resources are accepted and non-Apple-Music resources are rejected.
- The three detail views still own nearly identical open logic, which makes future fixes easy to apply unevenly.
- The expanded player artwork is wrapped as a button-like interaction, so a drag gesture can end up triggering the link.

## Design

### 1. Shared Detail Artwork Link Helper

Add a small shared helper around `AppleMusicExternalLinkResolver` and `AppleMusicExternalLinkOpener`. The helper should not render UI. It should do the non-visual work that the three detail pages currently duplicate:

- Determine whether a `BrowseItem` is an Apple Music resource using `SearchManager` service hints, local service IDs, linked account metadata, and URI source fallback.
- Extract an `AppleMusicFavoriteResource` for `.albums`, `.artists`, or `.playlists`.
- Resolve the Apple Music universal link using MusicKit catalog lookup.
- Open the URL through the shared opener with a context string that identifies the surface.
- Log missing-resource, missing-URL, and lookup-failure cases without showing a scary user-facing error.

The UI views remain responsible for their artwork shape and layout:

- Albums and playlists keep square rounded artwork.
- Artists keep circular artwork and the existing station badge overlay.
- Each view keeps a local `isOpeningAppleMusicLink` state or equivalent guard to avoid duplicate taps.

The helper should have a narrow interface, for example:

```swift
enum AppleMusicDetailArtworkLink {
    static func resource(
        from item: BrowseItem,
        searchManager: SearchManager,
        allowedTypes: Set<AppleMusicFavoriteResourceType>
    ) -> AppleMusicFavoriteResource?

    @MainActor
    static func open(
        resource: AppleMusicFavoriteResource,
        title: String,
        context: String
    ) async
}
```

The exact type name can change during implementation if there is a better fit, but the boundary should remain the same: pure resource identification is separate from async URL resolution/opening.

### 2. Strong Resource Type Filtering

Each detail page should only accept the resource type that matches its page:

- `AlbumDetailView`: `.albums`
- `ArtistDetailView`: `.artists`
- `PlaylistDetailView`: `.playlists`

This avoids accidentally opening a wrong Apple Music page if Sonos metadata is malformed or if a non-Apple-Music service happens to use a similar `cloudType`.

`AppleMusicFavoriteResource.fromBrowseItem(_:)` already knows how to strip common Sonos prefixes and namespaced IDs. The new helper should reuse that parser, then apply the page-specific allowed type check.

### 3. Apple Music Source Detection

The source detector should continue to avoid trusting `cloudType` alone because `ALBUM`, `ARTIST`, and `PLAYLIST` are generic Sonos Cloud types used by multiple services.

Accept the item as Apple Music if any of these signals resolve to Apple Music:

- `searchManager.serviceDisplayHint(forFavorite:)`
- `item.serviceId` mapped through `searchManager.musicServices`
- `SharedStorage.serviceNamesByLocalSid`
- `item.serviceId` mapped to a linked cloud account display name
- `item.uri` parsed through `PlaybackSource.from(trackURI:)`

If none of these identify Apple Music, return `nil` and leave the artwork non-tappable.

### 4. Detail Page Behavior

For all three detail pages:

- If a matching Apple Music resource exists, the hero artwork is tappable.
- If no matching resource exists, the artwork remains purely visual.
- On tap, set an in-flight state, resolve the URL, open it, and clear the in-flight state.
- If URL resolution fails, log a surface-specific message and leave the page unchanged.

There should be no toast or alert for normal resolution failure. A missing Apple Music URL is not a destructive or surprising state; it just means the metadata was not sufficient.

### 5. Expanded Player Tap-Only Gesture

Replace the expanded player artwork's button-like trigger with a tap-only interaction that ignores drag movement.

The intended behavior:

- A clear tap on Apple Music current-song artwork opens the current song.
- A drag, downward shrink gesture, or dismiss gesture never opens Apple Music.
- The existing full-player drag-to-dismiss gesture remains intact.
- TV, line-in, non-Apple-Music, radio without Apple Music IDs, and unknown sources stay non-tappable.

Implementation can use either:

- A `DragGesture(minimumDistance: 0)` attached to the artwork with a small movement threshold, such as 8 points, and only trigger when the total translation stays below the threshold.
- Or a custom simultaneous gesture that records whether the pointer/finger moved past the threshold before ending.

The threshold should be small enough that intentional taps still feel immediate and large enough that normal downward player drags do not trigger a link.

### 6. Tests

Add focused unit tests for the pure resolver/helper logic:

- Apple Music album BrowseItem returns `.albums` with the expected catalog ID.
- Apple Music artist BrowseItem returns `.artists` with the expected catalog ID.
- Apple Music playlist BrowseItem returns `.playlists` with the expected catalog ID.
- A non-Apple-Music album/artist/playlist item returns `nil`.
- A mismatched allowed type returns `nil`, such as using a playlist resource on the album page.

Keep existing song resolver tests passing.

SwiftUI gesture behavior should be verified with build/device testing rather than brittle unit tests. The implementation plan should include a manual check:

1. Open the expanded player on an Apple Music song.
2. Tap the artwork and confirm it opens Apple Music.
3. Reopen the app, drag the artwork/player downward to shrink/dismiss, and confirm it does not open Apple Music.
4. Open Sonos Apple Music album, artist, and playlist detail pages and tap their hero artwork to confirm the Apple Music app opens the corresponding page.

## Non-Goals

- Do not add links to detail-page track rows or inner list artwork.
- Do not change mini-player behavior.
- Do not change Sonos playback behavior.
- Do not replace in-app album/artist text navigation with Apple Music external links.
- Do not show user-facing errors for unresolved Apple Music links.

## Risks

- Some Sonos resources may have Apple Music catalog IDs that MusicKit does not resolve in the user's storefront. The app should log this and leave the UI unchanged.
- Some existing `BrowseItem` instances may lack enough service metadata to prove they are Apple Music. The design intentionally prefers false negatives over opening the wrong service's page.
- Artist IDs can appear in Sonos metadata in several forms. Tests should include at least one namespaced or prefixed artist ID so the parser path is covered.

## Success Criteria

- Sonos Apple Music album detail hero artwork opens the matching Apple Music album page.
- Sonos Apple Music artist detail hero artwork opens the matching Apple Music artist page.
- Sonos Apple Music playlist detail hero artwork opens the matching Apple Music playlist page.
- Equivalent Spotify, unknown-service, or malformed resources do not become tappable.
- Dragging the expanded player downward does not trigger Apple Music opening.
- Existing current-song tap behavior continues to work for a normal tap.
