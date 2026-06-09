import assert from 'node:assert/strict';
import http from 'node:http';
import { test } from 'node:test';
import { PNG } from 'pngjs';

import {
  buildLiveActivityContentState,
  hashLiveActivityContentState,
} from './liveActivityContentState.js';
import type { SonosGroupSnapshot } from './types.js';

test('Live Activity content state embeds fetched album art as a small base64 JPEG thumbnail', async () => {
  const state = await buildLiveActivityContentState(snapshot({
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1',
  }), {
    fetchAlbumArt: async () => makeSolidPng(96, 96),
  });

  assert.ok(state.albumArtThumbnail);
  const thumbnail = Buffer.from(state.albumArtThumbnail, 'base64');
  assert.equal(thumbnail[0], 0xff);
  assert.equal(thumbnail[1], 0xd8);
  assert.ok(thumbnail.length > 0);
  assert.ok(thumbnail.length <= 15 * 1024);
});

test('Live Activity content state derives a dominant theme color from fetched album art', async () => {
  const state = await buildLiveActivityContentState(snapshot({
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1',
  }), {
    fetchAlbumArt: async () => makeSolidPng(96, 96),
  });

  assert.match(state.dominantColorHex ?? '', /^#[0-9A-F]{6}$/);
  assert.notEqual(state.dominantColorHex, '#FFFFFF');
});

test('Live Activity content hash changes when album art becomes available', () => {
  const withoutArt = hashLiveActivityContentState({
    ...baseContentState(),
    albumArtThumbnail: null,
  });
  const withArt = hashLiveActivityContentState({
    ...baseContentState(),
    albumArtThumbnail: Buffer.from('cover').toString('base64'),
  });

  assert.notEqual(withoutArt, withArt);
});

test('Live Activity content hash changes when the dominant theme color changes', () => {
  const withoutColor = hashLiveActivityContentState({
    ...baseContentState(),
    dominantColorHex: null,
  });
  const withColor = hashLiveActivityContentState({
    ...baseContentState(),
    dominantColorHex: '#3366CC',
  });

  assert.notEqual(withoutColor, withColor);
});

test('Live Activity content state carries TV soundbar controls', async () => {
  const state = await buildLiveActivityContentState(snapshot({
    playbackSourceRaw: 'tv',
    soundbarNightMode: true,
    soundbarSpeechEnhancementRawLevel: 2,
  }));

  assert.equal(state.soundbarNightMode, true);
  assert.equal(state.soundbarSpeechEnhancementRawLevel, 2);
});

test('Live Activity content hash changes when TV soundbar controls change', () => {
  const nightOff = hashLiveActivityContentState({
    ...baseContentState(),
    playbackSourceRaw: 'tv',
    soundbarNightMode: false,
    soundbarSpeechEnhancementRawLevel: 1,
  });
  const nightOn = hashLiveActivityContentState({
    ...baseContentState(),
    playbackSourceRaw: 'tv',
    soundbarNightMode: true,
    soundbarSpeechEnhancementRawLevel: 1,
  });

  assert.notEqual(nightOff, nightOn);
});

test('Live Activity content state carries the selected presentation style', async () => {
  const state = await buildLiveActivityContentState(snapshot({
    liveActivityStyleRaw: 'widget',
  }));

  assert.equal(state.liveActivityStyleRaw, 'widget');
});

test('Live Activity content hash changes when the presentation style changes', () => {
  const classic = hashLiveActivityContentState({
    ...baseContentState(),
    liveActivityStyleRaw: 'classic',
  });
  const widget = hashLiveActivityContentState({
    ...baseContentState(),
    liveActivityStyleRaw: 'widget',
  });

  assert.notEqual(classic, widget);
});

test('Live Activity album art extraction retries after a transient fetch failure', async () => {
  let requestCount = 0;
  const server = http.createServer((_req, res) => {
    requestCount += 1;
    if (requestCount === 1) {
      res.writeHead(503);
      res.end('not ready');
      return;
    }

    const image = makeSolidPng(96, 96);
    res.writeHead(200, {
      'content-type': 'image/png',
      'content-length': image.length,
    });
    res.end(image);
  });

  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert(address && typeof address === 'object');
  const albumArtUri = `http://127.0.0.1:${address.port}/getaa?s=transient`;

  try {
    const failedState = await buildLiveActivityContentState(snapshot({ albumArtUri }));
    const recoveredState = await buildLiveActivityContentState(snapshot({ albumArtUri }));

    assert.equal(failedState.albumArtThumbnail, null);
    assert.equal(failedState.dominantColorHex, null);
    assert.ok(recoveredState.albumArtThumbnail);
    assert.match(recoveredState.dominantColorHex ?? '', /^#[0-9A-F]{6}$/);
    assert.equal(requestCount, 2);
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});

function snapshot(overrides: Partial<SonosGroupSnapshot> = {}): SonosGroupSnapshot {
  return {
    groupId: '192.168.50.25',
    speakerName: 'Office',
    trackTitle: 'Blue Train',
    artist: 'John Coltrane',
    album: 'Blue Train',
    albumArtUri: null,
    isPlaying: true,
    positionSeconds: 42,
    durationSeconds: 300,
    groupMemberCount: 1,
    sampledAt: new Date('2026-06-02T00:00:00Z'),
    ...overrides,
  };
}

function baseContentState() {
  return {
    trackTitle: 'Blue Train',
    artist: 'John Coltrane',
    album: 'Blue Train',
    isPlaying: true,
    positionSeconds: 42,
    durationSeconds: 300,
    dominantColorHex: null,
    startedAt: 802396758,
    endsAt: 802397058,
    groupMemberCount: 1,
    playbackSourceRaw: null,
  };
}

function makeSolidPng(width: number, height: number): Buffer {
  const png = new PNG({ width, height });
  for (let index = 0; index < png.data.length; index += 4) {
    png.data[index] = 24;
    png.data[index + 1] = 96;
    png.data[index + 2] = 210;
    png.data[index + 3] = 255;
  }
  return PNG.sync.write(png);
}
