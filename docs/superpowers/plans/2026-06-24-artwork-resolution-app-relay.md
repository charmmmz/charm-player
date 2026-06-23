# Artwork Resolution App Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app prefer public CDN already present or just seen in playlist/album detail, then Apple Music MusicKit, then iTunes, before falling back to Sonos speaker `getaa`; make nas-relay independently prefer public/app-hinted/iTunes artwork before `getaa`.

**Architecture:** Keep app artwork resolution local and CDN-first: reuse public CDN URLs from the current item or in-memory detail-view registry before persistent URL cache and MusicKit, with iTunes as the final network fallback before allowing `getaa` to render. Keep nas-relay independent from MusicKit by adding an iTunes Search API resolver with bounded timeout, memory cache, and conservative Apple Music detection. Do not re-enable the previous heavy app image cache/prewarm path by default; keep lightweight registry, persistent public-CDN URL metadata, and relay artwork hints available so the app and relay can reuse CDN URLs discovered while browsing.

**Tech Stack:** Swift, SwiftUI, MusicKit, XCTest, TypeScript, Node `node:test`, Express, Sonos UPnP metadata.

---

## Scope Check

This plan covers one feature split across two cooperating surfaces:

- App playback/queue artwork resolution.
- nas-relay Live Activity artwork resolution.

The two pieces are coupled only through existing `POST /api/artwork-hints`; each task produces testable behavior on its own.

## File Structure

- Modify `SonosWidget/PlaybackArtworkPrewarmPolicy.swift`
  - Split the single disabled artwork cache/prewarm switch into narrow flags.
  - Keep heavy image prewarm and queue disk cache disabled by default.
  - Enable lightweight in-memory playback artwork registry, persistent public-CDN URL cache, and relay artwork hints independently.

- Modify `SonosWidget/SearchManager.swift`
  - Register Browse/playlist/album detail public CDN artwork in the in-memory registry even when image prewarm/cache is disabled.
  - Submit artwork hints when Browse/playlist detail data contains public CDN artwork even when image prewarm/cache is disabled.
  - Keep actual prefetch work behind the disabled prewarm flag.

- Modify `SonosWidget/SonosManager.swift`
  - Keep applying `PlaybackArtworkRegistry` replacements when loading the Sonos queue, so queue `getaa` URLs can be replaced by detail-view CDN URLs before row rendering.

- Modify `SonosWidget/AppleMusicPlaybackArtworkResolver.swift`
  - Keep `existing_public` first.
  - Prefer current-session detail registry before persistent URL cache.
  - Keep MusicKit direct before search.
  - Keep iTunes lookup/search after MusicKit and before returning nil, so queue/Now Playing only falls back to `getaa` after both MusicKit and iTunes miss.

- Modify `SonosWidgetTests/AppleMusicPlaybackArtworkResolverTests.swift`
  - Lock the app resolver order: public CDN -> registry -> persistent URL cache -> MusicKit direct -> MusicKit search -> iTunes lookup -> iTunes search -> miss/getaa visual fallback.

- Modify `SonosWidgetTests/PlaybackArtworkPrewarmTests.swift`
  - Lock registry and hint submission as separate from image prewarm/cache.

- Create `SonosWidgetTests/PlaybackArtworkRegistryTests.swift`
  - Lock Browse/detail public CDN URL reuse for queue items whose Sonos queue artwork is local `getaa`.

- Create `nas-relay/src/itunesArtwork.ts`
  - Resolve Apple artwork through iTunes lookup/search.
  - Normalize artwork URLs to `600x600bb.jpg`.
  - Score search results conservatively.

- Create `nas-relay/src/itunesArtwork.test.ts`
  - Unit tests for lookup, search, scoring, URL resizing, and unsupported input.

- Create `nas-relay/src/sonosArtworkResolver.ts`
  - Decide relay artwork source: public URL/hint -> iTunes lookup -> iTunes search -> current `getaa`.
  - Parse Apple Music catalog IDs from track URI and `getaa?u=...`.
  - Gate iTunes attempts to Apple Music-ish snapshots only.

- Create `nas-relay/src/sonosArtworkResolver.test.ts`
  - Unit tests for relay priority order and fallback behavior.

- Modify `nas-relay/src/sonos.ts`
  - Inject and call `resolveSonosArtwork(...)` after metadata is finalized and before snapshot is emitted.
  - Add structured logs for selected artwork source.

- Modify `nas-relay/src/types.ts` only if the resolver needs a small exported type for source logging.
  - Do not change APNs content-state shape unless tests prove it is necessary.

---

### Task 1: Split App Artwork Policy Flags

**Files:**
- Modify: `SonosWidget/PlaybackArtworkPrewarmPolicy.swift`
- Test: `SonosWidgetTests/PlaybackArtworkPrewarmTests.swift`
- Test: `SonosWidgetTests/PlaybackArtworkRegistryTests.swift`

- [x] **Step 1: Write failing tests for independent lightweight metadata policy**

Append these tests to `SonosWidgetTests/PlaybackArtworkPrewarmTests.swift`:

```swift
func testLightweightArtworkMetadataRemainsEnabledWhenImagePrewarmIsDisabled() {
    XCTAssertTrue(PlaybackArtworkCachingPolicy.isRegistryEnabled)
    XCTAssertTrue(PlaybackArtworkCachingPolicy.isArtworkHintsEnabled)
    XCTAssertFalse(PlaybackArtworkCachingPolicy.isPrewarmEnabled)
    XCTAssertFalse(PlaybackArtworkCachingPolicy.isQueueDiskCacheEnabled)
    XCTAssertFalse(PlaybackArtworkCachingPolicy.isPlaybackURLCacheEnabled)
}
```

Create `SonosWidgetTests/PlaybackArtworkRegistryTests.swift`:

