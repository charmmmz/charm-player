import assert from 'node:assert/strict';
import { test } from 'node:test';
import pino from 'pino';

import {
  ApnsClient,
  apnsStatusFromConfig,
  liveActivityNotificationPayloadBytes,
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
  artworkTraceId: 'art_trace123456',
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
    alert: {
      title: 'Blue Monday',
      body: 'New Order on Playroom',
    },
  });
});

test('liveActivityNotificationPayloadBytes measures the serialized APNs payload', () => {
  const note = makeLiveActivityStartNotification(
    baseConfig.bundleId,
    startAttributes,
    contentState,
    1_800_000_000,
  );

  assert.equal(
    liveActivityNotificationPayloadBytes(note),
    Buffer.byteLength(JSON.stringify({ aps: note.aps }), 'utf8'),
  );
});

test('pushUpdate dry-run logs payload bytes with the artwork trace id', async () => {
  const { logger, lines } = captureLogger();
  const client = await ApnsClient.create({
    ...baseConfig,
    keyId: '',
    teamId: '',
  }, logger);

  assert.deepEqual(
    await client.pushUpdate(['update-token-1'], contentState),
    { sent: 1, failed: 0, unregistered: [] },
  );

  const payloadLog = lines.map(parseLogLine).find(entry =>
    entry?.action === 'apns-dry-run' && entry?.event === 'update');
  assert.equal(payloadLog?.tokens, 1);
  assert.equal(typeof payloadLog?.payloadBytes, 'number');
  assert.equal(payloadLog?.state?.artworkTraceId, 'art_trace123456');
  assert.equal(payloadLog?.state?.artBytes, 3);
});

test('pushUpdate retries APNs write timeouts before reporting failure', async () => {
  const { logger } = captureLogger();
  let attempts = 0;
  const client = apnsClientWithProvider(logger, {
    send: async () => {
      attempts += 1;
      if (attempts === 1) {
        return {
          sent: [],
          failed: [{
            device: 'update-token-1',
            error: new Error('apn write timeout'),
          }],
        };
      }
      return {
        sent: [{ device: 'update-token-1' }],
        failed: [],
      };
    },
  });

  (client as any).retryDelaysMs = [0, 0];

  assert.deepEqual(
    await client.pushUpdate(['update-token-1'], contentState),
    { sent: 1, failed: 0, unregistered: [] },
  );
  assert.equal(attempts, 2);
});

test('pushUpdate does not retry APNs unregistered token failures', async () => {
  const { logger } = captureLogger();
  let attempts = 0;
  const client = apnsClientWithProvider(logger, {
    send: async () => {
      attempts += 1;
      return {
        sent: [],
        failed: [{
          device: 'update-token-1',
          status: 410,
          response: { reason: 'Unregistered' },
        }],
      };
    },
  });

  (client as any).retryDelaysMs = [0, 0];

  assert.deepEqual(
    await client.pushUpdate(['update-token-1'], contentState),
    { sent: 0, failed: 1, unregistered: ['update-token-1'] },
  );
  assert.equal(attempts, 1);
});

function captureLogger(): { logger: pino.Logger; lines: string[] } {
  const lines: string[] = [];
  const destination = {
    write: (line: string) => {
      lines.push(line);
    },
  };
  return { logger: pino({ level: 'info' }, destination), lines };
}

function parseLogLine(line: string): Record<string, any> | null {
  try {
    return JSON.parse(line) as Record<string, any>;
  } catch {
    return null;
  }
}

function apnsClientWithProvider(
  logger: pino.Logger,
  provider: { send: (note: unknown, tokens: string[]) => Promise<{ sent: any[]; failed: any[] }> },
): ApnsClient {
  const client = Object.create(ApnsClient.prototype) as any;
  client.config = baseConfig;
  client.apnsStatus = apnsStatusFromConfig(baseConfig, true);
  client.dryRun = false;
  client.log = logger.child({ module: 'apns' });
  client.provider = provider;
  return client as ApnsClient;
}

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
