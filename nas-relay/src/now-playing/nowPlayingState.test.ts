import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  buildNowPlayingAttributes,
  hashNowPlayingAttributes,
  isNowPlayingActive,
  NowPlayingSessionGenerationRegistry,
  nowPlayingArtworkURLs,
  shouldSendNowPlayingStart,
} from './nowPlayingState.js';
import type { NowPlayingTokenEntry, SonosGroupSnapshot } from '../types.js';

const target: NowPlayingTokenEntry = {
  kind: 'update',
  groupId: '192.168.50.25',
  token: 'update-token',
  sessionId: 'sonos:192.168.50.25',
  clientId: 'phone-a',
  speakerName: 'Playroom',
  relayURLString: 'http://192.168.50.10:8789',
  registeredAt: '2026-07-23T00:00:00.000Z',
};

const snapshot: SonosGroupSnapshot = {
  groupId: '192.168.50.25',
  speakerName: 'Playroom',
  trackTitle: 'Blue Monday',
  artist: 'New Order',
  album: 'Substance',
  trackUri: 'x-sonos-http:track-1',
  albumArtUri: 'http://192.168.50.25:1400/getaa?s=1&u=track-1',
  albumArtFallbackUri: 'https://is1-ssl.mzstatic.com/image/thumb/cover/1200x1200bb.jpg',
  isPlaying: true,
  transportStateRaw: 'PLAYING',
  groupVolume: 35,
  positionSeconds: 42,
  durationSeconds: 460,
  groupMemberCount: 1,
  sampledAt: new Date('2026-07-23T00:00:00.000Z'),
};

test('Now Playing prefers public high-resolution artwork and proxies Sonos getaa as fallback', () => {
  const urls = nowPlayingArtworkURLs(snapshot, target.relayURLString);
  assert.equal(urls.primary, snapshot.albumArtFallbackUri);
  assert.match(urls.fallback ?? '', /^http:\/\/192\.168\.50\.10:8789\/api\/artwork\?/);
  assert.match(urls.fallback ?? '', /url=http%3A%2F%2F192\.168\.50\.25%3A1400%2Fgetaa/);
});

test('Now Playing upgrades Apple Music artwork to 1200 pixels', () => {
  const urls = nowPlayingArtworkURLs({
    albumArtUri: 'http://192.168.1.10:1400/getaa?s=1&u=track',
    albumArtFallbackUri: 'https://is1-ssl.mzstatic.com/image/thumb/cover/600x600bb.jpg',
  }, 'http://relay.local:8789');

  assert.equal(
    urls.primary,
    'https://is1-ssl.mzstatic.com/image/thumb/cover/1200x1200bb.jpg',
  );
});

test('Now Playing uses relay proxy first and direct getaa second without public artwork', () => {
  const urls = nowPlayingArtworkURLs({
    albumArtUri: snapshot.albumArtUri,
    albumArtFallbackUri: null,
  }, target.relayURLString);
  assert.match(urls.primary ?? '', /\/api\/artwork\?/);
  assert.equal(urls.fallback, snapshot.albumArtUri);
});

test('Now Playing attributes use Unix timestamp, generation, and update token for commands', () => {
  const animatedArtworkURL = 'https://mvod.itunes.apple.com/artwork-square.m3u8';
  const attributes = buildNowPlayingAttributes(
    snapshot,
    target,
    animatedArtworkURL,
    'generation-a',
  );
  assert.equal(attributes.timestamp, snapshot.sampledAt.getTime() / 1000);
  assert.equal(attributes.elapsedTime, 42);
  assert.equal(attributes.duration, 460);
  assert.equal(attributes.volume, 0.35);
  assert.deepEqual(attributes.devices, [{
    id: snapshot.groupId,
    name: snapshot.speakerName,
    host: snapshot.groupId,
    volume: 0.35,
  }]);
  assert.equal(attributes.relayCommandToken, target.token);
  assert.equal(attributes.sessionGeneration, 'generation-a');
  assert.equal(attributes.artworkURLString, snapshot.albumArtFallbackUri);
  assert.equal(attributes.animatedArtworkURLString, animatedArtworkURL);
});