```swift
import XCTest
@testable import SonosWidget

@MainActor
final class PlaybackArtworkRegistryTests: XCTestCase {
    func testReplacesQueueGetaaWithBrowsePublicCDNByObjectID() {
        let registry = PlaybackArtworkRegistry()
        registry.register(
            BrowseItem(
                id: "song:1440857781",
                title: "Moon",
                artist: "Daniel Caesar",
                album: "Freudian",
                albumArtURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg",
                uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
                isContainer: false,
                cloudType: "TRACK"
            )
        )
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1&u=x-sonos-http%3asong%253a1440857781.mp4%3fsid%3d204%26sn%3d2",
            uri: "x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2",
            metaXML: nil
        )

        let resolved = registry.resolvedQueueItem(queueItem)

        XCTAssertEqual(
            resolved.albumArtURL,
            "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg"
        )
    }

    func testKeepsQueueGetaaWhenBrowseArtworkIsAmbiguousForSameTrackKey() {
        let registry = PlaybackArtworkRegistry()
        registry.register(
            BrowseItem(
                id: "song:1",
                title: "Intro",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://cdn.example.com/a.jpg",
                isContainer: false,
                cloudType: "TRACK"
            )
        )
        registry.register(
            BrowseItem(
                id: "song:2",
                title: "Intro",
                artist: "Artist",
                album: "Album",
                albumArtURL: "https://cdn.example.com/b.jpg",
                isContainer: false,
                cloudType: "TRACK"
            )
        )
        let queueItem = QueueItem(
            id: "0",
            objectID: "Q:0/0",
            trackNumber: 1,
            title: "Intro",
            artist: "Artist",
            album: "Album",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
            uri: nil,
            metaXML: nil
        )

        let resolved = registry.resolvedQueueItem(queueItem)

        XCTAssertEqual(resolved.albumArtURL, "http://192.168.50.249:1400/getaa?s=1")
    }
}
```

- [x] **Step 2: Run the focused Swift tests and verify failure**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/PlaybackArtworkPrewarmTests/testLightweightArtworkMetadataRemainsEnabledWhenImagePrewarmIsDisabled \
  -only-testing:SonosWidgetTests/PlaybackArtworkRegistryTests/testReplacesQueueGetaaWithBrowsePublicCDNByObjectID \
  -only-testing:SonosWidgetTests/PlaybackArtworkRegistryTests/testKeepsQueueGetaaWhenBrowseArtworkIsAmbiguousForSameTrackKey
```

Expected: fail because `isArtworkHintsEnabled` does not exist and `isRegistryEnabled` is still disabled.

- [x] **Step 3: Implement the narrow policy flags**

Replace the top of `SonosWidget/PlaybackArtworkPrewarmPolicy.swift` with:

```swift
import Foundation

nonisolated enum PlaybackArtworkCachingPolicy {
    // Heavy artwork caches/prewarm stay disabled while queue artwork is validated.
    static let isQueueDiskCacheEnabled = false
    static let isPlaybackURLCacheEnabled = false
    static let isPrewarmEnabled = false

    // Lightweight in-memory URL metadata only. This lets Browse/detail public
    // CDN artwork replace Sonos queue getaa URLs during the current app run.
    static let isRegistryEnabled = true

    // Lightweight metadata only. This posts already-known public CDN URLs to
    // nas-relay; it does not fetch images, persist artwork, or warm disk caches.
    static let isArtworkHintsEnabled = true

}
```

Keep the existing `PlaybackArtworkPrewarmPolicy` enum below this block unchanged.

- [x] **Step 4: Run focused tests and verify pass**

Run the same `xcodebuild test` command from Step 2.

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add SonosWidget/PlaybackArtworkPrewarmPolicy.swift SonosWidgetTests/PlaybackArtworkPrewarmTests.swift SonosWidgetTests/PlaybackArtworkRegistryTests.swift
git commit -m "Split playback artwork policy flags"
```

---

### Task 2: Decouple Registry and Relay Artwork Hints From Image Prewarm

**Files:**
- Modify: `SonosWidget/SearchManager.swift`
- Test: `SonosWidgetTests/PlaybackArtworkPrewarmTests.swift`

- [x] **Step 1: Write failing tests for registry and hint scheduling**

If `PlaybackArtworkPrewarmTests.swift` already has a `SearchManager` prewarm seam, extend it. If it does not, add these pure policy tests first and then wire implementation manually:

```swift
func testPlaybackArtworkPolicyAllowsHintsWithoutPrewarm() {
    XCTAssertTrue(PlaybackArtworkCachingPolicy.isRegistryEnabled)
    XCTAssertTrue(PlaybackArtworkCachingPolicy.isArtworkHintsEnabled)
    XCTAssertFalse(PlaybackArtworkCachingPolicy.isPrewarmEnabled)
}

func testSearchManagerRegistersBrowseArtworkWithoutImagePrewarm() async {
    let uniqueID = "song:\(UUID().uuidString)"
    let urlString = "https://is1-ssl.mzstatic.com/image/thumb/Music/\(UUID().uuidString).jpg/600x600bb.jpg"
    let manager = SearchManager()
    manager.playbackArtworkPrewarmOverride = { _ in
        XCTFail("image prewarm should stay disabled")
    }
    let item = BrowseItem(
        id: uniqueID,
        title: "Unique Registry Song",
        artist: "Registry Artist",
        album: "Registry Album",
        albumArtURL: urlString,
        uri: "x-sonos-http:\(uniqueID.replacingOccurrences(of: ":", with: "%3a")).mp4?sid=204&flags=8232&sn=2",
        isContainer: false,
        cloudType: "TRACK"
    )

    await manager.prewarmPlaybackArtwork(items: [item])

    let queueItem = QueueItem(
        id: "0",
        objectID: "Q:0/0",
        trackNumber: 1,
        title: "Unique Registry Song",
        artist: "Registry Artist",
        album: "Registry Album",
        albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
        uri: "x-sonos-http:\(uniqueID.replacingOccurrences(of: ":", with: "%3a")).mp4?sid=204&flags=8232&sn=2",
        metaXML: nil
    )

    let resolved = PlaybackArtworkRegistry.shared.resolvedQueueItem(queueItem)

    XCTAssertEqual(resolved.albumArtURL, urlString)
}

func testArtworkHintBodyRejectsLocalGetaaButAcceptsPublicCDN() {
    let items = [
        BrowseItem(
            id: "song:1440857781",
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: "http://192.168.50.249:1400/getaa?s=1",
            isContainer: false,
            cloudType: "TRACK"
        ),
        BrowseItem(
            id: "song:1440857782",
            title: "Best Part",
            artist: "Daniel Caesar",
            album: "Freudian",
            albumArtURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/example.jpg/600x600bb.jpg",
            isContainer: false,
            cloudType: "TRACK"
        )
    ]

    let body = RelayClient.ArtworkHintsBody(items: items)

    XCTAssertEqual(body.hints.count, 1)
    XCTAssertEqual(body.hints.first?.title, "Best Part")
}
```

- [x] **Step 2: Run focused Swift tests and verify failure/pass baseline**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/PlaybackArtworkPrewarmTests/testPlaybackArtworkPolicyAllowsHintsWithoutPrewarm \
  -only-testing:SonosWidgetTests/PlaybackArtworkPrewarmTests/testSearchManagerRegistersBrowseArtworkWithoutImagePrewarm \
  -only-testing:SonosWidgetTests/PlaybackArtworkPrewarmTests/testArtworkHintBodyRejectsLocalGetaaButAcceptsPublicCDN
