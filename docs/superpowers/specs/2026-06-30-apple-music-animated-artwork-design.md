# Apple Music Animated Artwork Design

## Goal

Show Apple Music animated album artwork inside the app's now-playing player card, then use Apple Music album detail pages as a second entry point for resolving and warming animated artwork.

The feature must remain a visual enhancement. Static artwork remains the authoritative fallback and the existing artwork pipeline continues to drive widgets, Live Activity thumbnails, Hue palette extraction, and blurred backgrounds unless a later design explicitly changes those surfaces.

## Context

The app already resolves current Apple Music playback artwork through `TrackInfo.albumArtURL`, `AppleMusicPlaybackArtworkResolver`, `PlaybackArtworkRegistry`, and relay-side artwork resolution. `PlayerView.albumArtView(size:)` renders the full player artwork from `manager.albumArtImage`, while `AlbumDetailView` already resolves Apple Music album URLs through `AppleMusicExternalLinkFallbackResolver`.

Apple's documented MusicKit and Apple Music API `Artwork` models expose static image URLs, size information, and theme colors. Animated artwork is not documented as a stable public field. Existing open-source fetchers use the Apple Music web AMP API with `extend=editorialVideo` and read fields such as:

- `attributes.editorialVideo.motionDetailSquare.video`
- `attributes.editorialVideo.motionDetailTall.video`
- playlist equivalents when available

Because this path depends on web behavior rather than a documented public API, the implementation must be optional, cached, rate-limited, and lossless to existing static artwork behavior.

Reference projects:

- `bunnykek/Fetcher`: `https://github.com/bunnykek/Fetcher`
- `m8tec/apple-music-animated-artworks`: `https://github.com/m8tec/apple-music-animated-artworks`

## Scope

### Included

- Resolve animated Apple Music album artwork through `nas-relay`.
- Add a relay API for the iOS app to request animated artwork by Apple Music album URL or by artist/album metadata.
- Add iOS relay client models and request helpers.
- Add a small app-side animated artwork registry keyed by album identity.
- Show animated artwork in the app's player card when the current track has a matching animated album artwork URL.
- Use `AlbumDetailView` to resolve and warm animated artwork for Apple Music albums.
- Provide static artwork fallback for all misses, errors, disabled states, and unsupported media sources.

### Excluded

- Widget artwork.
- Live Activity artwork.
- Dynamic Island artwork.
- Hue palette extraction from video frames.
- Replacing `TrackInfo.albumArtURL` with animated URLs.
- Downloading or transcoding animated artwork to local video files.
- Using a public third-party hosted scraper as a required dependency.

## Architecture

### 1. Relay-Owned Resolver

Add a TypeScript resolver in `nas-relay`, tentatively `animatedAppleMusicArtwork.ts`.

Inputs:

- `appleMusicUrl`: preferred when the app already has an album URL.
- `artist` + `album`: fallback for now-playing when only track metadata is known.
- `countryCode`: optional storefront hint, defaulting to `us` if the URL lacks a storefront.

Output:

```ts
interface AnimatedArtworkResolution {
  status: 'hit' | 'miss' | 'negative-cache' | 'rate-limited' | 'disabled' | 'error';
  artist: string | null;
  album: string | null;
  appleMusicUrl: string | null;
  squareUrl: string | null;
  tallUrl: string | null;
  source: 'url' | 'metadata-search' | 'cache' | 'none';
}
```

Resolver behavior:

- Parse Apple Music album URLs into storefront and album id.
- For metadata requests, first consult cache, then use conservative iTunes or Apple Music web search to find the album URL.
- Fetch a short-lived Apple Music web bearer token by loading `music.apple.com` and its JS asset, following the pattern already used by public fetchers.
- Request `https://amp-api.music.apple.com/v1/catalog/{storefront}/albums/{id}?extend=editorialVideo&platform=web`.
- Read `motionDetailSquare.video` and `motionDetailTall.video` when present.
- Treat a response without animated URLs as a cacheable miss.
- Use a single-flight lock per normalized album key to avoid duplicate concurrent scrapes.
- Keep global backoff for `403` and `429`.

The relay should not download media segments. It only returns the m3u8 URLs.

### 2. Relay Routes

Add a router under `/api/animated-artwork`.

Routes:

- `GET /api/animated-artwork/url?url=...`
- `GET /api/animated-artwork/search?artist=...&album=...&country=...`

Both routes return the same JSON envelope:

