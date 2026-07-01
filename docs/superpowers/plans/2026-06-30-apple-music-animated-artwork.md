# Apple Music Animated Artwork Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Apple Music animated album artwork inside the app player card, and use Apple Music album detail pages to warm the same animated artwork cache without changing existing static artwork, widget, Live Activity, or Hue behavior.

**Architecture:** Keep animated artwork as an optional overlay. `nas-relay` owns Apple Music web AMP lookup, bearer-token extraction, caching, rate-limit backoff, and JSON routes. The iOS app asks relay for an animated artwork URL, stores successful hits in an in-memory registry, and renders a muted looping `AVPlayerLayer` above the existing static album art only when the current track remains eligible.

**Tech Stack:** TypeScript, Express, Node `node:test`, Swift, SwiftUI, UIKit `UIViewRepresentable`, AVFoundation, XCTest.

---

## Scope Check

This first implementation covers:

- Relay-side animated Apple Music album artwork lookup.
- Relay route API under `/api/animated-artwork`.
- iOS relay client request and decoding helpers.
- App-side animated artwork registry and now-playing state.
- Player card video overlay for Apple Music tracks.
- Album detail cache prewarming after Apple Music album URL resolution.

This first implementation does not cover:

- Widget or Live Activity animated artwork.
- Hue palette extraction from video frames.
- Downloading, transcoding, or locally persisting video files.
- A Settings screen toggle.
- Replacing `TrackInfo.albumArtURL` with video URLs.
- Making album detail hero art animate on screen.

---

## File Structure

- Create `nas-relay/src/animatedAppleMusicArtwork.ts`
  - Parse Apple Music album URLs.
  - Fetch Apple Music web bearer token.
  - Fetch AMP catalog album details with `extend=editorialVideo&platform=web`.
  - Extract `motionDetailSquare.video` and `motionDetailTall.video`.
  - Cache hits and misses in `${DATA_DIR}/animated-artwork-cache.json`.
  - Apply in-memory backoff after `403` and `429`.

- Create `nas-relay/src/animatedAppleMusicArtwork.test.ts`
  - Unit tests for URL parsing, video extraction, cache reuse, negative cache, disabled mode, rate-limit backoff, and metadata search flow.

- Create `nas-relay/src/animatedArtworkRoutes.ts`
  - `GET /api/animated-artwork/url?url=...`
  - `GET /api/animated-artwork/search?artist=...&album=...&country=...`

- Create `nas-relay/src/animatedArtworkRoutes.test.ts`
  - Express route validation and stable JSON envelope tests.

- Modify `nas-relay/src/index.ts`
  - Instantiate `AnimatedAppleMusicArtworkResolver`.
  - Mount `createAnimatedArtworkRouter(...)` under `/api`.

- Modify `nas-relay/src/httpLogging.ts`
  - Suppress automatic per-request logs for `/api/animated-artwork/url` and `/api/animated-artwork/search`.

- Modify `Shared/RelayClient.swift`
  - Add `AnimatedArtworkResponse`, status decoding, URL builders, and fetch helpers.

- Create `SonosWidget/AnimatedArtworkFeature.swift`
  - Static app-side feature gate and environment eligibility policy.

- Create `SonosWidget/AnimatedArtworkRegistry.swift`
  - In-memory registry keyed by Apple Music album URL/catalog id and normalized artist+album.

- Create `SonosWidget/AnimatedNowPlayingArtworkState.swift`
  - Main-actor lookup state, stale-result protection, relay access, and registry writes.

- Create `SonosWidget/AnimatedArtworkPlayerView.swift`
  - Muted looping `AVPlayerLayer` wrapper without visible playback controls.

- Modify `SonosWidget/PlayerView.swift`
  - Resolve animated artwork when now playing changes.
  - Overlay video above existing static album art only after the first video frame can render.
  - Keep TV, live stream, non-Apple-Music, Reduce Motion, and Low Power Mode surfaces static.

- Modify `SonosWidget/AlbumDetailView.swift`
  - Prewarm animated artwork by Apple Music album URL after the existing Apple Music album URL lookup finishes.

- Create `SonosWidgetTests/RelayClientAnimatedArtworkTests.swift`
  - URL building and JSON decoding tests.

- Create `SonosWidgetTests/AnimatedArtworkRegistryTests.swift`
  - Key priority and ambiguity tests.

- Create `SonosWidgetTests/AnimatedNowPlayingArtworkStateTests.swift`
  - Eligibility, stale lookup discard, and disabled-policy tests.

---

### Task 1: Relay Animated Artwork Resolver Core

**Files:**
- Create: `nas-relay/src/animatedAppleMusicArtwork.ts`
- Test: `nas-relay/src/animatedAppleMusicArtwork.test.ts`

- [ ] **Step 1: Add failing resolver tests**

Create `nas-relay/src/animatedAppleMusicArtwork.test.ts` with fixture-driven tests:

```ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  AnimatedAppleMusicArtworkResolver,
  parseAppleMusicAlbumURL,
} from './animatedAppleMusicArtwork.js';

const albumFixture = {
  data: [{
    id: '1547315522',
    attributes: {
      name: 'evermore (deluxe version)',
      artistName: 'Taylor Swift',
      url: 'https://music.apple.com/us/album/evermore-deluxe-version/1547315522',
      editorialVideo: {
        motionDetailSquare: { video: 'https://video.example.com/square.m3u8' },
        motionDetailTall: { video: 'https://video.example.com/tall.m3u8' },
      },
    },
  }],
};

test('parseAppleMusicAlbumURL extracts storefront and album id', () => {
  assert.deepEqual(
    parseAppleMusicAlbumURL('https://music.apple.com/us/album/evermore-deluxe-version/1547315522'),
    { storefront: 'us', albumId: '1547315522' },
  );
});

test('resolveByURL extracts square and tall video URLs from editorialVideo', async () => {
  const resolver = new AnimatedAppleMusicArtworkResolver({
    dataDir: path.join(tmpdir(), `animated-artwork-${Date.now()}`),
    fetchBearerToken: async () => 'token',
    fetchJson: async () => albumFixture,
    now: () => 1000,
  });

  const result = await resolver.resolveByURL({
    url: 'https://music.apple.com/us/album/evermore-deluxe-version/1547315522',
  });

  assert.equal(result.status, 'hit');
  assert.equal(result.squareUrl, 'https://video.example.com/square.m3u8');
  assert.equal(result.tallUrl, 'https://video.example.com/tall.m3u8');
  assert.equal(result.source, 'url');
});

test('resolveByURL caches confirmed misses', async () => {
  let fetchCount = 0;
  const resolver = new AnimatedAppleMusicArtworkResolver({
    dataDir: path.join(tmpdir(), `animated-artwork-miss-${Date.now()}`),
    fetchBearerToken: async () => 'token',
    fetchJson: async () => {
      fetchCount += 1;
      return { data: [{ id: '1', attributes: { name: 'Album', artistName: 'Artist' } }] };
    },
    now: () => 1000,
  });

  const first = await resolver.resolveByURL({
    url: 'https://music.apple.com/us/album/example/1',
  });
  const second = await resolver.resolveByURL({
    url: 'https://music.apple.com/us/album/example/1',
  });

  assert.equal(first.status, 'miss');
  assert.equal(second.status, 'negative-cache');
  assert.equal(fetchCount, 1);
});

test('resolveByURL enters backoff after rate limit response', async () => {
  const resolver = new AnimatedAppleMusicArtworkResolver({
    dataDir: path.join(tmpdir(), `animated-artwork-rate-${Date.now()}`),
    fetchBearerToken: async () => 'token',
    fetchJson: async () => {
      const error = new Error('rate limited') as Error & { status?: number };
      error.status = 429;
      throw error;
    },
    now: () => 1000,
  });

  const first = await resolver.resolveByURL({
    url: 'https://music.apple.com/us/album/example/1',
  });
  const second = await resolver.resolveByURL({
    url: 'https://music.apple.com/us/album/example/1',
  });

  assert.equal(first.status, 'rate-limited');
  assert.equal(second.status, 'rate-limited');
  assert.equal(second.source, 'none');
});

test('resolveByMetadata searches once then resolves the album URL', async () => {
  const resolver = new AnimatedAppleMusicArtworkResolver({
    dataDir: path.join(tmpdir(), `animated-artwork-search-${Date.now()}`),
    fetchBearerToken: async () => 'token',
    fetchJson: async () => albumFixture,
    searchAppleMusicAlbumURL: async input => {
      assert.equal(input.artist, 'Taylor Swift');
      assert.equal(input.album, 'evermore');
      return 'https://music.apple.com/us/album/evermore-deluxe-version/1547315522';
    },
    now: () => 1000,
  });

  const result = await resolver.resolveByMetadata({
    artist: 'Taylor Swift',
    album: 'evermore',
    countryCode: 'us',
  });

  assert.equal(result.status, 'hit');
  assert.equal(result.source, 'metadata-search');
  assert.equal(result.appleMusicUrl, 'https://music.apple.com/us/album/evermore-deluxe-version/1547315522');
});
```

- [ ] **Step 2: Run the focused relay test and verify RED**

Run:

```bash
npm test --prefix nas-relay -- animatedAppleMusicArtwork.test.ts
```

Expected: fail because `nas-relay/src/animatedAppleMusicArtwork.ts` does not exist.

- [ ] **Step 3: Implement resolver public types and pure parsing**

Create `nas-relay/src/animatedAppleMusicArtwork.ts` with these exported contracts:

```ts
import fs from 'node:fs/promises';
import path from 'node:path';

export type AnimatedArtworkStatus =
  | 'hit'
  | 'miss'
  | 'negative-cache'
  | 'rate-limited'
  | 'disabled'
  | 'error';

export type AnimatedArtworkSource = 'url' | 'metadata-search' | 'cache' | 'none';

export interface AnimatedArtworkResolution {
  ok: true;
  status: AnimatedArtworkStatus;
  artist: string | null;
  album: string | null;
  appleMusicUrl: string | null;
  squareUrl: string | null;
  tallUrl: string | null;
  source: AnimatedArtworkSource;
}

export interface AnimatedArtworkURLInput {
  url: string;
  countryCode?: string | undefined;
}

export interface AnimatedArtworkMetadataInput {
  artist: string;
  album: string;
  countryCode?: string | undefined;
}

export interface AnimatedAppleMusicArtworkResolverOptions {
  dataDir: string;
  enabled?: boolean | undefined;
  cacheTtlMs?: number | undefined;
  negativeCacheTtlMs?: number | undefined;
  metadataNegativeCacheTtlMs?: number | undefined;
  rateLimitBackoffMs?: number | undefined;
  fetchBearerToken?: (() => Promise<string>) | undefined;
  fetchJson?: ((url: URL, init: RequestInit) => Promise<unknown>) | undefined;
  fetchText?: ((url: URL, init?: RequestInit) => Promise<string>) | undefined;
  searchAppleMusicAlbumURL?: ((input: AnimatedArtworkMetadataInput) => Promise<string | null>) | undefined;
  now?: (() => number) | undefined;
}

export interface ParsedAppleMusicAlbumURL {
  storefront: string;
  albumId: string;
}

export function parseAppleMusicAlbumURL(value: string): ParsedAppleMusicAlbumURL | null {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }

  if (url.hostname !== 'music.apple.com') return null;
  const parts = url.pathname.split('/').filter(Boolean);
  const storefront = parts[0]?.toLowerCase();
  const albumMarker = parts.indexOf('album');
  const albumId = parts[albumMarker + 2] ?? parts[albumMarker + 1];
  if (!storefront || albumMarker < 0 || !albumId || !/^[0-9]+$/.test(albumId)) {
    return null;
  }
  return { storefront, albumId };
}
```