```

Expected: policy and hint body tests pass after Task 1; registry test fails until `SearchManager.prewarmPlaybackArtwork(items:)` registers items before returning for disabled prewarm. If `RelayClient.ArtworkHintsBody.hints` is inaccessible because of access control, expose a test-only count helper rather than changing production API shape.

- [x] **Step 3: Move registry and hint submission ahead of the prewarm guard**

Change `SearchManager.prewarmPlaybackArtwork(items:)` from:

```swift
func prewarmPlaybackArtwork(items: [BrowseItem]) async {
    guard PlaybackArtworkCachingPolicy.isPrewarmEnabled else {
        SonosLog.debug(
            .playbackLink,
            "Playback artwork prewarm skipped reason=cache_disabled items=\(items.count)")
        return
    }
    PlaybackArtworkRegistry.shared.register(items: items)
    let appleMusicItems = items.filter(isAppleMusicPlaybackArtworkItem)
    if !appleMusicItems.isEmpty {
        PlaybackArtworkURLCache.shared.register(
            items: appleMusicItems,
            service: .appleMusic,
            source: .sonosCloud
        )
    }
    submitArtworkHintsToRelay(items)
    await prewarmPlaybackArtwork(
        urls: PlaybackArtworkPrewarmPolicy.urls(from: items)
    )
}
```

to:

```swift
func prewarmPlaybackArtwork(items: [BrowseItem]) async {
    if PlaybackArtworkCachingPolicy.isRegistryEnabled {
        PlaybackArtworkRegistry.shared.register(items: items)
    }

    if PlaybackArtworkCachingPolicy.isArtworkHintsEnabled {
        submitArtworkHintsToRelay(items)
    }

    guard PlaybackArtworkCachingPolicy.isPrewarmEnabled else {
        SonosLog.debug(
            .playbackLink,
            "Playback artwork prewarm skipped reason=cache_disabled registry=\(PlaybackArtworkCachingPolicy.isRegistryEnabled) hints=\(PlaybackArtworkCachingPolicy.isArtworkHintsEnabled) items=\(items.count)")
        return
    }

    if PlaybackArtworkCachingPolicy.isPlaybackURLCacheEnabled {
        let appleMusicItems = items.filter(isAppleMusicPlaybackArtworkItem)
        if !appleMusicItems.isEmpty {
            PlaybackArtworkURLCache.shared.register(
                items: appleMusicItems,
                service: .appleMusic,
                source: .sonosCloud
            )
        }
    }
    await prewarmPlaybackArtwork(
        urls: PlaybackArtworkPrewarmPolicy.urls(from: items)
    )
}
```

- [x] **Step 4: Allow scheduling to run when registry or hints are enabled**

Change both `schedulePlaybackArtworkPrewarm` guards from:

```swift
guard PlaybackArtworkCachingPolicy.isPrewarmEnabled else { return }
```

to:

```swift
guard PlaybackArtworkCachingPolicy.isPrewarmEnabled
        || PlaybackArtworkCachingPolicy.isRegistryEnabled
        || PlaybackArtworkCachingPolicy.isArtworkHintsEnabled else { return }
```

This ensures Browse/playlist/album detail paths still call `prewarmPlaybackArtwork(items:)` so in-memory registry entries and relay hints can be written without image prewarm.

- [x] **Step 5: Keep container-track background browsing behind image prewarm**

Do not remove this existing guard in `prewarmContainerPlaybackArtwork(for:)`:

```swift
guard PlaybackArtworkCachingPolicy.isPrewarmEnabled else { return }
```

This is intentional. When the user is already inside playlist/album detail, `playNow(items:)` passes the displayed track `BrowseItem`s directly, so registry gets their public CDN URLs without another network browse. For a container played without opening detail, avoid doing hidden background browsing just to seed artwork metadata.

- [x] **Step 6: Run focused Swift tests**

Run the command from Step 2.

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add SonosWidget/SearchManager.swift SonosWidgetTests/PlaybackArtworkPrewarmTests.swift
git commit -m "Register playback artwork metadata without prewarm"
```

---

### Task 3: Lock App Resolver Order With iTunes Before Getaa

**Files:**
- Modify: `SonosWidget/AppleMusicPlaybackArtworkResolver.swift`
- Modify: `SonosWidgetTests/AppleMusicPlaybackArtworkResolverTests.swift`

- [x] **Step 1: Write resolver order tests**

Append to `SonosWidgetTests/AppleMusicPlaybackArtworkResolverTests.swift`:

```swift
func testExistingPublicArtworkShortCircuitsMusicKitAndITunes() async {
    let (cache, defaults, suiteName) = makeCache()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let resolver = AppleMusicPlaybackArtworkResolver(
        cache: cache,
        registryLookup: { _ in nil },
        musicKitIsAuthorized: { true },
        musicKitDirectLookup: { _, _ in XCTFail("MusicKit direct should not run for public artwork"); return nil },
        musicKitSearchLookup: { _ in XCTFail("MusicKit search should not run for public artwork"); return nil },
        iTunesLookup: { _, _ in XCTFail("iTunes lookup should not run for public artwork"); return nil },
        iTunesSearch: { _ in XCTFail("iTunes search should not run for public artwork"); return nil },
        sonosCloudArtworkLookup: { _ in XCTFail("Sonos cloud should not run for public artwork"); return nil }
    )

    let result = await resolver.resolve(
        request: PlaybackArtworkRequest(
            service: .appleMusic,
            kind: .song,
            catalogID: "1440857781",
            title: "Moon",
            artist: "Daniel Caesar",
            album: "Freudian",
            currentArtworkURLString: "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg",
            identity: .metadata(
                objectIDs: ["song:1440857781"],
                title: "Moon",
                artist: "Daniel Caesar",
                album: "Freudian"
            ),
            countryCode: "US"
        )
    )

    XCTAssertEqual(result?.source, .existingPublic)
    XCTAssertEqual(result?.urlString, "https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg")
}

func testITunesLookupRunsAfterMusicKitSearchMissAndBeforeITunesSearch() async {
    var order: [String] = []
    let (cache, defaults, suiteName) = makeCache()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let resolver = AppleMusicPlaybackArtworkResolver(
        cache: cache,
        registryLookup: { _ in nil },
        musicKitIsAuthorized: { true },
        musicKitDirectLookup: { _, _ in order.append("musicKitDirect"); return nil },
        musicKitSearchLookup: { _ in order.append("musicKitSearch"); return nil },
        iTunesLookup: { _, _ in order.append("iTunesLookup"); return "https://cdn.example.com/itunes-lookup.jpg" },
        iTunesSearch: { _ in XCTFail("search should not run after lookup hit"); return nil },
        sonosCloudArtworkLookup: { _ in nil }
    )

    let result = await resolver.resolve(request: request(catalogID: "1440857781"))

    XCTAssertEqual(order, ["musicKitDirect", "musicKitSearch", "iTunesLookup"])
    XCTAssertEqual(result?.source, .iTunesLookup)
    XCTAssertEqual(result?.urlString, "https://cdn.example.com/itunes-lookup.jpg")
}

func testITunesSearchRunsBeforeResolverMiss() async {
    var order: [String] = []
    let (cache, defaults, suiteName) = makeCache()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let resolver = AppleMusicPlaybackArtworkResolver(
        cache: cache,
        registryLookup: { _ in nil },
        musicKitIsAuthorized: { true },
        musicKitDirectLookup: { _, _ in order.append("musicKitDirect"); return nil },
        musicKitSearchLookup: { _ in order.append("musicKitSearch"); return nil },
        iTunesLookup: { _, _ in order.append("iTunesLookup"); return nil },
        iTunesSearch: { _ in order.append("iTunesSearch"); return "https://cdn.example.com/itunes-search.jpg" },
        sonosCloudArtworkLookup: { _ in order.append("sonosCloud"); return nil }
    )

    let result = await resolver.resolve(request: request(catalogID: "1440857781"))

    XCTAssertEqual(order, ["musicKitDirect", "musicKitSearch", "iTunesLookup", "iTunesSearch"])
    XCTAssertEqual(result?.source, .iTunesSearch)
    XCTAssertEqual(result?.urlString, "https://cdn.example.com/itunes-search.jpg")
}
```