test('session generation is significant to a Now Playing update', () => {
  const first = buildNowPlayingAttributes(snapshot, target, null, 'generation-a');
  const second = buildNowPlayingAttributes(snapshot, target, null, 'generation-b');
  assert.notEqual(hashNowPlayingAttributes(first), hashNowPlayingAttributes(second));
});

test('session generation registry recovers, rotates, and ends playback generations', () => {
  const values = ['generated-a', 'generated-b'];
  const registry = new NowPlayingSessionGenerationRegistry(() => values.shift() ?? 'unexpected');
  assert.equal(registry.active(snapshot.groupId), 'generated-a');
  assert.equal(registry.active(snapshot.groupId), 'generated-a');
  assert.equal(registry.rotate(snapshot.groupId), 'generated-b');
  registry.end(snapshot.groupId);
  assert.equal(registry.current(snapshot.groupId), null);

  assert.equal(registry.current(snapshot.groupId, [{
    ...target,
    sessionGeneration: 'persisted-generation',
  }]), 'persisted-generation');
});

test('session generation recovery prefers the start token over a stale update token', () => {
  const registry = new NowPlayingSessionGenerationRegistry();
  assert.equal(registry.current(snapshot.groupId, [
    {
      ...target,
      kind: 'update',
      sessionGeneration: 'pre-reboot-generation',
    },
    {
      ...target,
      kind: 'start',
      token: 'start-token',
      sessionGeneration: 'recovered-generation',
    },
  ]), 'recovered-generation');
});

test('animated artwork identity changes are significant but absence stays omitted', () => {
  const withoutMotion = buildNowPlayingAttributes(snapshot, target);
  const withMotion = buildNowPlayingAttributes(
    snapshot,
    target,
    'https://mvod.itunes.apple.com/artwork-square.m3u8',
  );

  assert.equal(withoutMotion.animatedArtworkURLString, undefined);
  assert.notEqual(hashNowPlayingAttributes(withoutMotion), hashNowPlayingAttributes(withMotion));
});

test('Now Playing exposes every active Sonos group member and treats grouping as significant', () => {
  const grouped = buildNowPlayingAttributes({
    ...snapshot,
    groupMemberCount: 2,
    groupMembers: [
      {
        id: 'rincon-playroom',
        name: 'Playroom',
        host: '192.168.50.25',
        isCoordinator: true,
        volume: 35,
      },
      {
        id: 'rincon-move',
        name: 'Move',
        host: '192.168.50.26',
        isCoordinator: false,
        volume: 22,
      },
    ],
  }, target);
  const solo = buildNowPlayingAttributes(snapshot, target);

  assert.deepEqual(grouped.devices, [
    {
      id: 'rincon-playroom',
      name: 'Playroom',
      host: '192.168.50.25',
      volume: 0.35,
    },
    {
      id: 'rincon-move',
      name: 'Move',
      host: '192.168.50.26',
      volume: 0.22,
    },
  ]);
  assert.notEqual(hashNowPlayingAttributes(grouped), hashNowPlayingAttributes(solo));
});

test('progress-only sampling changes do not change the Now Playing push hash', () => {
  const first = buildNowPlayingAttributes(snapshot, target);
  const second = buildNowPlayingAttributes({
    ...snapshot,
    positionSeconds: 103,
    sampledAt: new Date('2026-07-23T00:01:01.000Z'),
  }, target);
  assert.equal(hashNowPlayingAttributes(first), hashNowPlayingAttributes(second));
  assert.notEqual(first.elapsedTime, second.elapsedTime);
});

test('paused playback remains an active media session while stopped playback ends it', () => {
  assert.equal(isNowPlayingActive({
    ...snapshot,
    isPlaying: false,
    transportStateRaw: 'PAUSED_PLAYBACK',
  }), true);
  assert.equal(isNowPlayingActive({
    ...snapshot,
    isPlaying: false,
    transportStateRaw: 'STOPPED',
  }), false);
});

test('Now Playing sends a start only when explicitly requested', () => {
  assert.equal(shouldSendNowPlayingStart('start', false, false), false);
  assert.equal(shouldSendNowPlayingStart('start', true, false), false);
  assert.equal(shouldSendNowPlayingStart('start', true, true), true);
  assert.equal(shouldSendNowPlayingStart('update', true, true), false);
});
