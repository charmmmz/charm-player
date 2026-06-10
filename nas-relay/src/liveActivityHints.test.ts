import assert from 'node:assert/strict';
import { test } from 'node:test';

import { LiveActivityHintStore } from './liveActivityHints.js';
import type { SonosGroupSnapshot } from './types.js';

test('Live Activity hints apply matching app-supplied audio quality when the relay snapshot has none', () => {
  const store = new LiveActivityHintStore();
  store.update({
    groupId: '192.168.50.25',
    trackTitle: 'Between the Bars',
    artist: 'Elliott Smith',
    album: 'Either/Or',
    playbackSourceRaw: 'appleMusic',
    audioQualityLabel: 'Lossless',
    liveActivityStyleRaw: 'widget',
  });

  const enriched = store.apply(snapshot({
    trackTitle: 'Between the Bars',
    artist: 'Elliott Smith',
    album: 'Either/Or',
    playbackSourceRaw: 'appleMusic',
    audioQualityLabel: null,
    liveActivityStyleRaw: null,
  }));

  assert.equal(enriched.audioQualityLabel, 'Lossless');
  assert.equal(enriched.liveActivityStyleRaw, 'widget');
});

test('Live Activity hints do not leak stale quality onto a different track', () => {
  const store = new LiveActivityHintStore();
  store.update({
    groupId: '192.168.50.25',
    trackTitle: 'Between the Bars',
    artist: 'Elliott Smith',
    album: 'Either/Or',
    audioQualityLabel: 'Lossless',
  });

  const enriched = store.apply(snapshot({
    trackTitle: 'Needle in the Hay',
    artist: 'Elliott Smith',
    album: 'Elliott Smith',
    audioQualityLabel: null,
  }));

  assert.equal(enriched.audioQualityLabel, null);
});

test('Live Activity hint diagnostics name mismatched fields', () => {
  const store = new LiveActivityHintStore();
  store.update({
    groupId: '192.168.50.25',
    trackTitle: 'Between the Bars',
    artist: 'Elliott Smith',
    album: 'Either/Or',
    playbackSourceRaw: 'appleMusic',
    audioQualityLabel: 'Lossless',
  });

  const result = store.applyWithDiagnostics(snapshot({
    trackTitle: 'Needle in the Hay',
    artist: 'Elliott Smith',
    album: 'Elliott Smith',
    playbackSourceRaw: 'appleMusic',
    audioQualityLabel: null,
  }));

  assert.equal(result.diagnostic.reason, 'mismatch');
  assert.deepEqual(result.diagnostic.mismatches, ['trackTitle', 'album']);
  assert.equal(result.diagnostic.hintAudioQualityLabel, 'Lossless');
  assert.equal(result.diagnostic.snapshotAudioQualityLabel, null);
});

test('Live Activity hints keep relay-detected audio quality when both are present', () => {
  const store = new LiveActivityHintStore();
  store.update({
    groupId: '192.168.50.25',
    trackTitle: 'Blue Train',
    artist: 'John Coltrane',
    album: 'Blue Train',
    audioQualityLabel: 'Lossless',
  });

  const enriched = store.apply(snapshot({
    trackTitle: 'Blue Train',
    artist: 'John Coltrane',
    album: 'Blue Train',
    audioQualityLabel: 'Hi-Res Lossless',
  }));

  assert.equal(enriched.audioQualityLabel, 'Hi-Res Lossless');
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
