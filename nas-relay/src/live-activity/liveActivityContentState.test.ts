import assert from 'node:assert/strict';
import http from 'node:http';
import { test } from 'node:test';
import jpeg from 'jpeg-js';
import pino from 'pino';
import { PNG } from 'pngjs';

import {
  buildLiveActivityContentState,
  hashLiveActivityContentState,
} from './liveActivityContentState.js';
import type { SonosGroupSnapshot } from '../types.js';

test('Live Activity content state embeds fetched album art as a push-sized high-density JPEG thumbnail', async () => {
  const state = await buildLiveActivityContentState(snapshot({
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1',
  }), {
    fetchAlbumArt: async () => makeDetailedPng(400, 400),
  });

  assert.ok(state.albumArtThumbnail);
  const thumbnail = Buffer.from(state.albumArtThumbnail, 'base64');
  assert.equal(thumbnail[0], 0xff);
  assert.equal(thumbnail[1], 0xd8);
  const decoded = jpeg.decode(thumbnail, { useTArray: true });
  assert.ok(decoded.width >= 112);
  assert.equal(decoded.width, decoded.height);
  assert.ok(thumbnail.length > 0);
  assert.ok(thumbnail.length <= 2_500);
  assert.ok(estimatedLiveActivityPayloadBytes(state) <= 4_096);
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

test('Live Activity album art fetches public Apple Music artwork URLs', async () => {
  let requestedUri: string | null = null;
  const albumArtUri = 'https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/fc/db/cover.jpg/600x600bb.jpg';

  const state = await buildLiveActivityContentState(snapshot({ albumArtUri }), {
    fetchAlbumArt: async uri => {
      requestedUri = uri;
      return makeSolidPng(96, 96);
    },
  });

  assert.equal(requestedUri, albumArtUri);
  assert.ok(state.albumArtThumbnail);
  assert.match(state.dominantColorHex ?? '', /^#[0-9A-F]{6}$/);
});

test('Live Activity content state carries an artwork trace id through album art logs', async () => {
  const { logger, lines } = captureLogger();
  const albumArtUri = 'http://192.168.50.25:1400/getaa?s=trace';

  const state = await buildLiveActivityContentState(snapshot({ albumArtUri }), {
    logger,
    logContext: { trigger: 'unit-test' },
    fetchAlbumArt: async () => makeSolidPng(96, 96),
  });

  assert.match(state.artworkTraceId ?? '', /^art_[0-9a-f]{12}$/);
  const albumArtLog = lines.map(parseLogLine).find(entry => entry?.action === 'album-art');

  assert.equal(albumArtLog?.status, 'resolved');
  assert.equal(albumArtLog?.trigger, 'unit-test');
  assert.equal(albumArtLog?.artworkTraceId, state.artworkTraceId);
  assert.equal(albumArtLog?.thumbnailBytes, Buffer.byteLength(state.albumArtThumbnail ?? '', 'base64'));
  assert.equal(albumArtLog?.thumbnailBase64Length, state.albumArtThumbnail?.length);
});

test('Live Activity album art success diagnostics stay at debug level', async () => {
  const { logger, lines } = captureLogger();
  const albumArtUri = 'http://192.168.50.25:1400/getaa?s=debug';

  await buildLiveActivityContentState(snapshot({ albumArtUri }), {
    logger,
    logContext: { trigger: 'sonos-change' },
    fetchAlbumArt: async () => makeSolidPng(96, 96),
  });

  const albumArtLog = lines.map(parseLogLine).find(entry => entry?.action === 'album-art');
  assert.equal(albumArtLog?.status, 'resolved');
  assert.equal(albumArtLog?.level, 20);
});

test('Live Activity album art fetches getaa once for the same song', async () => {
  let fetchCalls = 0;
  const dependencies = {
    fetchAlbumArt: async () => {
      fetchCalls += 1;
      return makeSolidPng(96, 96);
    },
  };
  const albumArtUri = 'http://192.168.50.25:1400/getaa?s=once&u=x-sonos-http%3atrack';

  const firstState = await buildLiveActivityContentState(snapshot({ albumArtUri }), dependencies);
  const secondState = await buildLiveActivityContentState(snapshot({ albumArtUri }), dependencies);

  assert.ok(firstState.albumArtThumbnail);
  assert.equal(secondState.albumArtThumbnail, firstState.albumArtThumbnail);
  assert.equal(fetchCalls, 1);
});

test('Live Activity album art fetches again when the song changes behind the same getaa URL', async () => {
  let fetchCalls = 0;
  const dependencies = {
    fetchAlbumArt: async () => {
      fetchCalls += 1;
      return makeSolidPng(96, 96);
    },
  };
  const albumArtUri = 'http://192.168.50.25:1400/getaa?s=current';

  await buildLiveActivityContentState(snapshot({
    albumArtUri,
    trackTitle: 'Blue Train',
  }), dependencies);
  await buildLiveActivityContentState(snapshot({
    albumArtUri,
    trackTitle: 'Naima',
  }), dependencies);

  assert.equal(fetchCalls, 2);
});

test('Live Activity album art fetches the same getaa URL again after a song change', async () => {
  let requestCount = 0;
  const server = http.createServer((_req, res) => {
    requestCount += 1;
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
  const albumArtUri = `http://127.0.0.1:${address.port}/getaa?s=current`;

  try {
    await buildLiveActivityContentState(snapshot({
      albumArtUri,
      trackTitle: 'Blue Train',
    }));
    await buildLiveActivityContentState(snapshot({
      albumArtUri,
      trackTitle: 'Naima',
    }));

    assert.equal(requestCount, 2);
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
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

test('Live Activity content hash ignores diagnostic artwork trace ids', () => {
  const first = hashLiveActivityContentState({
    ...baseContentState(),
    albumArtThumbnail: Buffer.from('cover').toString('base64'),
    artworkTraceId: 'art_111111111111',
  });
  const second = hashLiveActivityContentState({
    ...baseContentState(),
    albumArtThumbnail: Buffer.from('cover').toString('base64'),
    artworkTraceId: 'art_222222222222',
  });

  assert.equal(first, second);
});

test('Live Activity content hash ignores playback progress changes', () => {
  const earlier = hashLiveActivityContentState({
    ...baseContentState(),
    positionSeconds: 42,
    startedAt: 802396758,
    endsAt: 802397058,
  });
  const later = hashLiveActivityContentState({
    ...baseContentState(),
    positionSeconds: 102,
    startedAt: 802396818,
    endsAt: 802397118,
  });

  assert.equal(earlier, later);
});

test('Live Activity content hash changes when the group member count changes', () => {
  const standalone = hashLiveActivityContentState({
    ...baseContentState(),
    groupMemberCount: 1,
  });
  const grouped = hashLiveActivityContentState({
    ...baseContentState(),
    groupMemberCount: 2,
  });

  assert.notEqual(standalone, grouped);
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

test('Live Activity content state carries the audio quality label', async () => {
  const state = await buildLiveActivityContentState(snapshot({
    audioQualityLabel: 'Dolby Atmos · MAT',
  }));

  assert.equal(state.audioQualityLabel, 'Dolby Atmos · MAT');
});

test('Live Activity content hash changes when the audio quality label changes', () => {
  const lossless = hashLiveActivityContentState({
    ...baseContentState(),
    audioQualityLabel: 'Lossless',
  });
  const atmos = hashLiveActivityContentState({
    ...baseContentState(),
    audioQualityLabel: 'Dolby Atmos · MAT',
  });

  assert.notEqual(lossless, atmos);
});

test('Live Activity album art extraction retries a transient failed fetch for the same song', async () => {
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

test('Live Activity album art uses fallback artwork when the primary getaa fetch fails', async () => {
  const { logger, lines } = captureLogger();
  const primaryUri = 'http://192.168.50.25:1400/getaa?s=primary';
  const fallbackUri = 'https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/fallback/600x600bb.jpg';
  const requested: string[] = [];

  const state = await buildLiveActivityContentState(snapshot({
    albumArtUri: primaryUri,
    albumArtFallbackUri: fallbackUri,
  }), {
    logger,
    logContext: { trigger: 'unit-test' },
    fetchAlbumArt: async uri => {
      requested.push(uri);
      if (uri === primaryUri) throw new Error('speaker getaa timed out');
      return makeSolidPng(96, 96);
    },
  });

  assert.deepEqual(requested, [primaryUri, fallbackUri]);
  assert.ok(state.albumArtThumbnail);
  assert.match(state.dominantColorHex ?? '', /^#[0-9A-F]{6}$/);
  assert.equal(lines.some(line =>
    line.includes('"msg":"live activity album art"')
    && line.includes('"status":"fallback-resolved"')
    && line.includes('"trigger":"unit-test"')
    && line.includes('"speaker getaa timed out"')
  ), true);
});

test('Live Activity content state logs missing album art URI', async () => {
  const { logger, lines } = captureLogger();

  await buildLiveActivityContentState(snapshot({ albumArtUri: null }), {
    logger,
    logContext: { trigger: 'unit-test' },
  });

  assert.equal(lines.some(line =>
    line.includes('"msg":"live activity album art"')
    && line.includes('"status":"missing-uri"')
    && line.includes('"groupId":"192.168.50.25"')
    && line.includes('"trigger":"unit-test"')
  ), true);
});

test('Live Activity content state logs album art fetch failures', async () => {
  const { logger, lines } = captureLogger();

  await buildLiveActivityContentState(snapshot({
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=missing',
  }), {
    logger,
    logContext: { trigger: 'unit-test' },
    fetchAlbumArt: async () => {
      throw new Error('speaker returned 404');
    },
  });

  assert.equal(lines.some(line =>
    line.includes('"msg":"live activity album art"')
    && line.includes('"status":"failed"')
    && line.includes('"trigger":"unit-test"')
    && line.includes('"speaker returned 404"')
  ), true);
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

function makeDetailedPng(width: number, height: number): Buffer {
  const png = new PNG({ width, height });
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const index = (y * width + x) * 4;
      png.data[index] = (x * 3 + y) % 256;
      png.data[index + 1] = (x + y * 2) % 256;
      png.data[index + 2] = (192 + x - y) % 256;
      png.data[index + 3] = 255;
    }
  }
  return PNG.sync.write(png);
}

function estimatedLiveActivityPayloadBytes(state: ReturnType<typeof baseContentState>): number {
  return Buffer.byteLength(JSON.stringify({
    aps: {
      timestamp: 1_780_000_000,
      event: 'update',
      'content-state': state,
      'stale-date': 1_780_028_800,
    },
  }));
}

function captureLogger(): { logger: pino.Logger; lines: string[] } {
  const lines: string[] = [];
  const destination = {
    write: (line: string) => {
      lines.push(line);
    },
  };
  return { logger: pino({ level: 'debug' }, destination), lines };
}

function parseLogLine(line: string): Record<string, any> | null {
  try {
    return JSON.parse(line) as Record<string, any>;
  } catch {
    return null;
  }
}