- [x] **Step 2: Run focused Swift tests**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/AppleMusicPlaybackArtworkResolverTests/testExistingPublicArtworkShortCircuitsMusicKitAndITunes \
  -only-testing:SonosWidgetTests/AppleMusicPlaybackArtworkResolverTests/testITunesLookupRunsAfterMusicKitSearchMissAndBeforeITunesSearch \
  -only-testing:SonosWidgetTests/AppleMusicPlaybackArtworkResolverTests/testITunesSearchRunsBeforeResolverMiss
```

Expected: pass if the current resolver order is already correct. If it fails because iTunes does not run after MusicKit misses, restore this block in `AppleMusicPlaybackArtworkResolver.resolve(request:)` immediately after the MusicKit block and before `sonosCloudArtworkURL(request)`:

```swift
if let lookup = await iTunesLookupArtworkURL(request) {
    store(lookup, source: .iTunesLookup, request: request)
    return PlaybackArtworkResolution(urlString: lookup, source: .iTunesLookup)
}

if let searched = await iTunesSearchArtworkURL(request) {
    store(searched, source: .iTunesSearch, request: request)
    return PlaybackArtworkResolution(urlString: searched, source: .iTunesSearch)
}
```

- [x] **Step 3: Run the full resolver test file**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/AppleMusicPlaybackArtworkResolverTests
```

Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add SonosWidget/AppleMusicPlaybackArtworkResolver.swift SonosWidgetTests/AppleMusicPlaybackArtworkResolverTests.swift
git commit -m "Lock app playback artwork fallback order"
```

---

### Task 4: Add nas-relay iTunes Artwork Client

**Files:**
- Create: `nas-relay/src/itunesArtwork.ts`
- Create: `nas-relay/src/itunesArtwork.test.ts`

- [x] **Step 1: Create failing iTunes client tests**

Create `nas-relay/src/itunesArtwork.test.ts`:

```ts
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  artworkUrlFromITunesResult,
  iTunesArtworkSearchTerm,
  lookupITunesArtwork,
  searchITunesArtwork,
} from './itunesArtwork.js';

test('artworkUrlFromITunesResult resizes iTunes artwork to 600 square', () => {
  assert.equal(
    artworkUrlFromITunesResult({
      artworkUrl100: 'https://is1-ssl.mzstatic.com/image/thumb/Music/example.jpg/100x100bb.jpg',
    }),
    'https://is1-ssl.mzstatic.com/image/thumb/Music/example.jpg/600x600bb.jpg',
  );
});

test('iTunesArtworkSearchTerm includes title artist and album', () => {
  assert.equal(
    iTunesArtworkSearchTerm({ title: 'Moon', artist: 'Daniel Caesar', album: 'Freudian' }),
    'Moon Daniel Caesar Freudian',
  );
});

test('lookupITunesArtwork uses numeric catalog id and country', async () => {
  const requested: string[] = [];
  const result = await lookupITunesArtwork({
    catalogId: '1440857781',
    country: 'US',
    fetcher: async url => {
      requested.push(url.toString());
      return {
        results: [
          {
            trackId: 1440857781,
            trackName: 'Moon',
            artistName: 'Daniel Caesar',
            collectionName: 'Freudian',
            artworkUrl100: 'https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/100x100bb.jpg',
          },
        ],
      };
    },
  });

  assert.equal(requested.length, 1);
  assert.match(requested[0]!, /^https:\/\/itunes\.apple\.com\/lookup\?/);
  assert.match(requested[0]!, /id=1440857781/);
  assert.match(requested[0]!, /country=US/);
  assert.equal(result?.source, 'itunes_lookup');
  assert.equal(result?.url, 'https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg');
});

test('lookupITunesArtwork skips non numeric catalog id', async () => {
  const result = await lookupITunesArtwork({
    catalogId: 'librarytrack:p.BaUXlqoaX7',
    country: 'US',
    fetcher: async () => {
      throw new Error('fetcher should not run');
    },
  });

  assert.equal(result, null);
});

test('searchITunesArtwork returns best exact song match', async () => {
  const result = await searchITunesArtwork({
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    country: 'US',
    fetcher: async () => ({
      results: [
        {
          trackName: 'Moonlight',
          artistName: 'Other Artist',
          collectionName: 'Other Album',
          artworkUrl100: 'https://cdn.example.com/wrong/100x100bb.jpg',
        },
        {
          trackName: 'Moon',
          artistName: 'Daniel Caesar',
          collectionName: 'Freudian',
          artworkUrl100: 'https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/100x100bb.jpg',
        },
      ],
    }),
  });

  assert.equal(result?.source, 'itunes_search');
  assert.equal(result?.url, 'https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg');
});
```

- [x] **Step 2: Run relay test and verify failure**

Run:

```bash
cd nas-relay && npm test -- src/itunesArtwork.test.ts
```

Expected: fail because `itunesArtwork.ts` does not exist.

- [x] **Step 3: Implement `itunesArtwork.ts`**

Create `nas-relay/src/itunesArtwork.ts`:

```ts
export type ITunesArtworkSource = 'itunes_lookup' | 'itunes_search';

