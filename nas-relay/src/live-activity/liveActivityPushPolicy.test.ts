import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  LiveActivityPushInFlightRegistry,
  liveActivityPushResultLogLevel,
  shouldPushLiveActivityUpdate,
} from './liveActivityPushPolicy.js';
import type { TokenEntry } from '../types.js';

test('Live Activity force updates bypass an unchanged content hash', () => {
  const token = tokenEntry({ lastSentHash: 'same-hash' });

  assert.equal(shouldPushLiveActivityUpdate(token, 'same-hash', { force: true }), true);
});

test('Live Activity event updates skip an unchanged content hash', () => {
  const token = tokenEntry({ lastSentHash: 'same-hash' });

  assert.equal(shouldPushLiveActivityUpdate(token, 'same-hash', { force: false }), false);
});

test('Live Activity event updates send changed content hashes', () => {
  const token = tokenEntry({ lastSentHash: 'old-hash' });

  assert.equal(shouldPushLiveActivityUpdate(token, 'new-hash', { force: false }), true);
});

test('Live Activity in-flight registry skips duplicate hash pushes until released', () => {
  const registry = new LiveActivityPushInFlightRegistry();
  const token = tokenEntry({ lastSentHash: 'old-hash' });

  assert.deepEqual(registry.acquire([token], 'new-hash', { force: false }), [token]);
  assert.deepEqual(registry.acquire([token], 'new-hash', { force: false }), []);

  registry.release([token], 'new-hash');

  assert.deepEqual(registry.acquire([token], 'new-hash', { force: false }), [token]);
});

test('Live Activity in-flight registry blocks forced duplicate hash pushes', () => {
  const registry = new LiveActivityPushInFlightRegistry();
  const token = tokenEntry({ lastSentHash: 'same-hash' });

  assert.deepEqual(registry.acquire([token], 'same-hash', { force: true }), [token]);
  assert.deepEqual(registry.acquire([token], 'same-hash', { force: true }), []);
});

test('Live Activity successful periodic push results are logged at debug level', () => {
  assert.equal(
    liveActivityPushResultLogLevel('periodic-refresh', { failed: 0, unregisteredCount: 0 }),
    'debug',
  );
  assert.equal(
    liveActivityPushResultLogLevel('sonos-change', { failed: 0, unregisteredCount: 0 }),
    'info',
  );
  assert.equal(
    liveActivityPushResultLogLevel('periodic-refresh', { failed: 1, unregisteredCount: 0 }),
    'info',
  );
});

function tokenEntry(overrides: Partial<TokenEntry> = {}): TokenEntry {
  return {
    groupId: '192.168.50.25',
    token: 'token',
    registeredAt: '2026-06-06T00:00:00.000Z',
    ...overrides,
  };
}