Then implement the class methods:

- `resolveByURL(input:)`
- `resolveByMetadata(input:)`
- `loadCache()`
- `saveCache()`
- `fetchAnimatedArtwork(parsed:)`
- `defaultFetchBearerToken()`
- `defaultSearchAppleMusicAlbumURL(input:)`

Required resolver behavior:

- `enabled === false` returns `status: "disabled"` without network access.
- Cache key for URL lookup is `album:{storefront}:{albumId}`.
- Metadata key is `metadata:{normalizedArtist}:{normalizedAlbum}:{country}`.
- Positive hit TTL is 30 days.
- Confirmed no-video miss TTL is 30 days.
- Metadata no-match TTL is 7 days.
- Global backoff after `403` or `429` is 15 minutes.
- `fetchAnimatedArtwork` calls:

```ts
const endpoint = new URL(`https://amp-api.music.apple.com/v1/catalog/${parsed.storefront}/albums/${parsed.albumId}`);
endpoint.searchParams.set('extend', 'editorialVideo');
endpoint.searchParams.set('platform', 'web');
```

- The request sets:

```ts
{
  headers: {
    Authorization: `Bearer ${token}`,
    Origin: 'https://music.apple.com',
    Referer: 'https://music.apple.com/',
  },
  signal,
}
```

- The extractor accepts only `http` or `https` `.m3u8` URLs.
- Search uses the existing iTunes Search API shape, with conservative matching on normalized artist and album names, then returns the Apple Music collection URL.

- [ ] **Step 4: Run the focused relay test and verify GREEN**

Run:

```bash
npm test --prefix nas-relay -- animatedAppleMusicArtwork.test.ts
```

Expected: all tests in `animatedAppleMusicArtwork.test.ts` pass.

---

### Task 2: Relay Routes And Server Wiring

**Files:**
- Create: `nas-relay/src/animatedArtworkRoutes.ts`
- Test: `nas-relay/src/animatedArtworkRoutes.test.ts`
- Modify: `nas-relay/src/index.ts`
- Modify: `nas-relay/src/httpLogging.ts`

- [ ] **Step 1: Add failing route tests**

Create `nas-relay/src/animatedArtworkRoutes.test.ts`:

```ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import express from 'express';
import pino from 'pino';

import { createAnimatedArtworkRouter } from './animatedArtworkRoutes.js';
import type { AnimatedAppleMusicArtworkResolver } from './animatedAppleMusicArtwork.js';

function testServer(resolver: Pick<AnimatedAppleMusicArtworkResolver, 'resolveByURL' | 'resolveByMetadata'>) {
  const app = express();
  app.use('/api', createAnimatedArtworkRouter(pino({ enabled: false }), resolver));
  const server = app.listen(0);
  const address = server.address();
  assert.equal(typeof address, 'object');
  assert.ok(address);
  const baseURL = `http://127.0.0.1:${address.port}`;
  return { server, baseURL };
}

test('url route returns resolver envelope', async () => {
  const { server, baseURL } = testServer({
    resolveByURL: async () => ({
      ok: true,
      status: 'hit',
      artist: 'Taylor Swift',
      album: 'evermore',
      appleMusicUrl: 'https://music.apple.com/us/album/evermore-deluxe-version/1547315522',
      squareUrl: 'https://video.example.com/square.m3u8',
      tallUrl: null,
      source: 'url',
    }),
    resolveByMetadata: async () => {
      throw new Error('unexpected');
    },
  });
  try {
    const response = await fetch(`${baseURL}/api/animated-artwork/url?url=${encodeURIComponent('https://music.apple.com/us/album/example/1')}`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      ok: true,
      status: 'hit',
      artist: 'Taylor Swift',
      album: 'evermore',
      appleMusicUrl: 'https://music.apple.com/us/album/evermore-deluxe-version/1547315522',
      squareUrl: 'https://video.example.com/square.m3u8',
      tallUrl: null,
      source: 'url',
    });
  } finally {
    server.close();
  }
});

test('search route validates artist and album', async () => {
  const { server, baseURL } = testServer({
    resolveByURL: async () => {
      throw new Error('unexpected');
    },
    resolveByMetadata: async () => {
      throw new Error('unexpected');
    },
  });
  try {
    const response = await fetch(`${baseURL}/api/animated-artwork/search?artist=Taylor`);
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), {
      ok: false,
      error: 'artist and album are required',
    });
  } finally {
    server.close();
  }
});
```

- [ ] **Step 2: Run route tests and verify RED**

Run:

```bash
npm test --prefix nas-relay -- animatedArtworkRoutes.test.ts
```

Expected: fail because `animatedArtworkRoutes.ts` does not exist.

- [ ] **Step 3: Implement route module**

Create `nas-relay/src/animatedArtworkRoutes.ts`:

```ts
import express from 'express';
import type pino from 'pino';

import type { AnimatedAppleMusicArtworkResolver } from './animatedAppleMusicArtwork.js';

