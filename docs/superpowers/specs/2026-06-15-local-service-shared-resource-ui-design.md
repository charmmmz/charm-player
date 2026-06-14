# Local Service Shared Resource UI Design

Date: 2026-06-15

## Goal

Make Local Service resource browsing behave like Browse by sharing the same resource presentation and action model wherever practical. Users should be able to long-press Local Service resources for queue actions, playlist detail rows should show artwork, and horizontal recommendation cards should navigate to the same item whether the user taps the cover or the title.

## Current Context

Browse already has mature resource behavior around `BrowseItem`: rows and cards expose context menus with `Play Now`, `Play Next`, `Add to Queue`, and favorites actions where appropriate. Queue actions flow through `SearchManager.playNext(item:manager:)` and `SearchManager.addToQueue(item:manager:)`, which already handle LAN-only queue constraints and user-facing errors.

Local Service currently uses MusicKit models (`Song`, `Album`, `Artist`, `Playlist`, `RecentlyPlayedMusicItem`, `MusicPersonalRecommendation.Item`) plus `LocalServiceAppleMusicPlayable`. Playback works through `LocalLibraryStore.playOnSonos(...)`, which eventually calls `SearchManager.playLocalAppleMusic(...)`. That path converts a local Apple Music playable into a Sonos `BrowseItem`, but it is private to play-now behavior and is not reusable by UI menu actions.

The horizontal Local Service card bug appears in recommendation playlists: tapping a cover can navigate to a neighboring playlist while tapping the text navigates correctly. The likely cause is unstable or split hit testing in lazy horizontal cards, where artwork and text effectively behave as separate tap regions despite one visual card.

## Design

### Shared Resource Model

Introduce a shared display/action model for music resources used by both Browse and Local Service. The model should describe:

- Stable identity.
- Title, subtitle, secondary detail.
- Artwork source and fallback icon.
- Resource kind: song, album, artist, playlist, station, or unknown.
- Primary interaction: play, navigate to detail, or start station.
- Available secondary actions: play now, play next, add to queue, favorite, open externally where supported.

Browse can adapt existing `BrowseItem` values into this model. Local Service can adapt MusicKit values into the same model while retaining the original typed payload needed for detail navigation and fallback matching.

### Shared UI Components

Create shared resource card and row components for Browse and Local Service to converge on:

- `MusicResourceCard` for horizontal album/playlist/station cards.
- `MusicResourceRow` for song/detail/list rows.
- `MusicResourceContextMenu` for secondary actions.

The components should be layout-only and receive closures for actions. They must not call network APIs directly. Browse and Local Service screens remain responsible for routing to the correct action handler.

The shared card must use one stable tap target with a single `contentShape(Rectangle())`. Artwork subviews should not create separate navigation targets or intercept taps. This directly addresses the cover/title navigation split.

### Local Service Queue Actions

Expose a reusable Local Service queue item resolver that turns `LocalServiceAppleMusicPlayable` into the same Sonos-playable `BrowseItem` used by `playLocalAppleMusic`. This can live near `SearchManager` because it depends on linked Sonos service/account mapping and the cloud-to-local service ID map.

Local Service secondary actions should use this resolver and then call the same Browse queue functions:

- `Play Now`: existing `playLocalAppleMusic` behavior, via the shared action surface.
- `Play Next`: resolve to `BrowseItem`, then call `SearchManager.playNext`.
- `Add to Queue`: resolve to `BrowseItem`, then call `SearchManager.addToQueue`.

If the app is in remote/cloud mode, queue actions should surface the same LAN-required message Browse already uses. If a MusicKit item cannot be resolved to a Sonos-playable Apple Music resource, show the current Local Service friendly error rather than silently doing nothing.

### Local Service Screen Coverage

The shared row/card and context menu should cover:

- Local Service home horizontal cards: recently added, recently played, and recommendations.
- Your Library category detail rows for songs, albums, artists, and playlists.
- Album detail track rows.
- Playlist detail track rows.
- Artist detail rows where songs are displayed.

Primary tap behavior stays as it is today:

- Songs and tracks play immediately.
- Albums and playlists navigate to detail.
- Artists navigate to detail where supported.
- Stations play/start directly.

Long press exposes queue actions where a Sonos-playable item can be resolved.

### Playlist Detail Artwork

Playlist detail track rows should show artwork on every row. Prefer the row track artwork. If missing, use the playlist cover as a fallback so playlist rows still look complete. Album detail rows can reuse the same row component and may use album artwork as fallback when the track artwork is missing.

### Error Handling

Shared UI components should not own error state. Action handlers should update the existing `LocalLibraryStore.errorMessage` or `SearchManager.errorMessage` paths. While a Local Service action is in flight, reuse the existing active item state so only the active row/card shows progress and unrelated items are dimmed.

### Testing

Add focused tests for:

- Local Service MusicKit item adapters produce stable shared resource IDs and expected resource kinds.
- Local Service queue resolver produces a `BrowseItem` with non-empty URI/metadata for supported Apple Music song, album, playlist, and station playables.
- Shared action policy exposes `Play Now`, `Play Next`, and `Add to Queue` for queueable Local Service resources.
- Playlist track row artwork selection prefers track artwork and falls back to playlist artwork.
- Recommendation card identity keeps cover and title tied to the same item.

Run the smallest relevant tests plus a Debug build before implementation is considered complete.

## Non-Goals

- Reworking Browse favorites management beyond preserving current behavior.
- Changing Sonos Cloud remote queue semantics; queue insertion remains LAN-only.
- Redesigning the full Local Service home layout beyond sharing resource cards and rows.
- Changing Apple Music external-link behavior except where the shared resource model needs to carry an optional external URL.

## Acceptance Criteria

- Local Service resources offer Browse-like long-press queue actions.
- Queue actions use the same Sonos queue path as Browse after local Apple Music resources resolve to `BrowseItem`.
- Playlist detail rows show artwork.
- Tapping a Local Service horizontal card cover and title always opens or plays the same resource.
- Existing Browse actions continue to work.
- Relevant tests and Debug build pass.