```json
{
  "ok": true,
  "status": "hit",
  "artist": "Taylor Swift",
  "album": "evermore (deluxe version)",
  "appleMusicUrl": "https://music.apple.com/us/album/evermore-deluxe-version/1547315522",
  "squareUrl": "https://...",
  "tallUrl": "https://...",
  "source": "url"
}
```

Misses still return `200` with `ok: true` and `status: "miss"` or `"negative-cache"`. Network failures return `200` with `status: "error"` unless the route itself receives invalid input, which returns `400`. This keeps the iOS UI from treating artwork absence as a user-facing failure.

### 3. Relay Cache

Persist cache in the relay data directory as JSON. Keep two related indexes:

- URL cache keyed by normalized Apple Music album URL or album id.
- Metadata alias cache keyed by normalized `artist + album`.

Cache policy:

- Hits: 30 days.
- Misses with confirmed no animated artwork: 30 days.
- Search no-match aliases: 7 days.
- Rate-limit backoff: in memory only, initially 15 minutes.

The cache stores both `squareUrl` and `tallUrl`. A cache entry with only one variant remains valid and can be refreshed opportunistically when the missing variant is requested.

### 4. iOS Relay Client

Add `RelayClient.AnimatedArtworkResponse` and helpers:

- `animatedArtworkByURL(baseURL:url:)`
- `animatedArtworkSearch(baseURL:artist:album:countryCode:)`

The client uses the existing no-proxy session and short timeouts:

- URL lookup timeout: 4 seconds.
- Metadata search timeout: 5 seconds.

The iOS side ignores non-hit statuses without surfacing errors.

### 5. App-Side Registry

Add a small `@MainActor` registry, tentatively `AnimatedArtworkRegistry`.

Keys:

- Apple Music album URL when available.
- Apple Music album catalog id when available.
- Normalized `artist + album` fallback.

Stored value:

```swift
struct AnimatedArtworkInfo: Equatable, Sendable {
    var squareURLString: String?
    var tallURLString: String?
    var appleMusicURLString: String?
    var source: Source
    var resolvedAt: Date
}
```

The registry is in-memory for the first implementation. Relay persistence gives cross-session cache, while app memory cache prevents repeated UI lookups during the current run. A later pass can persist app-side metadata if needed.

### 6. Player Card Integration

Add a small view model or local state holder for `PlayerView`, tentatively `AnimatedNowPlayingArtworkState`.

Inputs:

- `manager.trackInfo`
- `currentAppleMusicTrackURL`
- `albumBrowseItem`
- `RelayManager.shared.url` and `RelayManager.shared.isAvailable`

Lookup order:

1. Registry by album URL from `albumBrowseItem` or preloaded album detail.
2. Registry by normalized `artist + album`.
3. Relay URL lookup if an Apple Music album URL is available.
4. Relay metadata search if current source is Apple Music and artist/album are meaningful.
5. Static artwork fallback.

Rendering:

- Replace only the visible image layer inside `albumArtView(size:)` for non-TV Apple Music tracks.
- Keep the existing placeholder, source badge, TV state, sizing, transitions, and tap behavior.
- Add `AnimatedArtworkPlayerView`, implemented with `AVPlayerLayer` through `UIViewRepresentable` rather than `VideoPlayer`, so controls never appear.
- The video is muted, loops, uses aspect-fill or aspect-fit according to the current artwork layout, and pauses when the player card is not visible.
- Static `manager.albumArtImage` remains underneath until the first video frame is ready. If video loading fails, the static layer stays visible.

Playback lifecycle:

- Rebuild the `AVPlayer` only when the selected animated URL changes.
- Cancel stale lookup tasks when track identity changes.
- Stop playback on disappear.
- Respect Reduce Motion by skipping video playback and keeping static art.
- Optionally skip video when Low Power Mode is enabled.

Variant choice:

- Player card uses `squareUrl`.
- If only `tallUrl` exists, the player may use it with center crop only after verifying it does not look wrong in square framing.
- Album detail can use `tallUrl` for hero-style presentation in a later visual pass.

### 7. Album Detail Integration

Extend `AlbumDetailView` after `fallbackAppleMusicArtworkURL` is resolved.

Behavior:

- When `fallbackAppleMusicArtworkURL` becomes available, call the relay URL route.
- Store any hit in `AnimatedArtworkRegistry`.
- Do not block `loadAlbum()`, cover image loading, playback controls, or Apple Music link opening.
- Initially keep the visible album detail hero as static artwork unless the player-card implementation proves stable.

