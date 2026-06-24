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

test('Live Activity preferences use recent app now playing hints for live snapshots except artwork', () => {
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
    trackTitle: 'Apple Music 1',
    artist: 'Apple Music',
    album: 'Live Radio',
    albumArtUri: 'http://192.168.50.25:1400/getaa?s=1&u=x-sonosapi-hls%3astation',
    playbackSourceRaw: 'appleMusic',
    audioQualityLabel: null,
    positionSeconds: 14,
    durationSeconds: 0,
    liveActivityStyleRaw: null,
  }));

  assert.equal(enriched.trackTitle, 'Correct Radio Song');
  assert.equal(enriched.artist, 'Correct Artist');
  assert.equal(enriched.album, 'Correct Album');
  assert.equal(enriched.albumArtUri, 'http://192.168.50.25:1400/getaa?s=1&u=x-sonosapi-hls%3astation');
  assert.equal(enriched.positionSeconds, 0);
  assert.equal(enriched.durationSeconds, 0);
  assert.equal(enriched.playbackSourceRaw, 'appleMusic');
  assert.equal(enriched.audioQualityLabel, 'Lossless');
  assert.equal(enriched.liveActivityStyleRaw, 'widget');
});

test('Live Activity preferences ignore expired app now playing hints', () => {
  let now = 1_000;
  const store = new LiveActivityPreferenceStore(() => now);
  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: null,
    nowPlaying: {
      trackTitle: 'Correct Radio Song',
      artist: 'Correct Artist',
      durationSeconds: 0,
    },
  });

  now += 31_000;
  const enriched = store.apply(snapshot({
    trackTitle: 'Relay Radio Song',
    artist: 'Relay Artist',
    durationSeconds: 0,
  }));

  assert.equal(enriched.trackTitle, 'Relay Radio Song');
  assert.equal(enriched.artist, 'Relay Artist');
});

test('Live Activity preferences preserve app now playing hints when style updates omit them', () => {
  const store = new LiveActivityPreferenceStore(() => 1_000);
  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: null,
    nowPlaying: {
      trackTitle: 'Correct Radio Song',
      artist: 'Correct Artist',
      durationSeconds: 0,
    },
  });

  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: 'widget',
    nowPlaying: undefined,
  });

  const enriched = store.apply(snapshot({
    trackTitle: 'Relay Radio Song',
    artist: 'Relay Artist',
    durationSeconds: 0,
  }));

  assert.equal(enriched.trackTitle, 'Correct Radio Song');
  assert.equal(enriched.artist, 'Correct Artist');
  assert.equal(enriched.liveActivityStyleRaw, 'widget');
});

test('Live Activity preferences keep fixed-duration relay metadata over app hints', () => {
  const store = new LiveActivityPreferenceStore(() => 1_000);
  store.update({
    groupId: '192.168.50.25',
    liveActivityStyleRaw: null,
    nowPlaying: {
      trackTitle: 'Stale Radio Song',
      artist: 'Stale Artist',
      durationSeconds: 0,
    },
  });

  const enriched = store.apply(snapshot({
    trackTitle: 'Blue Train',
    artist: 'John Coltrane',
    durationSeconds: 300,
  }));

  assert.equal(enriched.trackTitle, 'Blue Train');
  assert.equal(enriched.artist, 'John Coltrane');
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