export interface ITunesArtworkResolution {
  source: ITunesArtworkSource;
  url: string;
}

export interface ITunesArtworkResult {
  wrapperType?: string;
  kind?: string;
  trackId?: number;
  trackName?: string;
  collectionName?: string;
  artistName?: string;
  artworkUrl30?: string;
  artworkUrl60?: string;
  artworkUrl100?: string;
}

interface ITunesResponse {
  results: ITunesArtworkResult[];
}

type ITunesFetcher = (url: URL) => Promise<ITunesResponse>;

const DEFAULT_TIMEOUT_MS = 2500;

export async function lookupITunesArtwork(input: {
  catalogId: string | null | undefined;
  country?: string | null;
  fetcher?: ITunesFetcher;
}): Promise<ITunesArtworkResolution | null> {
  const catalogId = input.catalogId?.trim() ?? '';
  if (!/^\d+$/.test(catalogId)) return null;

  const url = new URL('https://itunes.apple.com/lookup');
  url.searchParams.set('id', catalogId);
  url.searchParams.set('country', normalizedCountry(input.country));

  const response = await (input.fetcher ?? fetchITunesJSON)(url);
  const artworkUrl = response.results.map(artworkUrlFromITunesResult).find(Boolean);
  return artworkUrl ? { source: 'itunes_lookup', url: artworkUrl } : null;
}

export async function searchITunesArtwork(input: {
  title: string | null | undefined;
  artist?: string | null;
  album?: string | null;
  country?: string | null;
  fetcher?: ITunesFetcher;
}): Promise<ITunesArtworkResolution | null> {
  const term = iTunesArtworkSearchTerm(input);
  if (!term) return null;

  const url = new URL('https://itunes.apple.com/search');
  url.searchParams.set('term', term);
  url.searchParams.set('media', 'music');
  url.searchParams.set('entity', 'song');
  url.searchParams.set('limit', '5');
  url.searchParams.set('country', normalizedCountry(input.country));

  const response = await (input.fetcher ?? fetchITunesJSON)(url);
  const match = response.results
    .filter(result => artworkUrlFromITunesResult(result))
    .sort((a, b) => scoreITunesResult(b, input) - scoreITunesResult(a, input))[0];
  const artworkUrl = artworkUrlFromITunesResult(match);
  return artworkUrl ? { source: 'itunes_search', url: artworkUrl } : null;
}

export function iTunesArtworkSearchTerm(input: {
  title: string | null | undefined;
  artist?: string | null;
  album?: string | null;
}): string {
  return [input.title, input.artist, input.album]
    .map(value => value?.trim() ?? '')
    .filter(Boolean)
    .join(' ');
}

export function artworkUrlFromITunesResult(result: ITunesArtworkResult | null | undefined): string | null {
  const raw = result?.artworkUrl100 ?? result?.artworkUrl60 ?? result?.artworkUrl30;
  if (!raw) return null;
  try {
    const url = new URL(raw.replace(/\/\d+x\d+bb(\.[a-z0-9]+)?$/i, '/600x600bb.jpg'));
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
    return url.toString();
  } catch {
    return null;
  }
}

function scoreITunesResult(
  result: ITunesArtworkResult,
  target: { title: string | null | undefined; artist?: string | null; album?: string | null },
): number {
  let score = 0;
  if (normalized(result.trackName) === normalized(target.title)) score += 4;
  if (normalized(result.artistName) === normalized(target.artist)) score += 3;
  if (normalized(result.collectionName) === normalized(target.album)) score += 2;
  if ((result.wrapperType ?? '').toLowerCase() === 'track') score += 1;
  return score;
}

function normalized(value: string | null | undefined): string {
  return (value ?? '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');
}

function normalizedCountry(country: string | null | undefined): string {
  const value = country?.trim().toUpperCase() ?? '';
  return /^[A-Z]{2}$/.test(value) ? value : 'US';
}

async function fetchITunesJSON(url: URL): Promise<ITunesResponse> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error(`iTunes request failed with HTTP ${response.status}`);
    return await response.json() as ITunesResponse;
  } finally {
    clearTimeout(timeout);
  }
}
```

- [x] **Step 4: Run relay iTunes tests**

Run:

```bash
cd nas-relay && npm test -- src/itunesArtwork.test.ts
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add nas-relay/src/itunesArtwork.ts nas-relay/src/itunesArtwork.test.ts
git commit -m "Add relay iTunes artwork lookup"
```

---

### Task 5: Add nas-relay Artwork Resolution Chain

**Files:**
- Create: `nas-relay/src/sonosArtworkResolver.ts`
- Create: `nas-relay/src/sonosArtworkResolver.test.ts`

- [x] **Step 1: Create failing resolver tests**

Create `nas-relay/src/sonosArtworkResolver.test.ts`:

```ts
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { resolveSonosArtwork, catalogIdFromSonosValues } from './sonosArtworkResolver.js';

