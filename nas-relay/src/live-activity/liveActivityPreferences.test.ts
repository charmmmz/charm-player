import assert from 'node:assert/strict';
import { test } from 'node:test';

import { LiveActivityPreferenceStore } from './liveActivityPreferences.js';
import type { SonosGroupSnapshot } from '../types.js';

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

test('Live Activity preferences preserve style when updates omit it', () => {
  const store = new LiveActivityPreferenceStore();
  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: 'widget',
  });

  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: undefined,
  });

  const enriched = store.apply(snapshot({
    liveActivityStyleRaw: null,
  }));

  assert.equal(enriched.liveActivityStyleRaw, 'widget');
});

test('Live Activity preferences prioritize the app-selected group without changing other snapshots', () => {
  const store = new LiveActivityPreferenceStore();
  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: 'widget',
    selectedGroupId: '192.168.50.25',
  });

  const selected = store.apply(snapshot({
    groupId: '192.168.50.25',
    speakerName: 'Playroom',
    liveActivityStyleRaw: null,
  }));
  const other = store.apply(snapshot({
    groupId: '192.168.50.30',
    speakerName: 'Move',
    liveActivityStyleRaw: null,
  }));

  assert.equal(selected.liveActivityStyleRaw, 'widget');
  assert.equal(other.liveActivityStyleRaw, null);
  assert.equal(store.relevanceScoreForGroup('192.168.50.25'), 100);
  assert.equal(store.relevanceScoreForGroup('192.168.50.30'), 1);
});

test('Live Activity preferences keep selected group when later updates omit it', () => {
  const store = new LiveActivityPreferenceStore();
  store.update({
    groupId: '192.168.50.25',
    selectedGroupId: '192.168.50.25',
  });
  store.update({
    groupId: '192.168.50.30',
    liveActivityStyleRaw: 'classic',
  });

  assert.equal(store.relevanceScoreForGroup('192.168.50.25'), 100);
  assert.equal(store.relevanceScoreForGroup('192.168.50.30'), 1);
});

test('Live Activity preferences ignore app now playing hints for relay-owned snapshots', () => {
  const store = new LiveActivityPreferenceStore(() => 1_000);
  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: 'widget',
    nowPlaying: {
      trackTitle: 'Correct Radio Song',
      artist: 'Correct Artist',
      album: 'Correct Album',
      albumArtUri: 'https://example.com/correct.jpg',
      isPlaying: true,
      positionSeconds: 0,
      durationSeconds: 0,
      playbackSourceRaw: 'appleMusic',
      audioQualityLabel: 'Lossless',
    },
  });

  const enriched = store.apply(snapshot({
    trackTitle: 'Relay Radio Song',
    artist: 'Relay Artist',
    album: 'Relay Album',
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1&u=x-sonosapi-hls%3astation',
    playbackSourceRaw: 'appleMusic',
    audioQualityLabel: null,
    positionSeconds: 14,
    durationSeconds: 0,
    liveActivityStyleRaw: null,
  }));

  assert.equal(enriched.trackTitle, 'Relay Radio Song');
  assert.equal(enriched.artist, 'Relay Artist');
  assert.equal(enriched.album, 'Relay Album');
  assert.equal(enriched.albumArtUri, 'http://192.168.50.25:1400/getaa?s=1&u=x-sonosapi-hls%3astation');
  assert.equal(enriched.positionSeconds, 14);
  assert.equal(enriched.durationSeconds, 0);
  assert.equal(enriched.playbackSourceRaw, 'appleMusic');
  assert.equal(enriched.audioQualityLabel, null);
  assert.equal(enriched.liveActivityStyleRaw, 'widget');
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
