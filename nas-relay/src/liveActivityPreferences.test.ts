import assert from 'node:assert/strict';
import { test } from 'node:test';

import { LiveActivityPreferenceStore } from './liveActivityPreferences.js';
import type { SonosGroupSnapshot } from './types.js';

test('Live Activity preferences apply app-selected style to relay-owned snapshots', () => {
  const store = new LiveActivityPreferenceStore();
  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: 'widget',
  });

  const enriched = store.apply(snapshot({
    audioQualityLabel: 'Lossless',
    liveActivityStyleRaw: null,
  }));

  assert.equal(enriched.liveActivityStyleRaw, 'widget');
  assert.equal(enriched.audioQualityLabel, 'Lossless');
});

test('Live Activity preferences keep a style already present on the relay snapshot', () => {
  const store = new LiveActivityPreferenceStore();
  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: 'widget',
  });

  const enriched = store.apply(snapshot({
    liveActivityStyleRaw: 'classic',
  }));

  assert.equal(enriched.liveActivityStyleRaw, 'classic');
});

test('Live Activity preferences ignore blank style strings', () => {
  const store = new LiveActivityPreferenceStore();
  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: '   ',
  });

  const enriched = store.apply(snapshot({
    liveActivityStyleRaw: null,
  }));

  assert.equal(enriched.liveActivityStyleRaw, null);
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