test('catalogIdFromSonosValues reads Apple Music id from track uri', () => {
  assert.equal(
    catalogIdFromSonosValues([
      'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    ]),
    '1440857781',
  );
});

test('catalogIdFromSonosValues reads Apple Music id from getaa u query', () => {
  assert.equal(
    catalogIdFromSonosValues([
      'http://192.168.50.249:1400/getaa?s=1&u=x-sonos-http%3Asong%253A1440857781.mp4%3Fsid%3D204%26flags%3D8232%26sn%3D2',
    ]),
    '1440857781',
  );
});

test('resolveSonosArtwork keeps existing public artwork', async () => {
  const result = await resolveSonosArtwork({
    currentArtworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/Music/current.jpg/600x600bb.jpg',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    hintResolver: () => 'https://cdn.example.com/hint.jpg',
    lookupITunes: async () => { throw new Error('lookup should not run'); },
    searchITunes: async () => { throw new Error('search should not run'); },
  });

  assert.deepEqual(result, {
    url: 'https://is1-ssl.mzstatic.com/image/thumb/Music/current.jpg/600x600bb.jpg',
    source: 'existing_public',
  });
});

test('resolveSonosArtwork uses hint before iTunes', async () => {
  const result = await resolveSonosArtwork({
    currentArtworkUrl: 'http://192.168.50.249:1400/getaa?s=1',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    hintResolver: () => 'https://cdn.example.com/hint.jpg',
    lookupITunes: async () => { throw new Error('lookup should not run'); },
    searchITunes: async () => { throw new Error('search should not run'); },
  });

  assert.deepEqual(result, { url: 'https://cdn.example.com/hint.jpg', source: 'hint' });
});

test('resolveSonosArtwork uses iTunes lookup before search', async () => {
  const result = await resolveSonosArtwork({
    currentArtworkUrl: 'http://192.168.50.249:1400/getaa?s=1',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    hintResolver: () => null,
    lookupITunes: async input => {
      assert.equal(input.catalogId, '1440857781');
      return { source: 'itunes_lookup', url: 'https://cdn.example.com/lookup.jpg' };
    },
    searchITunes: async () => { throw new Error('search should not run after lookup hit'); },
  });

  assert.deepEqual(result, { url: 'https://cdn.example.com/lookup.jpg', source: 'itunes_lookup' });
});

test('resolveSonosArtwork falls back to getaa after iTunes miss', async () => {
  const result = await resolveSonosArtwork({
    currentArtworkUrl: 'http://192.168.50.249:1400/getaa?s=1',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    hintResolver: () => null,
    lookupITunes: async () => null,
    searchITunes: async () => null,
  });

  assert.deepEqual(result, {
    url: 'http://192.168.50.249:1400/getaa?s=1',
    source: 'getaa',
  });
});

test('resolveSonosArtwork avoids iTunes for non Apple Music getaa', async () => {
  const result = await resolveSonosArtwork({
    currentArtworkUrl: 'http://192.168.50.249:1400/getaa?s=1&u=x-rincon-cpcontainer%3Aspotify%3Atrack',
    trackUri: 'x-rincon-cpcontainer:spotify:track',
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    hintResolver: () => null,
    lookupITunes: async () => { throw new Error('lookup should not run'); },
    searchITunes: async () => { throw new Error('search should not run'); },
  });

  assert.deepEqual(result, {
    url: 'http://192.168.50.249:1400/getaa?s=1&u=x-rincon-cpcontainer%3Aspotify%3Atrack',
    source: 'getaa',
  });
});
```

- [x] **Step 2: Run resolver tests and verify failure**

Run:

```bash
cd nas-relay && npm test -- src/sonosArtworkResolver.test.ts
```

Expected: fail because `sonosArtworkResolver.ts` does not exist.

- [x] **Step 3: Implement `sonosArtworkResolver.ts`**

Create `nas-relay/src/sonosArtworkResolver.ts`:

```ts
import type { ITunesArtworkResolution } from './itunesArtwork.js';
import { lookupITunesArtwork, searchITunesArtwork } from './itunesArtwork.js';
import type { ArtworkHintLookup } from './artworkHints.js';
import { isLocalSonosArtworkUrl } from './artworkHints.js';

export type SonosArtworkSource = 'existing_public' | 'hint' | 'itunes_lookup' | 'itunes_search' | 'getaa' | 'missing';

export interface ResolvedSonosArtwork {
  url: string | null;
  source: SonosArtworkSource;
}

type HintResolver = (lookup: ArtworkHintLookup) => string | null;

export async function resolveSonosArtwork(input: {
  currentArtworkUrl: string | null | undefined;
  trackUri: string | null | undefined;
  title: string | null | undefined;
  artist: string | null | undefined;
  album: string | null | undefined;
  country?: string | null;
  hintResolver?: HintResolver;
  lookupITunes?: (input: { catalogId: string | null | undefined; country?: string | null }) => Promise<ITunesArtworkResolution | null>;
  searchITunes?: (input: { title: string | null | undefined; artist?: string | null; album?: string | null; country?: string | null }) => Promise<ITunesArtworkResolution | null>;
}): Promise<ResolvedSonosArtwork> {
  const current = clean(input.currentArtworkUrl);
  if (current && isPublicArtworkUrl(current)) {
    return { url: current, source: 'existing_public' };
  }

  const hint = input.hintResolver?.({
    title: input.title,
    artist: input.artist,
    album: input.album,
    objectIds: [input.trackUri],
    currentArtworkUrl: current,
  }) ?? null;
  if (hint && isPublicArtworkUrl(hint)) {
    return { url: hint, source: 'hint' };
  }

  if (isAppleMusicish(input.trackUri, current)) {
    const catalogId = catalogIdFromSonosValues([input.trackUri, current]);
    const lookup = await (input.lookupITunes ?? lookupITunesArtwork)({
      catalogId,
      country: input.country,
    });
    if (lookup?.url) return { url: lookup.url, source: lookup.source };

    const search = await (input.searchITunes ?? searchITunesArtwork)({
      title: input.title,
      artist: input.artist,
      album: input.album,
      country: input.country,
    });
    if (search?.url) return { url: search.url, source: search.source };
  }

  if (current) return { url: current, source: isLocalSonosArtworkUrl(current) ? 'getaa' : 'existing_public' };
  return { url: null, source: 'missing' };
}

export function catalogIdFromSonosValues(values: Array<string | null | undefined>): string | null {
  for (const value of values) {
    for (const candidate of decodedCandidates(value)) {
      const match = candidate.match(/song[:%3a]+(\d+)(?:\.mp4|\.m4a|\.aac|\.mp3)?/i)
        ?? candidate.match(/(?:^|[/:])(\d{6,})(?:\.mp4|\.m4a|\.aac|\.mp3)(?:$|[?&])/i);
      if (match?.[1]) return match[1];
    }
  }
  return null;
}

function isAppleMusicish(trackUri: string | null | undefined, artworkUrl: string | null | undefined): boolean {
  return decodedCandidates(trackUri).concat(decodedCandidates(artworkUrl)).some(value => {
    const lower = value.toLowerCase();
    return lower.includes('sid=204')
      || lower.includes('x-sonos-http:song')
      || lower.includes('song%3a');
  });
}

function isPublicArtworkUrl(value: string): boolean {
  if (isLocalSonosArtworkUrl(value)) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'http:' || url.protocol === 'https:';
  } catch {
    return false;
  }
}

function decodedCandidates(value: string | null | undefined): string[] {
  const initial = clean(value);
  if (!initial) return [];
  const values = [initial];
  for (let index = 0; index < 2; index += 1) {
    const previous = values[values.length - 1]!;
    try {
      const decoded = decodeURIComponent(previous);
      if (decoded === previous) break;
      values.push(decoded);
    } catch {
      break;
    }
  }
  return values;
}

function clean(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? '';
  return trimmed ? trimmed : null;
}
```

- [x] **Step 4: Run relay resolver tests**

Run:

```bash
cd nas-relay && npm test -- src/sonosArtworkResolver.test.ts
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add nas-relay/src/sonosArtworkResolver.ts nas-relay/src/sonosArtworkResolver.test.ts
git commit -m "Add relay artwork fallback chain"
```

---

### Task 6: Wire Relay Artwork Resolver Into Sonos Snapshots

**Files:**
- Modify: `nas-relay/src/sonos.ts`
- Modify: `nas-relay/src/sonos.test.ts`

- [x] **Step 1: Add a snapshot integration test**

Add this focused test to `nas-relay/src/sonos.test.ts` near the other `SonosBridge` snapshot tests:

```ts
test('SonosBridge applies relay artwork resolver before publishing snapshot', async () => {
  const resolvedURL = 'https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg';
  const resolverInputs: Array<{
    currentArtworkUrl: string | null | undefined;
    trackUri: string | null | undefined;
    title: string | null | undefined;
    artist: string | null | undefined;
    album: string | null | undefined;
  }> = [];
  const bridge = new SonosBridge(pino({ enabled: false }), {
    localControl: null,
    artworkResolver: async input => {
      resolverInputs.push(input);
      return { url: resolvedURL, source: 'itunes_lookup' };
    },
  });
  const device = playbackDevice({
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'RINCON_804AF2200FD601400',
  }, genericAppleMusicPositionInfo());

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<void>;
  }).refreshSnapshot(device);

  assert.equal(resolverInputs.length, 1);
  assert.equal(resolverInputs[0]!.trackUri, 'x-sonos-http:song%3a1839352407.mp4?sid=204&flags=8232&sn=2');
  assert.equal(resolverInputs[0]!.title, 'Call On Me');
  assert.equal(resolverInputs[0]!.artist, 'Daniel Caesar');
  assert.equal(resolverInputs[0]!.album, 'Son of Spergy');
  assert.match(
    resolverInputs[0]!.currentArtworkUrl ?? '',
    /^http:\/\/192\.168\.50\.25:1400\/getaa\?s=1&u=x-sonos-http/,
  );

  const snapshot = bridge.current('192.168.50.25');
  assert.equal(snapshot?.albumArtUri, resolvedURL);
});
```

- [x] **Step 2: Run the integration test and verify failure**

Run:

```bash
cd nas-relay && npm test -- src/sonos.test.ts
```

Expected: fail because `SonosBridge` does not yet call an injected artwork resolver.

- [x] **Step 3: Add resolver dependency to `SonosBridge` options**

In `nas-relay/src/sonos.ts`, import:

```ts
import { resolveSonosArtwork, type ResolvedSonosArtwork } from './sonosArtworkResolver.js';
```

Extend the `SonosBridge` options type with:

```ts
artworkResolver?: (input: {
  currentArtworkUrl: string | null | undefined;
  trackUri: string | null | undefined;
  title: string | null | undefined;
  artist: string | null | undefined;
  album: string | null | undefined;
  country?: string | null;
  hintResolver?: (lookup: ArtworkHintLookup) => string | null;
}) => Promise<ResolvedSonosArtwork>;
```

Store it as:

```ts
private readonly artworkResolver: NonNullable<SonosBridgeOptions['artworkResolver']>;
```

Initialize it:

```ts
this.artworkResolver = options.artworkResolver ?? resolveSonosArtwork;
```

- [x] **Step 4: Replace inline hint-only logic with resolver call**

After `heldPreviousLiveMetadata` is applied and before the snapshot object is built, replace the current `artworkHints?.resolve(...)` block with:

```ts
const resolvedArtwork = await this.artworkResolver({
  currentArtworkUrl: albumArtUri,
  trackUri,
  title: trackTitle,
  artist,
  album,
  country: process.env.SONOS_RELAY_ITUNES_COUNTRY ?? 'US',
  hintResolver: lookup => this.artworkHints?.resolve(lookup) ?? null,
});
if (resolvedArtwork.url !== albumArtUri) {
  this.log.debug(
    {
      groupId: resolvedGroupId,
      trigger,
      title: trackTitle,
      artist,
      album,
      artworkSource: resolvedArtwork.source,
      previousAlbumArtUri: summarizeAlbumArtUri(albumArtUri),
      resolvedAlbumArtUri: summarizeAlbumArtUri(resolvedArtwork.url),
    },
    'snapshot album art resolved',
  );
}
albumArtUri = resolvedArtwork.url;
```

If `resolveSnapshot` currently has cancellation checks after metadata calls, keep the same pattern: after the `await this.artworkResolver(...)` call, check `if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;`.

- [x] **Step 5: Run relay tests**

Run:

```bash
cd nas-relay && npm test -- src/sonosArtworkResolver.test.ts src/itunesArtwork.test.ts src/sonos.test.ts
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add nas-relay/src/sonos.ts nas-relay/src/sonos.test.ts
git commit -m "Resolve relay snapshot artwork before getaa"
```

---

### Task 7: Add Bounded Relay Artwork Cache and Negative Cache

**Files:**
- Modify: `nas-relay/src/itunesArtwork.ts`
- Modify: `nas-relay/src/itunesArtwork.test.ts`

Implementation note: the cache lives at the iTunes client boundary, so lookup/search hits and misses are shared by every relay artwork resolver call without caching speaker-local `getaa` URLs as final artwork.

- [x] **Step 1: Add failing cache tests**

Append to `nas-relay/src/sonosArtworkResolver.test.ts`:

```ts
test('resolveSonosArtwork de-duplicates repeated iTunes lookup for same catalog id', async () => {
  let lookupCount = 0;
  const input = {
    currentArtworkUrl: 'http://192.168.50.249:1400/getaa?s=1',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    hintResolver: () => null,
    lookupITunes: async () => {
      lookupCount += 1;
      return { source: 'itunes_lookup' as const, url: 'https://cdn.example.com/lookup.jpg' };
    },
    searchITunes: async () => null,
  };

  const first = await resolveSonosArtwork(input);
  const second = await resolveSonosArtwork(input);

  assert.equal(first.url, 'https://cdn.example.com/lookup.jpg');
  assert.equal(second.url, 'https://cdn.example.com/lookup.jpg');
  assert.equal(lookupCount, 1);
});