export function createAnimatedArtworkRouter(
  log: pino.Logger,
  resolver: Pick<AnimatedAppleMusicArtworkResolver, 'resolveByURL' | 'resolveByMetadata'>,
): express.Router {
  const router = express.Router();

  router.get('/animated-artwork/url', async (req, res) => {
    const url = typeof req.query.url === 'string' ? req.query.url.trim() : '';
    const countryCode = typeof req.query.country === 'string' ? req.query.country.trim() : undefined;
    if (!url) {
      res.status(400).json({ ok: false, error: 'url is required' });
      return;
    }

    try {
      res.json(await resolver.resolveByURL({ url, countryCode }));
    } catch (err) {
      log.warn({ err, source: 'relay', action: 'animated-artwork-url' }, 'animated_artwork');
      res.json({
        ok: true,
        status: 'error',
        artist: null,
        album: null,
        appleMusicUrl: null,
        squareUrl: null,
        tallUrl: null,
        source: 'none',
      });
    }
  });

  router.get('/animated-artwork/search', async (req, res) => {
    const artist = typeof req.query.artist === 'string' ? req.query.artist.trim() : '';
    const album = typeof req.query.album === 'string' ? req.query.album.trim() : '';
    const countryCode = typeof req.query.country === 'string' ? req.query.country.trim() : undefined;
    if (!artist || !album) {
      res.status(400).json({ ok: false, error: 'artist and album are required' });
      return;
    }

    try {
      res.json(await resolver.resolveByMetadata({ artist, album, countryCode }));
    } catch (err) {
      log.warn({ err, source: 'relay', action: 'animated-artwork-search' }, 'animated_artwork');
      res.json({
        ok: true,
        status: 'error',
        artist: null,
        album: null,
        appleMusicUrl: null,
        squareUrl: null,
        tallUrl: null,
        source: 'none',
      });
    }
  });

  return router;
}
```

- [ ] **Step 4: Wire route into `index.ts`**

Add imports:

```ts
import { AnimatedAppleMusicArtworkResolver } from './animatedAppleMusicArtwork.js';
import { createAnimatedArtworkRouter } from './animatedArtworkRoutes.js';
```

After `deviceLogs` creation, instantiate:

```ts
const animatedArtworkResolver = new AnimatedAppleMusicArtworkResolver({
  dataDir: DATA_DIR,
  enabled: (process.env.ANIMATED_ARTWORK_ENABLED ?? 'true') !== 'false',
});
```

Mount the router with the existing `/api` routes:

```ts
app.use('/api', createAnimatedArtworkRouter(
  log.child({ module: 'animated-artwork' }),
  animatedArtworkResolver,
));
```

- [ ] **Step 5: Update auto-log suppression**

In `nas-relay/src/httpLogging.ts`, add:

```ts
const ANIMATED_ARTWORK_URL_PATH = '/api/animated-artwork/url';
const ANIMATED_ARTWORK_SEARCH_PATH = '/api/animated-artwork/search';
```

Include both constants in `shouldIgnoreHttpAutoLog(...)`.

- [ ] **Step 6: Verify relay routes and TypeScript build**

Run:

```bash
npm test --prefix nas-relay -- animatedArtworkRoutes.test.ts animatedAppleMusicArtwork.test.ts
npm run build --prefix nas-relay
```

Expected: both tests pass and TypeScript compiles.

---

### Task 3: Swift Relay Client API

**Files:**
- Modify: `Shared/RelayClient.swift`
- Test: `SonosWidgetTests/RelayClientAnimatedArtworkTests.swift`

- [ ] **Step 1: Add failing URL and decoder tests**

Create `SonosWidgetTests/RelayClientAnimatedArtworkTests.swift`:

```swift
import XCTest
@testable import SonosWidget

final class RelayClientAnimatedArtworkTests: XCTestCase {
    func testAnimatedArtworkURLBuilderEscapesAlbumURL() {
        let baseURL = URL(string: "http://192.168.50.2:8787")!
        let albumURL = URL(string: "https://music.apple.com/us/album/evermore-deluxe-version/1547315522")!

        let url = RelayClient.animatedArtworkURL(baseURL: baseURL, albumURL: albumURL)

        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.path, "/api/animated-artwork/url")
        XCTAssertTrue(url?.query?.contains("url=https://music.apple.com/us/album/evermore-deluxe-version/1547315522") == true)
    }

    func testAnimatedArtworkSearchURLBuilderEscapesMetadata() {
        let baseURL = URL(string: "http://192.168.50.2:8787")!

        let url = RelayClient.animatedArtworkSearchURL(
            baseURL: baseURL,
            artist: "Doja Cat",
            album: "Planet Her (Deluxe)",
            countryCode: "us"
        )

        XCTAssertEqual(url?.path, "/api/animated-artwork/search")
        XCTAssertTrue(url?.query?.contains("artist=Doja%20Cat") == true)
        XCTAssertTrue(url?.query?.contains("album=Planet%20Her%20(Deluxe)") == true)
        XCTAssertTrue(url?.query?.contains("country=us") == true)
    }

    func testAnimatedArtworkResponseDecodesHitAndUnknownStatus() throws {
        let hitData = """
        {
          "ok": true,
          "status": "hit",
          "artist": "Taylor Swift",
          "album": "evermore",
          "appleMusicUrl": "https://music.apple.com/us/album/evermore-deluxe-version/1547315522",
          "squareUrl": "https://video.example.com/square.m3u8",
          "tallUrl": null,
          "source": "url"
        }
        """.data(using: .utf8)!

        let hit = try JSONDecoder().decode(RelayClient.AnimatedArtworkResponse.self, from: hitData)
        XCTAssertEqual(hit.status, .hit)
        XCTAssertEqual(hit.squareURLString, "https://video.example.com/square.m3u8")

        let unknownData = """
        {
          "ok": true,
          "status": "future",
          "artist": null,
          "album": null,
          "appleMusicUrl": null,
          "squareUrl": null,
          "tallUrl": null,
          "source": "none"
        }
        """.data(using: .utf8)!

        let unknown = try JSONDecoder().decode(RelayClient.AnimatedArtworkResponse.self, from: unknownData)
        XCTAssertEqual(unknown.status, .unknown)
    }
}
```

- [ ] **Step 2: Run focused Swift tests and verify RED**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/RelayClientAnimatedArtworkTests
```

Expected: compile failure because animated artwork client types do not exist.

- [ ] **Step 3: Add RelayClient models and URL builders**

Add below the existing artwork proxy section in `Shared/RelayClient.swift`:

```swift
    // MARK: - Animated artwork

    struct AnimatedArtworkResponse: Decodable, Sendable, Equatable {
        enum Status: String, Decodable, Sendable {
            case hit
            case miss
            case negativeCache = "negative-cache"
            case rateLimited = "rate-limited"
            case disabled
            case error
            case unknown

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Status(rawValue: raw) ?? .unknown
            }
        }

        let ok: Bool
        let status: Status
        let artist: String?
        let album: String?
        let appleMusicURLString: String?
        let squareURLString: String?
        let tallURLString: String?
        let source: String?

        private enum CodingKeys: String, CodingKey {
            case ok
            case status
            case artist
            case album
            case appleMusicURLString = "appleMusicUrl"
            case squareURLString = "squareUrl"
            case tallURLString = "tallUrl"
            case source
        }

        var bestSquareArtworkURL: URL? {
            [squareURLString, tallURLString].compactMap { value in
                guard let value else { return nil }
                return URL(string: value)
            }.first
        }
    }

    static func animatedArtworkURL(baseURL: URL, albumURL: URL, countryCode: String? = nil) -> URL? {
        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("animated-artwork")
            .appendingPathComponent("url")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: albumURL.absoluteString),
            countryCode.map { URLQueryItem(name: "country", value: $0) }
        ].compactMap { $0 }
        return components.url
    }

    static func animatedArtworkSearchURL(
        baseURL: URL,
        artist: String,
        album: String,
        countryCode: String? = nil
    ) -> URL? {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty, !trimmedAlbum.isEmpty else { return nil }

        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("animated-artwork")
            .appendingPathComponent("search")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "artist", value: trimmedArtist),
            URLQueryItem(name: "album", value: trimmedAlbum),
            countryCode.map { URLQueryItem(name: "country", value: $0) }
        ].compactMap { $0 }
        return components.url
    }
```

- [ ] **Step 4: Add RelayClient fetch helpers**

Add:

```swift
    static func animatedArtworkByURL(
        baseURL: URL,
        albumURL: URL,
        countryCode: String? = nil
    ) async throws -> AnimatedArtworkResponse {
        guard let url = animatedArtworkURL(
            baseURL: baseURL,
            albumURL: albumURL,
            countryCode: countryCode
        ) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(AnimatedArtworkResponse.self, from: data)
    }

    static func animatedArtworkSearch(
        baseURL: URL,
        artist: String,
        album: String,
        countryCode: String? = nil
    ) async throws -> AnimatedArtworkResponse {
        guard let url = animatedArtworkSearchURL(
            baseURL: baseURL,
            artist: artist,
            album: album,
            countryCode: countryCode
        ) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(AnimatedArtworkResponse.self, from: data)
    }
```

- [ ] **Step 5: Run focused Swift tests and verify GREEN**

Run the same focused `RelayClientAnimatedArtworkTests` command.

Expected: tests pass.

---

### Task 4: App Feature Gate, Registry, And Eligibility Policy

**Files:**
- Create: `SonosWidget/AnimatedArtworkFeature.swift`
- Create: `SonosWidget/AnimatedArtworkRegistry.swift`
- Test: `SonosWidgetTests/AnimatedArtworkRegistryTests.swift`

- [ ] **Step 1: Add failing registry tests**

Create `SonosWidgetTests/AnimatedArtworkRegistryTests.swift`:

```swift
import XCTest
@testable import SonosWidget

@MainActor
final class AnimatedArtworkRegistryTests: XCTestCase {
    func testLookupPrefersAlbumURLOverMetadataFallback() {
        let registry = AnimatedArtworkRegistry()
        registry.register(
            AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/url.m3u8",
                tallURLString: nil,
                appleMusicURLString: "https://music.apple.com/us/album/evermore-deluxe-version/1547315522",
                artist: "Taylor Swift",
                album: "evermore",
                source: .url,
                resolvedAt: Date(timeIntervalSince1970: 1)
            )
        )
        registry.register(
            AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/metadata.m3u8",
                tallURLString: nil,
                appleMusicURLString: nil,
                artist: "Taylor Swift",
                album: "evermore",
                source: .metadataSearch,
                resolvedAt: Date(timeIntervalSince1970: 2)
            )
        )

        let result = registry.artwork(
            appleMusicURLString: "https://music.apple.com/us/album/evermore-deluxe-version/1547315522",
            artist: "Taylor Swift",
            album: "evermore"
        )

        XCTAssertEqual(result?.squareURLString, "https://video.example.com/url.m3u8")
    }

    func testAmbiguousMetadataDoesNotReturnStaleVideo() {
        let registry = AnimatedArtworkRegistry()
        registry.register(
            AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/a.m3u8",
                tallURLString: nil,
                appleMusicURLString: nil,
                artist: "Artist",
                album: "Album",
                source: .metadataSearch,
                resolvedAt: Date(timeIntervalSince1970: 1)
            )
        )
        registry.register(
            AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/b.m3u8",
                tallURLString: nil,
                appleMusicURLString: nil,
                artist: "Artist",
                album: "Album",
                source: .metadataSearch,
                resolvedAt: Date(timeIntervalSince1970: 2)
            )
        )

        XCTAssertNil(registry.artwork(appleMusicURLString: nil, artist: "Artist", album: "Album"))
    }
}
```

- [ ] **Step 2: Run focused registry tests and verify RED**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/AnimatedArtworkRegistryTests
```

Expected: compile failure because registry types do not exist.

- [ ] **Step 3: Add feature gate**

Create `SonosWidget/AnimatedArtworkFeature.swift`:

```swift
import Foundation
import UIKit

enum AnimatedArtworkFeature {
    static let isEnabled = true

    static func canRenderVideo(
        source: PlaybackSource?,
        isReduceMotionEnabled: Bool = UIAccessibility.isReduceMotionEnabled,
        isLowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    ) -> Bool {
        guard isEnabled else { return false }
        guard source == .appleMusic else { return false }
        guard !isReduceMotionEnabled else { return false }
        guard !isLowPowerModeEnabled else { return false }
        return true
    }
}
```

- [ ] **Step 4: Add registry**

Create `SonosWidget/AnimatedArtworkRegistry.swift`:

```swift
import Foundation

