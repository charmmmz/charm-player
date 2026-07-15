import assert from 'node:assert/strict';
import { test } from 'node:test';

import { snapshotJson } from './relaySnapshotJson.js';
import type { SonosGroupSnapshot } from '../types.js';

test('relay snapshot JSON includes TV soundbar state for command responses', () => {
  const json = snapshotJson(snapshot({
    playbackSourceRaw: 'tv',
    audioQualityLabel: 'Dolby Atmos · MAT',
    soundbarNightMode: true,
    soundbarSpeechEnhancementRawLevel: 3,
    groupVolume: 34,
  }));

  assert.equal(json.playbackSourceRaw, 'tv');
  assert.equal(json.audioQualityLabel, 'Dolby Atmos · MAT');
  assert.equal(json.soundbarNightMode, true);
  assert.equal(json.soundbarSpeechEnhancementRawLevel, 3);
  assert.equal(json.groupVolume, 34);
});

function snapshot(overrides: Partial<SonosGroupSnapshot> = {}): SonosGroupSnapshot {
  return {
    groupId: '192.168.50.25',
    speakerName: 'Playroom',
    trackTitle: 'TV',
    artist: 'Live audio',
    album: '',
    albumArtUri: null,
    isPlaying: true,
    playbackSourceRaw: 'tv',
    positionSeconds: 0,
    durationSeconds: 0,
    groupMemberCount: 1,
    sampledAt: new Date('2026-06-17T00:00:00Z'),
    ...overrides,
  };
}
