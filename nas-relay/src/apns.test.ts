import assert from 'node:assert/strict';
import { test } from 'node:test';
import pino from 'pino';

import {
  ApnsClient,
  apnsStatusFromConfig,
  makeLiveActivityStartNotification,
  type ApnsConfig,
} from './apns.js';
import type { LiveActivityContentState, LiveActivityStartAttributes } from './types.js';

const baseConfig: ApnsConfig = {
  bundleId: 'com.charm.SonosWidget',
  keyPath: '/app/data/apns.p8',
  keyId: 'ABCDEF1234',
  teamId: '3MSS7DJGVR',
  production: true,
};

test('APNs status is ready when key metadata and key file are present', () => {
  assert.deepEqual(apnsStatusFromConfig(baseConfig, true), {
    mode: 'ready',
    environment: 'production',
    bundleId: 'com.charm.SonosWidget',
    keyIdConfigured: true,
    teamIdConfigured: true,
    keyFilePresent: true,
    missing: [],
  });
});

test('APNs status is dry-run and reports missing key inputs', () => {
  assert.deepEqual(apnsStatusFromConfig({
    ...baseConfig,
    keyId: '',
    teamId: '',
    production: false,
  }, false), {
    mode: 'dry-run',
    environment: 'sandbox',
    bundleId: 'com.charm.SonosWidget',
    keyIdConfigured: false,
    teamIdConfigured: false,
    keyFilePresent: false,
    missing: ['APNS_KEY_ID', 'APNS_TEAM_ID', 'apns.p8'],
  });
});

const contentState: LiveActivityContentState = {
  trackTitle: 'Blue Monday',
  artist: 'New Order',
  album: 'Substance',
  isPlaying: true,
  positionSeconds: 42,
  durationSeconds: 460,
  dominantColorHex: '#0f766e',
  startedAt: 123,
  endsAt: 456,
  albumArtThumbnail: 'AQID',
  groupMemberCount: 2,
  playbackSourceRaw: 'lineIn',
  liveActivityStyleRaw: 'compact',
  audioQualityLabel: 'Lossless',
};

const startAttributes: LiveActivityStartAttributes = {
  speakerName: 'Playroom',
  groupId: '192.168.50.25',
};

test('makeLiveActivityStartNotification creates ActivityKit start payload', () => {
  const note = makeLiveActivityStartNotification(
    baseConfig.bundleId,
    startAttributes,
    contentState,
    1_800_000_000,
  );

  assert.equal(note.topic, 'com.charm.SonosWidget.push-type.liveactivity');
  assert.equal(note.pushType, 'liveactivity');
  assert.equal(note.expiry, 1_800_003_600);
  assert.deepEqual(note.aps, {
    timestamp: 1_800_000_000,
    'stale-date': 1_800_028_800,
    event: 'start',
    'attributes-type': 'SonosActivityAttributes',
    attributes: startAttributes,
    'content-state': contentState,
    'input-push-token': 1,
  });
});

test('pushStart dry-run returns all tokens as sent without provider', async () => {
  const client = await ApnsClient.create({
    ...baseConfig,
    keyId: '',
    teamId: '',
  }, pino({ enabled: false }));

  assert.deepEqual(
    await client.pushStart(['start-token-1', 'start-token-2'], startAttributes, contentState),
    { sent: 2, failed: 0, unregistered: [] },
  );
});
