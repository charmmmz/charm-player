import assert from 'node:assert/strict';
import { test } from 'node:test';

import { maybeStartLiveActivityForSnapshot } from './liveActivityStartCoordinator.js';
import type { ApnsResult } from './apns.js';
import type {
  LiveActivityContentState,
  LiveActivityStartAttributes,
  PushToStartTokenEntry,
  SonosGroupSnapshot,
  TokenEntry,
} from './types.js';

const snap: SonosGroupSnapshot = {
  groupId: '192.168.50.25',
  speakerName: 'Playroom',
  trackTitle: 'Blue Monday',
  artist: 'New Order',
  album: 'Substance',
  albumArtUri: null,
  isPlaying: true,
  positionSeconds: 42,
  durationSeconds: 460,
  groupMemberCount: 1,
  sampledAt: new Date('2026-06-24T08:00:00.000Z'),
};

const contentState: LiveActivityContentState = {
  trackTitle: 'Blue Monday',
  artist: 'New Order',
  album: 'Substance',
  isPlaying: true,
  positionSeconds: 42,
  durationSeconds: 460,
  groupMemberCount: 1,
};

const startToken: PushToStartTokenEntry = {
  groupId: '192.168.50.25',
  token: 'start-token-a',
  clientId: 'phone-a',
  speakerName: 'Playroom',
  registeredAt: '2026-06-24T07:00:00.000Z',
};

function activityToken(): TokenEntry {
  return {
    groupId: '192.168.50.25',
    token: 'activity-token',
    clientId: 'phone-a',
    activityId: 'activity-1',
    registeredAt: '2026-06-24T07:59:00.000Z',
  };
}

test('starts with Sonos attributes and content state when eligible', async () => {
  const pushed: Array<{
    tokens: string[];
    attributes: LiveActivityStartAttributes;
    state: LiveActivityContentState;
  }> = [];

  const result = await maybeStartLiveActivityForSnapshot({
    snap,
    startTokens: [startToken],
    activityTokens: [],
    buildState: async buildSnap => {
      assert.equal(buildSnap, snap);
      return contentState;
    },
    pushStart: async (tokens, attributes, state) => {
      pushed.push({ tokens, attributes, state });
      return { sent: tokens.length, failed: 0, unregistered: [] };
    },
    recordStart: () => {},
    unregisterStartToken: () => {},
    now: new Date('2026-06-24T08:00:00.000Z'),
  });

  assert.deepEqual(result, { reason: 'start', sent: 1, failed: 0 });
  assert.deepEqual(pushed, [
    {
      tokens: ['start-token-a'],
      attributes: { speakerName: 'Playroom', groupId: '192.168.50.25' },
      state: contentState,
    },
  ]);
});

test('does not build state or push when policy returns no targets due to activity token', async () => {
  let buildStateCalled = false;
  let pushStartCalled = false;

  const result = await maybeStartLiveActivityForSnapshot({
    snap,
    startTokens: [startToken],
    activityTokens: [activityToken()],
    buildState: async () => {
      buildStateCalled = true;
      return contentState;
    },
    pushStart: async () => {
      pushStartCalled = true;
      return { sent: 0, failed: 0, unregistered: [] };
    },
    recordStart: () => {},
    unregisterStartToken: () => {},
    now: new Date('2026-06-24T08:00:00.000Z'),
  });

  assert.deepEqual(result, { reason: 'activity-token-active', sent: 0, failed: 0 });
  assert.equal(buildStateCalled, false);
  assert.equal(pushStartCalled, false);
});

test('unregisters unregistered start tokens from APNs result', async () => {
  const unregistered: string[] = [];

  const result = await maybeStartLiveActivityForSnapshot({
    snap,
    startTokens: [
      { ...startToken, token: 'start-token-a' },
      { ...startToken, token: 'start-token-b' },
    ],
    activityTokens: [],
    buildState: async () => contentState,
    pushStart: async (): Promise<ApnsResult> => ({
      sent: 1,
      failed: 1,
      unregistered: ['start-token-b'],
    }),
    recordStart: () => {},
    unregisterStartToken: token => unregistered.push(token),
    now: new Date('2026-06-24T08:00:00.000Z'),
  });

  assert.deepEqual(result, { reason: 'start', sent: 1, failed: 1 });
  assert.deepEqual(unregistered, ['start-token-b']);
});

test('records start timestamp for each target attempted', async () => {
  const recorded: Array<{ token: string; date: Date }> = [];
  const now = new Date('2026-06-24T08:00:00.000Z');

  await maybeStartLiveActivityForSnapshot({
    snap,
    startTokens: [
      { ...startToken, token: 'start-token-a' },
      { ...startToken, token: 'start-token-b' },
    ],
    activityTokens: [],
    buildState: async () => contentState,
    pushStart: async () => ({ sent: 1, failed: 1, unregistered: [] }),
    recordStart: (token, date) => recorded.push({ token, date }),
    unregisterStartToken: () => {},
    now,
  });

  assert.deepEqual(recorded, [
    { token: 'start-token-a', date: now },
    { token: 'start-token-b', date: now },
  ]);
});