test('resolveSonosArtwork caches misses so getaa fallback does not search repeatedly', async () => {
  let lookupCount = 0;
  let searchCount = 0;
  const input = {
    currentArtworkUrl: 'http://192.168.50.249:1400/getaa?s=1',
    trackUri: 'x-sonos-http:song%3a1440857782.mp4?sid=204&flags=8232&sn=2',
    title: 'No Match',
    artist: 'No Artist',
    album: 'No Album',
    hintResolver: () => null,
    lookupITunes: async () => {
      lookupCount += 1;
      return null;
    },
    searchITunes: async () => {
      searchCount += 1;
      return null;
    },
  };

  await resolveSonosArtwork(input);
  await resolveSonosArtwork(input);

  assert.equal(lookupCount, 1);
  assert.equal(searchCount, 1);
});
```

- [x] **Step 2: Run resolver tests and verify failure**

Run:

```bash
cd nas-relay && npm test -- src/sonosArtworkResolver.test.ts
```

Expected: fail because repeated calls currently invoke lookup/search repeatedly.

- [x] **Step 3: Add small in-memory resolution cache**

In `sonosArtworkResolver.ts`, add module-level cache:

```ts
const MAX_RESOLUTION_CACHE_ENTRIES = 500;
const RESOLUTION_CACHE_TTL_MS = 6 * 60 * 60 * 1000;

