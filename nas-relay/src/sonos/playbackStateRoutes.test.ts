import assert from 'node:assert/strict';
import express from 'express';
import { test } from 'node:test';
import pino from 'pino';

import { createPlaybackStateRouter } from './playbackStateRoutes.js';
import type { SonosGroupSnapshot } from '../types.js';

test('playback state route returns the cached snapshot without pulling Sonos', async () => {
  const app = express();
  let currentCalls = 0;
  const source = {
    current(groupId: string): SonosGroupSnapshot | undefined {
      currentCalls += 1;
      assert.equal(groupId, '192.168.50.25');
      return snapshot();
    },
  };
  app.use('/api', createPlaybackStateRouter(source, pino({ enabled: false })));

  const server = app.listen(0);
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address === 'object');

  try {
    const response = await fetch(
      `http://127.0.0.1:${address.port}/api/playback-state?groupId=192.168.50.25`,
    );
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(currentCalls, 1);
    assert.equal(body.ok, true);
    assert.equal(body.source, 'cached');
    assert.equal(body.state.groupId, '192.168.50.25');
    assert.equal(body.state.trackTitle, 'Song A');
    assert.equal(body.state.trackUri, 'x-sonos-http:song%3a1440857781.mp4?sid=204');
    assert.equal(body.state.albumArtUri, 'http://192.168.50.25:1400/getaa?u=x');
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
    });
  }
});

function snapshot(overrides: Partial<SonosGroupSnapshot> = {}): SonosGroupSnapshot {
  return {
    groupId: '192.168.50.25',
    speakerName: 'Playroom',
    trackTitle: 'Song A',
    artist: 'Artist A',
    album: 'Album A',
    trackUri: 'x-sonos-http:song%3a1440857781.mp4?sid=204',
    albumArtUri: 'http://192.168.50.25:1400/getaa?u=x',
    isPlaying: true,
    playbackSourceRaw: 'appleMusic',
    audioQualityLabel: 'Lossless',
    positionSeconds: 42,
    durationSeconds: 240,
    groupMemberCount: 2,
    sampledAt: new Date('2026-06-18T00:00:00Z'),
    ...overrides,
  };
}
