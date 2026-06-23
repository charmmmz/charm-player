import assert from 'node:assert/strict';
import { test } from 'node:test';

import { resolveSonosArtwork } from './sonosArtworkResolver.js';

test('Sonos artwork resolver keeps existing public artwork without lookups', async () => {
  const calls: string[] = [];
  const resolution = await resolveSonosArtwork({
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    albumArtUri: 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/moon/600x600bb.jpg',
    playbackSourceRaw: 'appleMusic',
    artworkHints: { resolve: () => { calls.push('hint'); return null; } },
    itunes: {
      lookupArtworkURLString: async () => { calls.push('lookup'); return null; },
      searchArtworkURLString: async () => { calls.push('search'); return null; },
    },
  });

  assert.deepEqual(calls, []);
  assert.equal(resolution.source, 'public');
  assert.equal(resolution.url, 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/moon/600x600bb.jpg');
});

test('Sonos artwork resolver applies app artwork hints before iTunes', async () => {
  const calls: string[] = [];
  const resolution = await resolveSonosArtwork({
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1',
    playbackSourceRaw: 'appleMusic',
    artworkHints: {
      resolve: input => {
        calls.push(`hint:${input.title}`);
        return 'https://cdn.example.com/hint.jpg';
      },
    },
    itunes: {
      lookupArtworkURLString: async () => { calls.push('lookup'); return null; },
      searchArtworkURLString: async () => { calls.push('search'); return null; },
    },
  });

  assert.deepEqual(calls, ['hint:Moon']);
  assert.equal(resolution.source, 'hint');
  assert.equal(resolution.url, 'https://cdn.example.com/hint.jpg');
});

test('Sonos artwork resolver uses iTunes lookup from Apple Music catalog id before search', async () => {
  const calls: string[] = [];
  const resolution = await resolveSonosArtwork({
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1',
    playbackSourceRaw: 'appleMusic',
    itunes: {
      lookupArtworkURLString: async (catalogID, countryCode) => {
        calls.push(`lookup:${catalogID}:${countryCode}`);
        return 'https://cdn.example.com/lookup.jpg';
      },
      searchArtworkURLString: async () => {
        calls.push('search');
        return 'https://cdn.example.com/search.jpg';
      },
    },
    countryCode: 'US',
  });

  assert.deepEqual(calls, ['lookup:1440857781:US']);
  assert.equal(resolution.source, 'itunesLookup');
  assert.equal(resolution.catalogID, '1440857781');
  assert.equal(resolution.url, 'https://cdn.example.com/lookup.jpg');
});

test('Sonos artwork resolver falls through to iTunes search after lookup miss', async () => {
  const calls: string[] = [];
  const resolution = await resolveSonosArtwork({
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204&flags=8232&sn=2',
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1',
    playbackSourceRaw: 'appleMusic',
    itunes: {
      lookupArtworkURLString: async catalogID => {
        calls.push(`lookup:${catalogID}`);
        return null;
      },
      searchArtworkURLString: async input => {
        calls.push(`search:${input.title}:${input.artist}:${input.album}`);
        return 'https://cdn.example.com/search.jpg';
      },
    },
  });

  assert.deepEqual(calls, ['lookup:1440857781', 'search:Moon:Daniel Caesar:Freudian']);
  assert.equal(resolution.source, 'itunesSearch');
  assert.equal(resolution.url, 'https://cdn.example.com/search.jpg');
});

test('Sonos artwork resolver extracts catalog id from getaa wrapped uri', async () => {
  const calls: string[] = [];
  const resolution = await resolveSonosArtwork({
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    trackUri: '',
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1&u=x-sonos-http%3Asong%253A1440857781.mp4%3Fsid%3D204%26flags%3D8232%26sn%3D2',
    playbackSourceRaw: 'appleMusic',
    itunes: {
      lookupArtworkURLString: async catalogID => {
        calls.push(`lookup:${catalogID}`);
        return 'https://cdn.example.com/lookup.jpg';
      },
      searchArtworkURLString: async () => null,
    },
  });

  assert.deepEqual(calls, ['lookup:1440857781']);
  assert.equal(resolution.source, 'itunesLookup');
  assert.equal(resolution.catalogID, '1440857781');
});

test('Sonos artwork resolver skips iTunes for non Apple Music getaa artwork', async () => {
  const calls: string[] = [];
  const resolution = await resolveSonosArtwork({
    title: 'Blue Train',
    artist: 'John Coltrane',
    album: 'Blue Train',
    trackUri: 'x-file-cifs://nas/music/blue-train.flac',
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1',
    playbackSourceRaw: 'library',
    itunes: {
      lookupArtworkURLString: async () => { calls.push('lookup'); return null; },
      searchArtworkURLString: async () => { calls.push('search'); return null; },
    },
  });

  assert.deepEqual(calls, []);
  assert.equal(resolution.source, 'getaa');
  assert.equal(resolution.url, 'http://192.168.50.25:1400/getaa?s=1');
});