interface CacheEntry {
  resolved: ResolvedSonosArtwork;
  expiresAt: number;
}

const resolutionCache = new Map<string, CacheEntry>();
```

At the top of `resolveSonosArtwork`, after `current` is computed and before iTunes calls, compute:

```ts
const cacheKey = resolutionCacheKey({
  currentArtworkUrl: current,
  trackUri: input.trackUri,
  title: input.title,
  artist: input.artist,
  album: input.album,
});
const cached = cacheKey ? resolutionCache.get(cacheKey) : undefined;
if (cached && cached.expiresAt > Date.now()) {
  return cached.resolved;
}
```

Before each return after hint/iTunes/getaa/missing resolution, call:

```ts
rememberResolution(cacheKey, resolved);
return resolved;
```

Add helpers:

```ts
function rememberResolution(key: string | null, resolved: ResolvedSonosArtwork): void {
  if (!key) return;
  resolutionCache.set(key, {
    resolved,
    expiresAt: Date.now() + RESOLUTION_CACHE_TTL_MS,
  });
  while (resolutionCache.size > MAX_RESOLUTION_CACHE_ENTRIES) {
    const oldest = resolutionCache.keys().next().value;
    if (oldest === undefined) return;
    resolutionCache.delete(oldest);
  }
}

function resolutionCacheKey(input: {
  currentArtworkUrl: string | null;
  trackUri: string | null | undefined;
  title: string | null | undefined;
  artist: string | null | undefined;
  album: string | null | undefined;
}): string | null {
  const catalogId = catalogIdFromSonosValues([input.trackUri, input.currentArtworkUrl]);
  if (catalogId) return `catalog:${catalogId}`;
  const title = normalizedCacheText(input.title);
  const artist = normalizedCacheText(input.artist);
  const album = normalizedCacheText(input.album);
  if (title && artist && album) return `track:${title}|${artist}|${album}`;
  return input.currentArtworkUrl ? `art:${input.currentArtworkUrl}` : null;
}

function normalizedCacheText(value: string | null | undefined): string {
  return (value ?? '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');
}
```

- [x] **Step 4: Run resolver tests**

Run:

```bash
cd nas-relay && npm test -- src/sonosArtworkResolver.test.ts
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add nas-relay/src/sonosArtworkResolver.ts nas-relay/src/sonosArtworkResolver.test.ts
git commit -m "Cache relay artwork resolutions"
```

---

### Task 8: Verification and Manual Diagnostics

**Files:**
- No production code unless tests reveal a compile issue.

- [x] **Step 1: Run app artwork tests**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/AppleMusicPlaybackArtworkResolverTests \
  -only-testing:SonosWidgetTests/QueueArtworkLoadPolicyTests \
  -only-testing:SonosWidgetTests/PlaybackArtworkPrewarmTests
```

Expected: pass.

- [x] **Step 2: Run relay tests**

Run:

```bash
cd nas-relay && npm test
```

Expected: pass.

- [x] **Step 3: Build relay**

Run:

```bash
cd nas-relay && npm run build
```

Expected: pass.

- [x] **Step 4: Build iOS app**

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: build succeeds.

- [ ] **Step 5: Manual log check on device**

Play `Favorite Songs` from Browse and export diagnostics:

```bash
xcrun devicectl device copy from \
  --device AD89415F-DB55-5D1E-BEF7-F78EA165C3DD \
  --domain-type appDataContainer \
  --domain-identifier com.charm.SonosWidget \
  --source Documents/sonos-diagnostics-export.log \
  --destination /tmp/sonos-diagnostics-export.log \
  --user mobile
```

Expected app log patterns:

```text
Queue artwork registry replaced count=...
Queue artwork fallback start ... current=http://<speaker>:1400/getaa...
Playback artwork resolver hit stage=registry ...
Playback artwork resolver hit stage=musicKit_direct ...
Queue artwork fallback hit source=musicKitDirect url=https://is*-ssl.mzstatic.com/...
Playback artwork prewarm skipped reason=cache_disabled registry=true hints=true ...
artwork hints posted count=...
```

Acceptable app fallback patterns when MusicKit direct/search misses:

```text
Queue artwork fallback hit source=iTunesLookup
Queue artwork fallback hit source=iTunesSearch
```

Unexpected app log pattern for Apple Music items unless all resolver stages miss:

```text
Remote artwork fetch start key=http://<speaker>:1400/getaa...
```

The `getaa` remote fetch can still appear after a MusicKit miss; it should not be the common Apple Music queue thumbnail path.

- [ ] **Step 6: Manual relay log check**

Start relay and play the same playlist. Expected relay log patterns:

```text
snapshot album art resolved artworkSource=hint ...
snapshot album art resolved artworkSource=itunes_lookup ...
snapshot album art resolved artworkSource=itunes_search ...
```

Acceptable fallback:

```text
snapshot album art resolved artworkSource=getaa ...
```

This should occur only when the snapshot is not Apple Music-ish or iTunes lookup/search both miss.

- [ ] **Step 7: Final commit if verification needed fixes**

If verification required changes:

```bash
git add SonosWidget SonosWidgetTests nas-relay
git commit -m "Verify artwork resolution fallback chain"
```

If verification made no changes, do not create an empty commit.

---

## Self-Review

- Spec coverage:
  - App uses public CDN already present or detail-view in-memory registry, then MusicKit direct/search, then iTunes lookup/search before `getaa`: Tasks 1 through 3.
  - Browse public CDN can help app queue rows and relay without heavy cache/prewarm: Tasks 1 and 2.
  - Relay tries public/hint, then iTunes, then `getaa`: Tasks 4 through 6.
  - Relay avoids repeated iTunes pressure: Task 7.
  - Verification includes app logs, relay logs, tests, and builds: Task 8.

- Completeness scan:
  - No deferred implementation notes remain. Task 6 uses existing helpers from `sonos.test.ts` by name and includes complete test code.

- Type consistency:
  - Swift policy names are introduced in Task 1 and used in Task 2.
  - TypeScript resolver source values are introduced in Task 5 and reused in Task 6 logs.
  - iTunes result source values match `ITunesArtworkSource`.
