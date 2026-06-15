# Album Detail Shared UI Design

## Goal

Unify the album detail presentation used by Sonos Browse albums and Local Service Apple Music albums while keeping their data loading and favorite semantics separate.

## Problem

`SonosWidget/AlbumDetailView.swift` and `SonosWidget/LocalMusicDetailViews.swift` both render an album detail page with artwork, metadata, a blurred artwork-derived background, primary playback actions, and a track list. They currently duplicate the same UI ideas while diverging in small but visible ways. The Browse album page keeps album favorite inside the top-right overflow menu, while the Local Service album page uses a separate action model and does not have an album favorite action yet.

The album favorite action has two different meanings:

- Sonos Browse albums should favorite or unfavorite the album in Sonos Favorites.
- Local Service albums should reserve the same UI position for an Apple Music favorite action implemented through MusicKit later.

Mixing those two meanings behind one generic "favorite" function would make the UI look reusable but keep the business logic ambiguous.

## Design

Create a small shared presentation layer instead of a single generic album detail screen.

The shared layer owns:

- Apple Music style album primary actions: circular Shuffle, prominent Play capsule, circular Favorite.
- A muted, darkened album theme derived from artwork dominant color.
- Overflow menu policy for album pages, where album Favorite is not shown because it lives in the primary action bar.

The existing album screens continue to own:

- Sonos Browse album loading through `SonosCloudAPI.browseAlbum`.
- Local Service album loading through MusicKit and local library lookup.
- Track row model types.
- Playback and queue behavior.
- Favorite behavior.

## Favorite Semantics

Introduce explicit favorite kinds:

- `AlbumFavoriteKind.sonos`: used by `AlbumDetailView`. The action calls existing `SearchManager.addToFavorites` and `SearchManager.removeFromFavorites`.
- `AlbumFavoriteKind.appleMusic`: used by `LocalMusicAlbumDetailView`. The action is a separate hook for future MusicKit favorite support. It must not call Sonos Favorites.

The action bar receives the favorite kind, current selected state, loading state, disabled state, and a callback. That keeps the UI shared while leaving behavior outside the component.

## Visual Direction

Match the Apple Music screenshot:

- Left action: round muted surface with Shuffle icon.
- Center action: white or near-white capsule with `play.fill` and `Play`.
- Right action: round muted surface with Favorite icon. Browse albums use `heart` or `heart.fill`; Local Service albums initially use the Apple Music favorite kind and unfilled heart until the MusicKit favorite backend exists.
- Background uses the album dominant color after saturation and brightness are reduced. The page should feel related to the artwork without becoming neon or candy-colored.

## Scope

In scope:

- Shared action policy and action bar component.
- Shared muted album theme color helper.
- Browse album page uses the shared bar and removes album Favorite from top-right overflow.
- Local Service album page uses the shared bar with Apple Music favorite semantics kept separate from Sonos favorite.
- Tests for pure policy and color behavior.

Out of scope:

- Implementing the actual Apple Music/MusicKit favorite API.
- Rewriting playlist, artist, or track detail pages.
- Unifying every track row implementation.
- Changing track row favorite menus.

## Testing

Use pure unit tests before UI changes:

- Sonos album primary actions are Shuffle, Play, Sonos Favorite.
- Local Music album primary actions are Shuffle, Play, Apple Music Favorite.
- Album overflow menu policy excludes Favorite.
- The theme color helper reduces saturation and brightness for vivid colors while preserving usable contrast for already-muted colors.

Then run the focused test target and a device or simulator build after implementation.

## Review Notes

This design intentionally avoids a large `GenericAlbumDetailView<T>` because the two pages have different model types and data flows. Small shared presentation units give most of the visual consistency benefit with less risk.