struct AnimatedArtworkInfo: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case url
        case metadataSearch
        case cache
    }

    var squareURLString: String?
    var tallURLString: String?
    var appleMusicURLString: String?
    var artist: String?
    var album: String?
    var source: Source
    var resolvedAt: Date

    var playerURL: URL? {
        [squareURLString, tallURLString].compactMap { value in
            guard let value else { return nil }
            return URL(string: value)
        }.first
    }
}

@MainActor
final class AnimatedArtworkRegistry {
    static let shared = AnimatedArtworkRegistry()

    private enum LookupKey: Hashable {
        case albumURL(String)
        case catalogID(String)
        case album(artist: String, album: String)
    }

    private struct Entry {
        var info: AnimatedArtworkInfo?
        var valueKey: String
        var isAmbiguous: Bool
    }

    private var entries: [LookupKey: Entry] = [:]

    func register(_ info: AnimatedArtworkInfo) {
        guard info.playerURL != nil else { return }
        for key in lookupKeys(
            appleMusicURLString: info.appleMusicURLString,
            artist: info.artist,
            album: info.album
        ) {
            remember(info, for: key)
        }
    }

    func artwork(
        appleMusicURLString: String?,
        artist: String?,
        album: String?
    ) -> AnimatedArtworkInfo? {
        for key in lookupKeys(
            appleMusicURLString: appleMusicURLString,
            artist: artist,
            album: album
        ) {
            guard let entry = entries[key],
                  !entry.isAmbiguous,
                  let info = entry.info else {
                continue
            }
            return info
        }
        return nil
    }

    private func remember(_ info: AnimatedArtworkInfo, for key: LookupKey) {
        let valueKey = info.playerURL?.absoluteString ?? ""
        guard let existing = entries[key] else {
            entries[key] = Entry(info: info, valueKey: valueKey, isAmbiguous: false)
            return
        }

        guard existing.valueKey != valueKey else {
            entries[key] = Entry(info: info, valueKey: valueKey, isAmbiguous: false)
            return
        }
        entries[key] = Entry(info: nil, valueKey: existing.valueKey, isAmbiguous: true)
    }

    private func lookupKeys(
        appleMusicURLString: String?,
        artist: String?,
        album: String?
    ) -> [LookupKey] {
        var keys: [LookupKey] = []
        if let normalizedURL = normalizedURLString(appleMusicURLString) {
            keys.append(.albumURL(normalizedURL))
            if let catalogID = catalogID(from: normalizedURL) {
                keys.append(.catalogID(catalogID))
            }
        }
        if let artist = normalizedName(artist), let album = normalizedName(album) {
            keys.append(.album(artist: artist, album: album))
        }
        return keys
    }

    private func normalizedURLString(_ value: String?) -> String? {
        guard let value,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return url.absoluteString.lowercased()
    }

    private func catalogID(from value: String) -> String? {
        let path = URL(string: value)?.pathComponents ?? []
        return path.last(where: { $0.allSatisfy(\.isNumber) })
    }

    private func normalizedName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }
}
```

- [ ] **Step 5: Run focused registry tests and verify GREEN**

Run the same focused `AnimatedArtworkRegistryTests` command.

Expected: tests pass.

---

### Task 5: Now-Playing Lookup State

**Files:**
- Create: `SonosWidget/AnimatedNowPlayingArtworkState.swift`
- Test: `SonosWidgetTests/AnimatedNowPlayingArtworkStateTests.swift`

- [ ] **Step 1: Add failing state tests**

Create `SonosWidgetTests/AnimatedNowPlayingArtworkStateTests.swift`:

```swift
import XCTest
@testable import SonosWidget

@MainActor
final class AnimatedNowPlayingArtworkStateTests: XCTestCase {
    func testEligibilityRejectsReduceMotionAndNonAppleMusic() {
        XCTAssertFalse(AnimatedArtworkFeature.canRenderVideo(
            source: .appleMusic,
            isReduceMotionEnabled: true,
            isLowPowerModeEnabled: false
        ))
        XCTAssertFalse(AnimatedArtworkFeature.canRenderVideo(
            source: .spotify,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: false
        ))
        XCTAssertTrue(AnimatedArtworkFeature.canRenderVideo(
            source: .appleMusic,
            isReduceMotionEnabled: false,
            isLowPowerModeEnabled: false
        ))
    }

    func testStaleLookupResultIsDiscarded() async {
        let state = AnimatedNowPlayingArtworkState(registry: AnimatedArtworkRegistry())
        let oldIdentity = AnimatedNowPlayingArtworkState.Identity(
            trackURI: "old",
            title: "Old",
            artist: "Artist",
            album: "Album"
        )
        let newIdentity = AnimatedNowPlayingArtworkState.Identity(
            trackURI: "new",
            title: "New",
            artist: "Artist",
            album: "Album"
        )

        state.beginLookup(identity: oldIdentity)
        state.beginLookup(identity: newIdentity)
        state.apply(
            info: AnimatedArtworkInfo(
                squareURLString: "https://video.example.com/old.m3u8",
                tallURLString: nil,
                appleMusicURLString: nil,
                artist: "Artist",
                album: "Album",
                source: .metadataSearch,
                resolvedAt: Date()
            ),
            for: oldIdentity
        )

        XCTAssertNil(state.currentInfo)
    }
}
```

- [ ] **Step 2: Run focused state tests and verify RED**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/AnimatedNowPlayingArtworkStateTests
```

Expected: compile failure because `AnimatedNowPlayingArtworkState` does not exist.

- [ ] **Step 3: Implement state holder**

Create `SonosWidget/AnimatedNowPlayingArtworkState.swift`:

```swift
import Foundation

@MainActor
final class AnimatedNowPlayingArtworkState: ObservableObject {
    struct Identity: Equatable, Sendable {
        let trackURI: String?
        let title: String
        let artist: String
        let album: String
    }

    @Published private(set) var currentInfo: AnimatedArtworkInfo?
    @Published private(set) var currentURL: URL?

    private let registry: AnimatedArtworkRegistry
    private var activeIdentity: Identity?
    private var lookupTask: Task<Void, Never>?

    init(registry: AnimatedArtworkRegistry = .shared) {
        self.registry = registry
    }

    func reset() {
        lookupTask?.cancel()
        activeIdentity = nil
        currentInfo = nil
        currentURL = nil
    }

    func beginLookup(identity: Identity) {
        if activeIdentity != identity {
            currentInfo = nil
            currentURL = nil
        }
        activeIdentity = identity
    }

    func apply(info: AnimatedArtworkInfo, for identity: Identity) {
        guard activeIdentity == identity else { return }
        registry.register(info)
        currentInfo = info
        currentURL = info.playerURL
    }

    func resolve(
        identity: Identity,
        albumURL: URL?,
        relayBaseURL: URL?,
        source: PlaybackSource?
    ) {
        lookupTask?.cancel()
        guard AnimatedArtworkFeature.canRenderVideo(source: source),
              let relayBaseURL else {
            reset()
            return
        }

        beginLookup(identity: identity)
        if let cached = registry.artwork(
            appleMusicURLString: albumURL?.absoluteString,
            artist: identity.artist,
            album: identity.album
        ) {
            apply(info: cached, for: identity)
            return
        }

        lookupTask = Task { [weak self] in
            do {
                let response: RelayClient.AnimatedArtworkResponse
                if let albumURL {
                    response = try await RelayClient.animatedArtworkByURL(
                        baseURL: relayBaseURL,
                        albumURL: albumURL
                    )
                } else {
                    response = try await RelayClient.animatedArtworkSearch(
                        baseURL: relayBaseURL,
                        artist: identity.artist,
                        album: identity.album,
                        countryCode: "us"
                    )
                }
                guard response.status == .hit,
                      response.bestSquareArtworkURL != nil else {
                    return
                }
                let info = AnimatedArtworkInfo(
                    squareURLString: response.squareURLString,
                    tallURLString: response.tallURLString,
                    appleMusicURLString: response.appleMusicURLString ?? albumURL?.absoluteString,
                    artist: response.artist ?? identity.artist,
                    album: response.album ?? identity.album,
                    source: response.source == "metadata-search" ? .metadataSearch : .url,
                    resolvedAt: Date()
                )
                await MainActor.run {
                    self?.apply(info: info, for: identity)
                }
            } catch {
                SonosLog.network("Animated artwork lookup failed error=\(error)")
            }
        }
    }
}
```

- [ ] **Step 4: Run focused state tests and verify GREEN**

Run the same focused `AnimatedNowPlayingArtworkStateTests` command.

Expected: tests pass.

---

### Task 6: Player Video Renderer

**Files:**
- Create: `SonosWidget/AnimatedArtworkPlayerView.swift`
- Modify: `SonosWidget/PlayerView.swift`

- [ ] **Step 1: Add the UIKit video layer wrapper**

Create `SonosWidget/AnimatedArtworkPlayerView.swift`:

```swift
import AVFoundation
import SwiftUI
import UIKit

struct AnimatedArtworkPlayerView: UIViewRepresentable {
    let url: URL
    var isPlaying: Bool
    var onReadyForDisplay: (() -> Void)?

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.configure(url: url, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.configure(url: url, coordinator: context.coordinator)
        if isPlaying {
            view.player?.play()
        } else {
            view.player?.pause()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReadyForDisplay: onReadyForDisplay)
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var player: AVQueuePlayer? {
            get { playerLayer.player as? AVQueuePlayer }
            set { playerLayer.player = newValue }
        }
        private var currentURL: URL?
        private var looper: AVPlayerLooper?

        func configure(url: URL, coordinator: Coordinator) {
            guard currentURL != url else { return }
            currentURL = url
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.actionAtItemEnd = .none
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            coordinator.observe(playerLayer: playerLayer)
        }
    }

    final class Coordinator: NSObject {
        private var observation: NSKeyValueObservation?
        private let onReadyForDisplay: (() -> Void)?

        init(onReadyForDisplay: (() -> Void)?) {
            self.onReadyForDisplay = onReadyForDisplay
        }

        func observe(playerLayer: AVPlayerLayer) {
            observation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    self?.onReadyForDisplay?()
                }
            }
        }
    }
}
```

- [ ] **Step 2: Compile the app target**

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: build succeeds. If `AVPlayerLooper` or KVO lifetimes need adjustment, fix the wrapper before touching `PlayerView`.

---

### Task 7: Player Card Integration

**Files:**
- Modify: `SonosWidget/PlayerView.swift`

- [ ] **Step 1: Add player state properties**

Inside `PlayerView`, add:

```swift
@StateObject private var animatedArtworkState = AnimatedNowPlayingArtworkState()
@State private var animatedArtworkReady = false
```

- [ ] **Step 2: Add now-playing animated artwork identity**

Add a helper near existing Apple Music current-track helpers:

```swift
private var animatedArtworkIdentity: AnimatedNowPlayingArtworkState.Identity? {
    guard let info = manager.trackInfo,
          !info.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !info.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return AnimatedNowPlayingArtworkState.Identity(
        trackURI: info.trackURI,
        title: info.title,
        artist: info.artist,
        album: info.album
    )
}
```

- [ ] **Step 3: Trigger lookup from existing player lifecycle**

Attach to the main expanded player container, next to existing `.task` / `.onChange` playback hooks:

```swift
.task(id: animatedArtworkIdentity) {
    guard let identity = animatedArtworkIdentity else {
        animatedArtworkState.reset()
        animatedArtworkReady = false
        return
    }

    animatedArtworkReady = false
    let albumURL = currentAppleMusicAnimatedArtworkLookupURL
    let relayBaseURL = RelayManager.shared.url
    animatedArtworkState.resolve(
        identity: identity,
        albumURL: albumURL,
        relayBaseURL: relayBaseURL,
        source: manager.trackInfo?.source
    )
}
.onDisappear {
    animatedArtworkState.reset()
    animatedArtworkReady = false
}
```

