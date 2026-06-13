import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import pino from 'pino';

import { TokenStore } from './tokenStore.js';

test('registering a rotated token replaces the previous token for the same client activity', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-token-store-'));
  try {
    const store = new TokenStore(dir, pino({ enabled: false }));

    store.register({
      groupId: '192.168.50.251',
      token: 'old-token',
      clientId: 'phone-a',
      activityId: 'activity-1',
    });
    store.register({
      groupId: '192.168.50.251',
      token: 'new-token',
      clientId: 'phone-a',
      activityId: 'activity-1',
    });

    assert.deepEqual(
      store.forGroup('192.168.50.251').map(entry => entry.token),
      ['new-token'],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('new protocol registration prunes legacy tokens for the same group', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-token-store-'));
  try {
    const store = new TokenStore(dir, pino({ enabled: false }));

    store.register({ groupId: '192.168.50.251', token: 'legacy-a' });
    store.register({ groupId: '192.168.50.251', token: 'legacy-b' });
    store.register({
      groupId: '192.168.50.251',
      token: 'current',
      clientId: 'phone-a',
      activityId: 'activity-2',
    });

    assert.deepEqual(
      store.forGroup('192.168.50.251').map(entry => entry.token),
      ['current'],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('new activity registration prunes older tokens from the same client and group', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-token-store-'));
  try {
    const store = new TokenStore(dir, pino({ enabled: false }));

    store.register({
      groupId: '192.168.50.251',
      token: 'previous-activity-token',
      clientId: 'phone-a',
      activityId: 'activity-1',
    });
    store.register({
      groupId: '192.168.50.251',
      token: 'current-activity-token',
      clientId: 'phone-a',
      activityId: 'activity-2',
    });

    assert.deepEqual(
      store.forGroup('192.168.50.251').map(entry => entry.token),
      ['current-activity-token'],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