After player card support is verified, album detail can opt into video rendering:

- Use `tallUrl` for tall hero contexts.
- Use `squareUrl` for the existing square header artwork.
- Preserve the existing tap-to-open Apple Music behavior.

### 8. Settings And Feature Flag

First implementation should include a compile-time or internal static feature flag:

```swift
enum AnimatedArtworkFeature {
    static let isEnabled = true
}
```

If runtime control is needed, add a Settings toggle later. It should not be a first-pass requirement because the feature already degrades silently and only works when relay is available.

Relay should also have an environment flag, default enabled:

- `ANIMATED_ARTWORK_ENABLED=true`

If disabled, routes return `status: "disabled"` with `ok: true`.

## Error Handling

- No relay configured: static artwork only.
- Relay unreachable: static artwork only.
- AMP token extraction failure: relay returns `status: "error"` and logs at warn/debug depending on frequency.
- AMP `403` or `429`: relay enters backoff and returns `status: "rate-limited"`.
- No `editorialVideo`: cache a negative result.
- Invalid m3u8 URL: treat as miss.
- AVPlayer failure: log once per track identity and keep static artwork visible.
- Track changes during lookup: discard stale result by comparing the track identity used to start the lookup.

## Privacy And Network Behavior

Requests to Apple are made by the relay, not by iOS, so the app does not repeatedly scrape Apple endpoints from the phone. The relay sends only album URL or artist/album metadata needed for resolution.

The relay must avoid repeated scraping:

- cache hits and misses,
- single-flight per album key,
- bounded search attempts,
- backoff for rate limiting.

## Tests

### Relay Unit Tests

Add focused `node:test` coverage:

- Parses Apple Music album URLs with and without storefront.
- Extracts square and tall URLs from an AMP API fixture containing `editorialVideo`.
- Falls back cleanly when `editorialVideo` is missing.
- Stores negative cache for confirmed misses.
- Reuses positive cache without a network request.
- Applies global backoff after `403` or `429`.
- Metadata search resolves to album URL and then to animated artwork.
- Routes validate inputs and return stable JSON envelopes.

### Swift Unit Tests

Add focused tests where practical:

- `RelayClient` decodes hit, miss, rate-limited, and error responses.
- `AnimatedArtworkRegistry` key matching prefers album URL/catalog id over metadata fallback.
- Player state discards stale lookup results when track identity changes.
- Reduce Motion / disabled feature flag prevents video selection.

### Manual Verification

Use known albums with animated artwork from the public fetcher examples:

- `https://music.apple.com/us/album/evermore-deluxe-version/1547315522`
- `https://music.apple.com/us/album/planet-her-deluxe/1574004234`

Check:

1. Start a known animated Apple Music track.
2. Full player initially shows static art.
3. Animated art appears after relay resolution.
4. Switch tracks quickly; old animation does not appear on the new track.
5. Play an album with no animated art; static art remains and no repeated network loop occurs.
6. Open an Apple Music album detail page; relay cache warms for that album.
7. Return to now playing for the same album; player uses cached animated artwork.
8. Disable relay or disconnect from LAN; app remains static with no user-facing error.

## Rollout Plan

1. Implement relay resolver and cache behind `ANIMATED_ARTWORK_ENABLED`.
2. Add relay routes and tests.
3. Add Swift relay client and registry tests.
4. Add player card video layer behind `AnimatedArtworkFeature.isEnabled`.
5. Wire now-playing lookup to relay and registry.
6. Wire album detail prewarming after Apple Music album URL resolution.
7. Run relay tests, focused Swift tests, and manual player verification.

## Success Criteria

- Player card animates for known supported Apple Music albums.
- Static artwork remains unchanged for unsupported albums and non-Apple-Music sources.
- Widget, Live Activity, and Hue behavior are unchanged.
- Relay does not repeatedly scrape Apple for the same supported or unsupported album.
- Track switching cannot show stale animated artwork.
- Album detail opening can warm the cache without blocking the page.

## Design Decisions

- First visual implementation will use only the player card. Album detail will initially warm the cache and may render animation in a later pass.
- The player will prefer `squareUrl`; use of `tallUrl` inside square framing is allowed only as a fallback after visual verification.
- Runtime Settings UI is deferred until the feature proves useful enough to expose.