- [ ] **Step 4: Add an Apple Music URL helper**

Use the existing current-track Apple Music URL preload before metadata search. Apple Music song URLs returned by the current fallback resolver use an `/album/.../{albumId}` path with a song `i=` query, so the relay URL parser can extract the album id from the path and ignore the song query.

```swift
private var currentAppleMusicAnimatedArtworkLookupURL: URL? {
    currentAppleMusicTrackURL
}
```

When this helper returns `nil`, `AnimatedNowPlayingArtworkState.resolve(...)` falls back to relay metadata search with the current `artist + album`.

- [ ] **Step 5: Overlay animated artwork inside `albumArtView(size:)`**

Keep the existing static image branch. Add the video layer only for non-TV artwork:

```swift
ZStack {
    existingStaticArtwork

    if !isTV,
       let animatedURL = animatedArtworkState.currentURL,
       AnimatedArtworkFeature.canRenderVideo(source: manager.trackInfo?.source) {
        AnimatedArtworkPlayerView(
            url: animatedURL,
            isPlaying: true,
            onReadyForDisplay: { animatedArtworkReady = true }
        )
        .opacity(animatedArtworkReady ? 1 : 0)
        .transition(.opacity)
        .accessibilityHidden(true)
    }
}
```

Preserve:

- TV format badge and TV placeholder.
- Source badge overlay.
- Existing tap-to-open Apple Music behavior.
- Existing size, corner radius, shadow, and drag/tap gesture behavior.
- Static `manager.albumArtImage` underneath the video.

- [ ] **Step 6: Compile the app target**

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: build succeeds.

---

### Task 8: Album Detail Cache Prewarm

**Files:**
- Modify: `SonosWidget/AlbumDetailView.swift`

- [ ] **Step 1: Add prewarm helper**

Add:

```swift
private func prewarmAnimatedArtwork(albumURL: URL) async {
    guard AnimatedArtworkFeature.isEnabled,
          let relayBaseURL = RelayManager.shared.url else {
        return
    }
    do {
        let response = try await RelayClient.animatedArtworkByURL(
            baseURL: relayBaseURL,
            albumURL: albumURL
        )
        guard response.status == .hit,
              response.bestSquareArtworkURL != nil else {
            return
        }
        await MainActor.run {
            AnimatedArtworkRegistry.shared.register(
                AnimatedArtworkInfo(
                    squareURLString: response.squareURLString,
                    tallURLString: response.tallURLString,
                    appleMusicURLString: response.appleMusicURLString ?? albumURL.absoluteString,
                    artist: response.artist ?? artist,
                    album: response.album ?? title,
                    source: response.source == "metadata-search" ? .metadataSearch : .url,
                    resolvedAt: Date()
                )
            )
        }
    } catch {
        SonosLog.network("Animated album artwork prewarm failed title='\(title)' artist='\(artist)' error=\(error)")
    }
}
```

- [ ] **Step 2: Call prewarm after album URL resolution**

In `refreshAppleMusicArtworkURL()`, after `fallbackAppleMusicArtworkURL = url`, add:

```swift
if let url {
    await prewarmAnimatedArtwork(albumURL: url)
}
```

Do not block album loading, favorite actions, queue actions, or static cover rendering.

- [ ] **Step 3: Compile the app target**

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: build succeeds.

---

### Task 9: Full Verification

**Files:**
- No new files.

- [ ] **Step 1: Run relay tests**

Run:

```bash
npm test --prefix nas-relay
```

Expected: all relay tests pass.

- [ ] **Step 2: Run relay build**

Run:

```bash
npm run build --prefix nas-relay
```

Expected: TypeScript compiles.

- [ ] **Step 3: Run focused Swift tests**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/RelayClientAnimatedArtworkTests \
  -only-testing:SonosWidgetTests/AnimatedArtworkRegistryTests \
  -only-testing:SonosWidgetTests/AnimatedNowPlayingArtworkStateTests
```

Expected: focused tests pass.

- [ ] **Step 4: Run app build**

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: app target builds.

- [ ] **Step 5: Manual relay probe with a known animated album**

With relay running, run:

```bash
curl 'http://127.0.0.1:8787/api/animated-artwork/url?url=https%3A%2F%2Fmusic.apple.com%2Fus%2Falbum%2Fevermore-deluxe-version%2F1547315522'
```

Expected: JSON response with `ok: true`. On supported Apple responses, `status` is `hit` and `squareUrl` or `tallUrl` is a `.m3u8` URL. If Apple changes the web field or rate-limits the request, response remains `ok: true` with `status: "error"` or `status: "rate-limited"` and the app remains static.

- [ ] **Step 6: Manual app behavior check**

Check these cases:

1. Start an Apple Music track from an album known to have animated artwork.
2. Open the app player card.
3. Static art appears first.
4. Animated art fades in only after relay resolution and first video frame readiness.
5. Switch tracks quickly; old animated art does not appear on the new track.
6. Play a non-Apple-Music source; player card stays static.
7. Enable Reduce Motion; player card stays static.
8. Open an Apple Music album detail page; relay cache warms without visible UI blocking.
9. Return to now playing for the same album; registry or relay cache avoids repeated Apple scraping.

---

## Implementation Notes

- Keep all Apple AMP scraping logic inside `nas-relay`.
- Keep iOS failures silent and visual-only. No user-facing toast for animated artwork misses.
- Do not reuse animated URLs for static artwork, widgets, Live Activities, or Hue.
- Do not log bearer tokens or full video URLs at info level.
- Treat Apple web response shape as unstable. Unknown fields should produce `status: "miss"` or `status: "error"` without crashing relay.
- Prefer `squareUrl` for the player card. Use `tallUrl` only when square is absent.
- Keep album detail in prewarm-only mode until player card behavior is visually verified.
