import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import pino from 'pino';

import { NowPlayingTokenStore } from './nowPlayingTokenStore.js';

test('rotated Now Playing update token replaces the old token for one client session', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-now-playing-token-store-'));
  try {
    const store = new NowPlayingTokenStore(dir, pino({ enabled: false }));
    const base = {
      kind: 'update' as const,
      groupId: '192.168.50.25',
      sessionId: 'sonos:192.168.50.25',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      relayURLString: 'http://192.168.50.10:8789',
      sessionGeneration: 'generation-a',
    };
    store.register({ ...base, token: 'old-token' });
    store.register({ ...base, token: 'new-token' });
    assert.deepEqual(store.forGroup(base.groupId, 'update').map(entry => entry.token), ['new-token']);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('a reused update token is a new registration in a new playback generation', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-now-playing-token-store-'));
  try {
    const store = new NowPlayingTokenStore(dir, pino({ enabled: false }), { flushDelayMs: 0 });
    const request = {
      kind: 'update' as const,
      groupId: '192.168.50.25',
      token: 'reused-token',
      sessionId: 'sonos-v11:192.168.50.25',
      sessionGeneration: 'generation-a',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      relayURLString: 'http://192.168.50.10:8789',
    };
    const first = store.register(request);
    store.recordSent(first, 'old-hash', request.sessionGeneration);

    const nextRequest = { ...request, sessionGeneration: 'generation-b' };
    assert.equal(store.hasRegistration(nextRequest), false);
    const next = store.register(nextRequest);
    assert.equal(next.sessionGeneration, 'generation-b');
    assert.equal(next.lastSentHash, undefined);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('identical Now Playing registration is recognized as idempotent', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-now-playing-token-store-'));
  try {
    const store = new NowPlayingTokenStore(dir, pino({ enabled: false }), { flushDelayMs: 0 });
    const request = {
      kind: 'update' as const,
      groupId: '192.168.50.25',
      token: 'same-token',
      sessionId: 'sonos-v3:192.168.50.25',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      relayURLString: 'http://192.168.50.10:8789',
    };

    assert.equal(store.hasRegistration(request), false);
    const first = store.register(request);
    assert.equal(store.hasRegistration(request), true);
    assert.equal(store.hasRegistration({ ...request, sessionId: 'new-session' }), false);
    store.recordSent(first, 'sent-hash');
    const duplicate = store.register(request);
    assert.equal(duplicate, first);
    assert.equal(duplicate.lastSentHash, 'sent-hash');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('push-to-start registration follows the selected group for one client', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-now-playing-token-store-'));
  try {
    const store = new NowPlayingTokenStore(dir, pino({ enabled: false }));
    const base = {
      kind: 'start' as const,
      token: 'start-token',
      sessionId: 'sonos:192.168.50.25',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      relayURLString: 'http://192.168.50.10:8789',
    };
    store.register({ ...base, groupId: '192.168.50.25' });
    store.register({
      ...base,
      groupId: '192.168.50.26',
      sessionId: 'sonos:192.168.50.26',
      speakerName: 'Move',
    });
    assert.equal(store.forGroup('192.168.50.25', 'start').length, 0);
    assert.equal(store.forGroup('192.168.50.26', 'start').length, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('a new session start registration prunes stale update tokens for the same client', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-now-playing-token-store-'));
  try {
    const store = new NowPlayingTokenStore(dir, pino({ enabled: false }));
    const common = {
      groupId: '192.168.50.25',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      relayURLString: 'http://192.168.50.10:8789',
    };
    store.register({
      ...common,
      kind: 'update',
      token: 'old-update-token',
      sessionId: 'sonos:192.168.50.25',
    });
    store.register({
      ...common,
      kind: 'start',
      token: 'start-token',
      sessionId: 'sonos-v2:192.168.50.25',
    });
    assert.equal(store.forGroup(common.groupId, 'update').length, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('reboot recovery can retire only the stale update token for one client session', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-now-playing-token-store-'));
  try {
    const store = new NowPlayingTokenStore(dir, pino({ enabled: false }), { flushDelayMs: 0 });
    const common = {
      kind: 'update' as const,
      groupId: '192.168.50.25',
      sessionId: 'sonos-v19:192.168.50.25',
      speakerName: 'Playroom',
      relayURLString: 'http://192.168.50.10:8789',
      sessionGeneration: 'pre-reboot-generation',
    };
    store.register({ ...common, clientId: 'phone-a', token: 'phone-a-old-update' });
    store.register({ ...common, clientId: 'phone-b', token: 'phone-b-update' });

    assert.equal(
      store.removeUpdatesForClientSession(common.groupId, 'phone-a', common.sessionId),
      1,
    );
    assert.deepEqual(
      store.forGroup(common.groupId, 'update').map(entry => entry.token),
      ['phone-b-update'],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('requested push-to-start replaces the persisted generation before APNs delivery', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-now-playing-token-store-'));
  try {
    const store = new NowPlayingTokenStore(dir, pino({ enabled: false }), { flushDelayMs: 0 });
    const common = {
      kind: 'start' as const,
      groupId: '192.168.50.25',
      token: 'start-token',
      sessionId: 'sonos-v19:192.168.50.25',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      relayURLString: 'http://192.168.50.10:8789',
    };
    const old = store.register({
      ...common,
      sessionGeneration: 'pre-reboot-generation',
      requestStart: false,
    });
    store.recordSent(old, 'old-session-active', 'pre-reboot-generation');

    const replacement = store.register({
      ...common,
      sessionGeneration: 'relay-owned-generation',
      requestStart: true,
    });

    assert.equal(replacement.sessionGeneration, 'relay-owned-generation');
    assert.equal(replacement.lastSentHash, undefined);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('Now Playing token can authenticate commands for its registered group only', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-now-playing-token-store-'));
  try {
    const store = new NowPlayingTokenStore(dir, pino({ enabled: false }));
    store.register({
      kind: 'update',
      groupId: '192.168.50.25',
      token: 'update-token',
      sessionId: 'sonos:192.168.50.25',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      relayURLString: 'http://192.168.50.10:8789',
    });
    assert.equal(store.hasTokenForGroup('192.168.50.25', 'update-token'), true);
    assert.equal(store.hasTokenForGroup('192.168.50.26', 'update-token'), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('ended playback rearms the push-to-start token for a later session', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-now-playing-token-store-'));
  try {
    const store = new NowPlayingTokenStore(dir, pino({ enabled: false }));
    const entry = store.register({
      kind: 'start',
      groupId: '192.168.50.25',
      token: 'start-token',
      sessionId: 'sonos-v9:192.168.50.25',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      relayURLString: 'http://192.168.50.10:8789',
    });
    store.recordSent(entry, 'sent-hash', 'generation-a');
    assert.equal(store.forGroup(entry.groupId, 'start')[0]?.lastSentHash, 'sent-hash');
    assert.equal(
      store.forGroup(entry.groupId, 'start')[0]?.sessionGeneration,
      'generation-a',
    );

    store.resetStartSentForGroup(entry.groupId);
    assert.equal(store.forGroup(entry.groupId, 'start')[0]?.lastSentHash, undefined);
    assert.equal(store.forGroup(entry.groupId, 'start')[0]?.sessionGeneration, undefined);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
