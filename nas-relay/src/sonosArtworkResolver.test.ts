import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  createSonosArtworkResolver,
  probeITunesArtwork,
  resolveSonosArtwork,
} from './sonosArtworkResolver.js';

test('Sonos artwork resolver keeps speaker getaa artwork without external lookups', async () => {
  const calls: string[] = [];
  const resolution = await resolveSonosArtwork({
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1&u=x-sonos-http%3atrack',
    playbackSourceRaw: 'appleMusic',
    artworkHints: { resolve: () => { calls.push('hint'); return 'https://cdn.example.com/hint.jpg'; } },
    itunes: {
      lookupArtworkURLString: async () => { calls.push('lookup'); return 'https://cdn.example.com/lookup.jpg'; },
      searchArtworkURLString: async () => { calls.push('search'); return 'https://cdn.example.com/search.jpg'; },
    },
  });

  assert.deepEqual(calls, []);
  assert.equal(resolution.source, 'getaa');
  assert.equal(resolution.url, 'http://192.168.50.25:1400/getaa?s=1&u=x-sonos-http%3atrack');
});

test('Sonos artwork resolver ignores public CDN artwork for relay-owned snapshots', async () => {
  const resolution = await resolveSonosArtwork({
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    albumArtUri: 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/moon/600x600bb.jpg',
    playbackSourceRaw: 'appleMusic',
  });

  assert.equal(resolution.source, 'none');
  assert.equal(resolution.url, null);
});

test('Sonos artwork resolver returns none when Sonos did not provide getaa artwork', async () => {
  const resolution = await resolveSonosArtwork({
    title: 'Blue Train',
    artist: 'John Coltrane',
    album: 'Blue Train',
    trackUri: 'x-file-cifs://nas/music/blue-train.flac',
    albumArtUri: null,
    playbackSourceRaw: 'library',
  });

  assert.equal(resolution.source, 'none');
  assert.equal(resolution.url, null);
});

test('Sonos artwork resolver logs an iTunes shadow lookup without replacing getaa artwork', async () => {
  const calls: string[] = [];
  const logs: Array<Record<string, unknown>> = [];
  const resolver = createSonosArtworkResolver({
    logger: {
      info: (fields: Record<string, unknown>, message: string) => {
        logs.push({ ...fields, message });
      },
      warn: (fields: Record<string, unknown>, message: string) => {
        logs.push({ ...fields, message });
      },
    },
    itunes: {
      lookupArtworkURLString: async (catalogID: string, countryCode?: string | null) => {
        calls.push(`lookup:${catalogID}:${countryCode}`);
        return 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/moon/600x600bb.jpg';
      },
      searchArtworkURLString: async () => {
        calls.push('search');
        return null;
      },
    },
    countryCode: 'US',
  });

  const resolution = await resolver.resolve({
    groupId: '192.168.50.25',
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1&u=x-sonos-http%3atrack',
    playbackSourceRaw: 'appleMusic',
  });
  await waitFor(() => logs.length > 0);

  assert.equal(resolution.source, 'getaa');
  assert.equal(resolution.url, 'http://192.168.50.25:1400/getaa?s=1&u=x-sonos-http%3atrack');
  assert.deepEqual(calls, ['lookup:1440857781:US']);
  assert.equal(logs[0]?.message, 'iTunes artwork shadow probe');
  assert.equal(logs[0]?.status, 'hit');
  assert.equal(logs[0]?.method, 'lookup');
  assert.equal(logs[0]?.catalogID, '1440857781');
  assert.equal(logs[0]?.resolvedAlbumArtUri, 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/moon/600x600bb.jpg');
});

test('iTunes shadow probe falls through to search after catalog lookup miss', async () => {
  const calls: string[] = [];
  const result = await probeITunesArtwork({
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1',
    playbackSourceRaw: 'appleMusic',
    countryCode: 'US',
    itunes: {
      lookupArtworkURLString: async catalogID => {
        calls.push(`lookup:${catalogID}`);
        return null;
      },
      searchArtworkURLString: async input => {
        calls.push(`search:${input.title}:${input.artist}:${input.album}:${input.countryCode}`);
        return 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/search/600x600bb.jpg';
      },
    },
  });

  assert.deepEqual(calls, ['lookup:1440857781', 'search:Moon:Daniel Caesar:Freudian:US']);
  assert.equal(result.status, 'hit');
  assert.equal(result.method, 'search');
  assert.equal(result.lookupStatus, 'miss');
  assert.equal(result.searchStatus, 'hit');
  assert.equal(result.url, 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/search/600x600bb.jpg');
});

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 0));
  }
}
