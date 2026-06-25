import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
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

test('count reports the current activity update token count', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-token-store-'));
  try {
    const store = new TokenStore(dir, pino({ enabled: false }));

    assert.equal(store.count(), 0);
    store.register({
      groupId: '192.168.50.251',
      token: 'activity-token-a',
      clientId: 'phone-a',
      activityId: 'activity-1',
    });
    store.register({
      groupId: '192.168.50.252',
      token: 'activity-token-b',
      clientId: 'phone-b',
      activityId: 'activity-2',
    });
    store.unregister('activity-token-a');

    assert.equal(store.count(), 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('pruning stale client activities keeps locally active activity tokens', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-token-store-'));
  try {
    const store = new TokenStore(dir, pino({ enabled: false }));

    await writeFile(
      path.join(dir, 'tokens.json'),
      JSON.stringify([
        {
          groupId: '192.168.50.251',
          token: 'still-active-token',
          clientId: 'phone-a',
          activityId: 'activity-active',
          registeredAt: '2026-06-24T19:13:00.000Z',
        },
        {
          groupId: '192.168.50.251',
          token: 'stale-token',
          clientId: 'phone-a',
          activityId: 'activity-stale',
          registeredAt: '2026-06-24T19:13:01.000Z',
        },
      ]),
      'utf8',
    );
    await store.load();

    const removed = store.pruneStaleClientActivities(
      '192.168.50.251',
      'phone-a',
      ['activity-active'],
    );

    assert.equal(removed, 1);
    assert.deepEqual(
      store.forGroup('192.168.50.251').map(entry => entry.token),
      ['still-active-token'],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('pruning stale client activities removes all same-client tokens when no local activity remains', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-token-store-'));
  try {
    const store = new TokenStore(dir, pino({ enabled: false }));

    store.register({
      groupId: '192.168.50.251',
      token: 'old-token',
      clientId: 'phone-a',
      activityId: 'activity-old',
    });
    store.register({
      groupId: '192.168.50.251',
      token: 'legacy-token',
      clientId: 'phone-a',
    });

    const removed = store.pruneStaleClientActivities(
      '192.168.50.251',
      'phone-a',
      [],
    );

    assert.equal(removed, 2);
    assert.deepEqual(store.forGroup('192.168.50.251'), []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('pruning stale client activities leaves other clients and groups untouched', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-token-store-'));
  try {
    const store = new TokenStore(dir, pino({ enabled: false }));

    store.register({
      groupId: '192.168.50.251',
      token: 'target-stale-token',
      clientId: 'phone-a',
      activityId: 'activity-stale',
    });
    store.register({
      groupId: '192.168.50.251',
      token: 'other-client-token',
      clientId: 'phone-b',
      activityId: 'activity-other-client',
    });
    store.register({
      groupId: '192.168.50.252',
      token: 'other-group-token',
      clientId: 'phone-a',
      activityId: 'activity-other-group',
    });

    const removed = store.pruneStaleClientActivities(
      '192.168.50.251',
      'phone-a',
      [],
    );

    assert.equal(removed, 1);
    assert.deepEqual(
      store.forGroup('192.168.50.251').map(entry => entry.token),
      ['other-client-token'],
    );
    assert.deepEqual(
      store.forGroup('192.168.50.252').map(entry => entry.token),
      ['other-group-token'],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
