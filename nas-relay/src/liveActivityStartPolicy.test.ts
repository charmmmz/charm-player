import assert from 'node:assert/strict';
import { test } from 'node:test';

import { selectPushToStartTargets } from './liveActivityStartPolicy.js';
import type { PushToStartTokenEntry, SonosGroupSnapshot, TokenEntry } from './types.js';

const snap: SonosGroupSnapshot = {
  groupId: '192.168.50.25',
  speakerName: 'Playroom',
  trackTitle: 'Nude',
  artist: 'Radiohead',
  album: 'In Rainbows',
  albumArtUri: null,
  isPlaying: true,
  positionSeconds: 10,
  durationSeconds: 255,
  groupMemberCount: 1,
  sampledAt: new Date('2026-06-24T08:00:00.000Z'),
};

const startToken: PushToStartTokenEntry = {
  groupId: '192.168.50.25',
  token: 'start-token',
  clientId: 'phone-a',
  speakerName: 'Playroom',
  registeredAt: '2026-06-24T07:00:00.000Z',
};

test('selects start tokens when playback is active and no activity token exists', () => {
  const decision = selectPushToStartTargets({
    snap,
    startTokens: [startToken],
    activityTokens: [],
    now: new Date('2026-06-24T08:00:00.000Z'),
  });

  assert.equal(decision.reason, 'start');
  assert.deepEqual(decision.targets.map(target => target.token), ['start-token']);
});

test('does not start when an update-token-backed activity is already active', () => {
  const activityTokens: TokenEntry[] = [
    {
      groupId: '192.168.50.25',
      token: 'activity-token',
      clientId: 'phone-a',
      activityId: 'activity-1',
      registeredAt: '2026-06-24T07:59:00.000Z',
    },
  ];

  const decision = selectPushToStartTargets({
    snap,
    startTokens: [startToken],
    activityTokens,
    now: new Date('2026-06-24T08:00:00.000Z'),
  });

  assert.equal(decision.reason, 'activity-token-active');
  assert.deepEqual(decision.targets, []);
});

test('does not start when playback is stopped', () => {
  const decision = selectPushToStartTargets({
    snap: { ...snap, isPlaying: false },
    startTokens: [startToken],
    activityTokens: [],
    now: new Date('2026-06-24T08:00:00.000Z'),
  });

  assert.equal(decision.reason, 'not-playing');
  assert.deepEqual(decision.targets, []);
});

test('does not start when no start tokens are registered', () => {
  const decision = selectPushToStartTargets({
    snap,
    startTokens: [],
    activityTokens: [],
    now: new Date('2026-06-24T08:00:00.000Z'),
  });

  assert.equal(decision.reason, 'no-start-token');
  assert.deepEqual(decision.targets, []);
});

test('does not start when all start tokens are in cooldown', () => {
  const decision = selectPushToStartTargets({
    snap,
    startTokens: [
      { ...startToken, token: 'start-token-a', lastStartAt: '2026-06-24T07:59:30.000Z' },
      { ...startToken, token: 'start-token-b', lastStartAt: '2026-06-24T07:59:45.000Z' },
    ],
    activityTokens: [],
    now: new Date('2026-06-24T08:00:00.000Z'),
    cooldownMs: 90_000,
  });

  assert.equal(decision.reason, 'cooldown');
  assert.deepEqual(decision.targets, []);
});

test('uses a 90 second default cooldown when none is supplied', () => {
  const decision = selectPushToStartTargets({
    snap,
    startTokens: [
      { ...startToken, token: 'recent-token', lastStartAt: '2026-06-24T07:58:31.000Z' },
      { ...startToken, token: 'eligible-token', lastStartAt: '2026-06-24T07:58:30.000Z' },
    ],
    activityTokens: [],
    now: new Date('2026-06-24T08:00:00.000Z'),
  });

  assert.equal(decision.reason, 'start');
  assert.deepEqual(decision.targets.map(target => target.token), ['eligible-token']);
});

test('selects only start tokens outside cooldown', () => {
  const decision = selectPushToStartTargets({
    snap,
    startTokens: [
      { ...startToken, token: 'recent-token', lastStartAt: '2026-06-24T07:59:30.000Z' },
      { ...startToken, token: 'eligible-token', lastStartAt: '2026-06-24T07:58:00.000Z' },
      { ...startToken, token: 'fresh-token', lastStartAt: undefined },
    ],
    activityTokens: [],
    now: new Date('2026-06-24T08:00:00.000Z'),
    cooldownMs: 90_000,
  });

  assert.equal(decision.reason, 'start');
  assert.deepEqual(
    decision.targets.map(target => target.token),
    ['eligible-token', 'fresh-token'],
  );
});
