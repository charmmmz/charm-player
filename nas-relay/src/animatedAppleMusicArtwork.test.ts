import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  AnimatedAppleMusicArtworkResolver,
  parseAppleMusicAlbumURL,
} from './animatedAppleMusicArtwork.js';

test('parses Apple Music album and song URLs to storefront album ids', () => {
  assert.deepEqual(
    parseAppleMusicAlbumURL('https://music.apple.com/us/album/name/1547315522'),
    { storefront: 'us', albumId: '1547315522' },
  );
  assert.deepEqual(
    parseAppleMusicAlbumURL('https://music.apple.com/us/album/name/1547315522?i=1547315524'),
    { storefront: 'us', albumId: '1547315522' },
  );
  assert.deepEqual(
    parseAppleMusicAlbumURL('https://music.apple.com/us/album/name/1547315522?i=9999999999'),
    { storefront: 'us', albumId: '1547315522' },
  );
  assert.equal(parseAppleMusicAlbumURL('https://music.apple.com/us/song/name/1547315524'), null);
  assert.equal(parseAppleMusicAlbumURL('https://example.com/us/album/name/1547315522'), null);
});

test('extracts square and tall animated artwork URLs from editorialVideo fixture', async () => {
  const dir = await tempDir();
  try {
    const requested: string[] = [];
    const fetchedPlaylists: string[] = [];
    const resolver = new AnimatedAppleMusicArtworkResolver({
      dataDir: dir,
      fetchBearerToken: async () => 'token',
      fetchJson: async (url, token) => {
        requested.push(url.toString());
        assert.equal(token, 'token');
        return ampAlbumFixture({
          square: 'https://cdn.example.com/square.m3u8',
          tall: 'https://cdn.example.com/tall.m3u8',
        });
      },
      fetchText: async url => {
        fetchedPlaylists.push(url.toString());
        if (url.toString() === 'https://cdn.example.com/square.m3u8') {
          return hlsMasterPlaylist('1080x1080');
        }
        if (url.toString() === 'https://cdn.example.com/tall.m3u8') {
          return hlsMasterPlaylist('1080x1440');
        }
        throw new Error(`unexpected playlist fetch: ${url.toString()}`);
      },
    });

    const result = await resolver.resolveByURL('https://music.apple.com/us/album/name/1547315522');

    assert.equal(result.status, 'hit');
    assert.equal(result.source, 'url');
    assert.equal(result.artist, 'Daniel Caesar');
    assert.equal(result.album, 'Freudian');
    assert.equal(result.appleMusicUrl, 'https://music.apple.com/us/album/freudian/1547315522');
    assert.equal(result.squareUrl, 'https://cdn.example.com/square.m3u8');
    assert.equal(result.tallUrl, 'https://cdn.example.com/tall.m3u8');
    assert.equal(result.squareWidth, 1080);
    assert.equal(result.squareHeight, 1080);
    assert.equal(result.squareAspectRatio, 1);
    assert.equal(result.tallWidth, 1080);
    assert.equal(result.tallHeight, 1440);
    assert.equal(result.tallAspectRatio, 0.75);
    assert.deepEqual(fetchedPlaylists, [
      'https://cdn.example.com/square.m3u8',
      'https://cdn.example.com/tall.m3u8',
    ]);
    assert.equal(new URL(requested[0] ?? '').pathname, '/v1/catalog/us/albums/1547315522');
    assert.equal(new URL(requested[0] ?? '').searchParams.get('extend'), 'editorialVideo');
    assert.equal(new URL(requested[0] ?? '').searchParams.get('platform'), 'web');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('caches confirmed no-video misses as negative-cache entries without another fetch', async () => {
  const dir = await tempDir();
  try {
    let fetchCount = 0;
    const now = 50_000;
    const resolver = new AnimatedAppleMusicArtworkResolver({
      dataDir: dir,
      now: () => now,
      fetchBearerToken: async () => 'token',
      fetchJson: async () => {
        fetchCount += 1;
        return ampAlbumFixture({});
      },
    });

    const first = await resolver.resolveByURL('https://music.apple.com/us/album/name/1547315522');
    const second = await resolver.resolveByURL('https://music.apple.com/us/album/name/1547315522');

    assert.equal(first.status, 'miss');
    assert.equal(first.source, 'none');
    assert.equal(second.status, 'negative-cache');
    assert.equal(second.source, 'cache');
    assert.equal(fetchCount, 1);

    const cache = await readCache(dir);
    assert.equal(cache.entries['album:us:1547315522'].status, 'miss');
    assert.equal(cache.entries['album:us:1547315522'].expiresAt, now + days(30));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('backs off globally across resolver instances after upstream 429 or 403 without fetching again', async () => {
  const dir = await tempDir();
  try {
    let fetchCount = 0;
    let tokenCount = 0;
    const firstResolver = new AnimatedAppleMusicArtworkResolver({
      dataDir: dir,
      now: () => 1_000,
      backoffMs: 500,
      fetchBearerToken: async () => 'token',
      fetchJson: async () => {
        fetchCount += 1;
        const error = new Error('rate limited') as Error & { status: number };
        error.status = 429;
        throw error;
      },
    });
    const secondResolver = new AnimatedAppleMusicArtworkResolver({
      dataDir: dir,
      now: () => 1_200,
      fetchBearerToken: async () => {
        tokenCount += 1;
        return 'token';
      },
      fetchJson: async () => {
        fetchCount += 1;
        return ampAlbumFixture({ square: 'https://cdn.example.com/other.m3u8' });
      },
    });

    const first = await firstResolver.resolveByURL('https://music.apple.com/us/album/name/1547315522');
    const second = await secondResolver.resolveByURL('https://music.apple.com/us/album/other/1660000000');

    assert.equal(first.status, 'rate-limited');
    assert.equal(first.source, 'none');
    assert.equal(second.status, 'rate-limited');
    assert.equal(second.source, 'none');
    assert.equal(fetchCount, 1);
    assert.equal(tokenCount, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('metadata search resolves to an album URL before fetching animated artwork', async () => {
  const dir = await tempDir();
  try {
    const searches: Array<{ artist: string; album: string; country: string }> = [];
    const resolver = new AnimatedAppleMusicArtworkResolver({
      dataDir: dir,
      fetchBearerToken: async () => 'token',
      searchAppleMusicAlbumURL: async (artist, album, country) => {
        searches.push({ artist, album, country });
        return 'https://music.apple.com/gb/album/freudian/1547315522';
      },
      fetchJson: async () => ampAlbumFixture({ square: 'https://cdn.example.com/square.m3u8' }),
    });

    const result = await resolver.resolveByMetadata(' Daniel Caesar ', ' Freudian ', 'gb');

    assert.equal(result.status, 'hit');
    assert.equal(result.source, 'metadata-search');
    assert.equal(result.squareUrl, 'https://cdn.example.com/square.m3u8');
    assert.deepEqual(searches, [{ artist: 'Daniel Caesar', album: 'Freudian', country: 'GB' }]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('metadata no-match misses are persisted under metadata keys for seven days', async () => {
  const dir = await tempDir();
  try {
    const now = 80_000;
    const resolver = new AnimatedAppleMusicArtworkResolver({
      dataDir: dir,
      now: () => now,
      searchAppleMusicAlbumURL: async () => null,
    });

    const result = await resolver.resolveByMetadata(' Daniel Caesar ', ' Freudian ', 'gb');

    assert.equal(result.status, 'miss');
    const cache = await readCache(dir);
    assert.equal(cache.entries['metadata:daniel caesar:freudian:GB'].status, 'miss');
    assert.equal(cache.entries['metadata:daniel caesar:freudian:GB'].expiresAt, now + days(7));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('default metadata search uses iTunes Search API matching before animated artwork lookup', async () => {
  const dir = await tempDir();
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = async () => {
      throw new Error('default metadata search should use injected fetchText');
    };
    const requested: string[] = [];
    const token = 'A'.repeat(60);
    const resolver = new AnimatedAppleMusicArtworkResolver({
      dataDir: dir,
      fetchText: async url => {
        requested.push(url.toString());
        if (url.hostname === 'itunes.apple.com') {
          return JSON.stringify({
            resultCount: 2,
            results: [
              {
                artistName: 'Different Artist',
                collectionName: 'Freudian',
                collectionViewUrl: 'https://music.apple.com/us/album/wrong/100',
              },
              {
                artistName: 'Daniel Caesar',
                collectionName: 'Freudian',
                collectionViewUrl: 'https://music.apple.com/us/album/freudian/1547315522?uo=4',
              },
            ],
          });
        }
        if (url.toString() === 'https://music.apple.com/') {
          return '<script src="/assets/token.js"></script>';
        }
        if (url.toString() === 'https://music.apple.com/assets/token.js') {
          return `const bearerToken="${token}";`;
        }
        throw new Error(`unexpected text fetch: ${url.toString()}`);
      },
      fetchJson: async (url, bearerToken) => {
        assert.equal(url.pathname, '/v1/catalog/us/albums/1547315522');
        assert.equal(bearerToken, token);
        return ampAlbumFixture({ square: 'https://cdn.example.com/default-search-square.m3u8' });
      },
    });

    const result = await resolver.resolveByMetadata('Daniel Caesar', 'Freudian', 'us');

    assert.equal(result.status, 'hit');
    assert.equal(result.source, 'metadata-search');
    assert.equal(result.squareUrl, 'https://cdn.example.com/default-search-square.m3u8');
    const searchURL = requested.find(value => value.startsWith('https://itunes.apple.com/search?'));
    assert(searchURL);
    assert.equal(new URL(searchURL).searchParams.get('entity'), 'album');
    assert.equal(new URL(searchURL).searchParams.get('country'), 'US');
  } finally {
    globalThis.fetch = originalFetch;
    await rm(dir, { recursive: true, force: true });
  }
});

test('disabled mode returns disabled without network access', async () => {
  const dir = await tempDir();
  try {
    let fetchCount = 0;
    const resolver = new AnimatedAppleMusicArtworkResolver({
      dataDir: dir,
      enabled: false,
      fetchBearerToken: async () => {
        fetchCount += 1;
        return 'token';
      },
      fetchJson: async () => {
        fetchCount += 1;
        return ampAlbumFixture({ square: 'https://cdn.example.com/square.m3u8' });
      },
    });

    const result = await resolver.resolveByURL('https://music.apple.com/us/album/name/1547315522');

    assert.equal(result.status, 'disabled');
    assert.equal(result.source, 'none');
    assert.equal(result.squareUrl, null);
    assert.equal(fetchCount, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('default bearer token extraction fetches only same-origin Apple Music JavaScript assets', async () => {
  const dir = await tempDir();
  try {
    const fetchedTextURLs: string[] = [];
    const token = 'B'.repeat(60);
    const resolver = new AnimatedAppleMusicArtworkResolver({
      dataDir: dir,
      fetchText: async url => {
        fetchedTextURLs.push(url.toString());
        if (url.toString() === 'https://music.apple.com/') {
          return [
            '<script src="https://tracking.example.com/not-apple.js"></script>',
            '<script src="/assets/apple-music.js"></script>',
          ].join('');
        }
        if (url.toString() === 'https://music.apple.com/assets/apple-music.js') {
          return `window.AppleMusic = { bearerToken: "${token}" };`;
        }
        throw new Error(`unexpected text fetch: ${url.toString()}`);
      },
      fetchJson: async (_url, bearerToken) => {
        assert.equal(bearerToken, token);
        return ampAlbumFixture({ square: 'https://cdn.example.com/square.m3u8' });
      },
    });

    const result = await resolver.resolveByURL('https://music.apple.com/us/album/name/1547315522');

    assert.equal(result.status, 'hit');
    assert.deepEqual(fetchedTextURLs.slice(0, 2), [
      'https://music.apple.com/',
      'https://music.apple.com/assets/apple-music.js',
    ]);
    assert.equal(fetchedTextURLs[2], 'https://cdn.example.com/square.m3u8');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('default bearer token extraction accepts bare Apple Music JWTs from same-origin scripts', async () => {
  const dir = await tempDir();
  try {
    const token = testAppleJWT();
    const resolver = new AnimatedAppleMusicArtworkResolver({
      dataDir: dir,
      fetchText: async url => {
        if (url.toString() === 'https://music.apple.com/') {
          return '<script src="/assets/index.js"></script>';
        }
        if (url.toString() === 'https://music.apple.com/assets/index.js') {
          return `const unrelated="value";const webPlayToken="${token}";`;
        }
        throw new Error(`unexpected text fetch: ${url.toString()}`);
      },
      fetchJson: async (_url, bearerToken) => {
        assert.equal(bearerToken, token);
        return ampAlbumFixture({ square: 'https://cdn.example.com/square.m3u8' });
      },
    });

    const result = await resolver.resolveByURL('https://music.apple.com/us/album/name/1547315522');

    assert.equal(result.status, 'hit');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

async function tempDir(): Promise<string> {
  return await mkdtemp(path.join(tmpdir(), 'animated-artwork-'));
}

async function readCache(dir: string): Promise<{
  entries: Record<string, { status: string; expiresAt: number }>;
}> {
  return JSON.parse(await readFile(path.join(dir, 'animated-artwork-cache.json'), 'utf8')) as {
    entries: Record<string, { status: string; expiresAt: number }>;
  };
}

function days(value: number): number {
  return value * 24 * 60 * 60 * 1_000;
}

function hlsMasterPlaylist(resolution: string): string {
  return [
    '#EXTM3U',
    '#EXT-X-VERSION:7',
    `#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=${resolution},CODECS="hvc1.2.20000000.L123.B0"`,
    'video.m3u8',
  ].join('\n');
}

function testAppleJWT(): string {
  return [
    Buffer.from(JSON.stringify({ typ: 'JWT', alg: 'ES256', kid: 'WebPlayKid' })).toString('base64url'),
    Buffer.from(JSON.stringify({
      iss: 'AMPWebPlay',
      exp: 9_999_999_999,
      root_https_origin: ['apple.com'],
    })).toString('base64url'),
    'signaturePart1234567890',
  ].join('.');
}

function ampAlbumFixture(urls: { square?: string; tall?: string }): unknown {
  return {
    data: [
      {
        attributes: {
          artistName: 'Daniel Caesar',
          name: 'Freudian',
          url: 'https://music.apple.com/us/album/freudian/1547315522',
          editorialVideo: {
            motionDetailSquare: {
              video: urls.square ? `not-a-url,${urls.square},https://cdn.example.com/poster.jpg` : '',
            },
            motionDetailTall: {
              video: urls.tall ?? 'ftp://cdn.example.com/tall.m3u8',
            },
          },
        },
      },
    ],
  };
}
