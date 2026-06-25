import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import pino from 'pino';

import { StartTokenStore } from './startTokenStore.js';
import type { PushToStartTokenEntry } from './types.js';

test('registering a rotated push-to-start token replaces the previous token for the same client group', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }));

    store.register({
      groupId: '192.168.50.25',
      token: 'old-start-token',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      liveActivityStyleRaw: 'widget',
    });
    store.register({
      groupId: '192.168.50.25',
      token: 'new-start-token',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      liveActivityStyleRaw: 'widget',
    });

    assert.deepEqual(
      store.forGroup('192.168.50.25').map(entry => entry.token),
      ['new-start-token'],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('same push-to-start token can be registered for multiple client groups', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }));

    store.register({
      groupId: '192.168.50.25',
      token: 'shared-start-token',
      clientId: 'phone-a',
      speakerName: 'Playroom',
    });
    store.register({
      groupId: '192.168.50.26',
      token: 'shared-start-token',
      clientId: 'phone-a',
      speakerName: 'Move',
    });

    assert.deepEqual(
      store.forGroup('192.168.50.25').map(entry => entry.speakerName),
      ['Playroom'],
    );
    assert.deepEqual(
      store.forGroup('192.168.50.26').map(entry => entry.speakerName),
      ['Move'],
    );
    assert.equal(store.count(), 2);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('registering and pruning persists only the current token for the same client group', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }), { flushDelayMs: 0 });

    store.register({
      groupId: '192.168.50.25',
      token: 'old-start-token',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      liveActivityStyleRaw: 'widget',
    });
    store.register({
      groupId: '192.168.50.26',
      token: 'same-client-other-group',
      clientId: 'phone-a',
    });
    store.register({
      groupId: '192.168.50.25',
      token: 'other-client-same-group',
      clientId: 'phone-b',
    });
    store.register({
      groupId: '192.168.50.25',
      token: 'new-start-token',
      clientId: 'phone-a',
      speakerName: 'Playroom',
      liveActivityStyleRaw: 'widget',
    });

    await waitForPersistedTokens(dir, tokens =>
      tokens.some(entry => entry.token === 'new-start-token')
      && !tokens.some(entry => entry.token === 'old-start-token')
      && tokens.some(entry => entry.token === 'same-client-other-group')
      && tokens.some(entry => entry.token === 'other-client-same-group'));

    const loaded = new StartTokenStore(dir, pino({ enabled: false }));
    await loaded.load();

    assert.deepEqual(
      loaded.forGroup('192.168.50.25').map(entry => entry.token).sort(),
      ['new-start-token', 'other-client-same-group'],
    );
    assert.deepEqual(
      loaded.forGroup('192.168.50.26').map(entry => entry.token),
      ['same-client-other-group'],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('recordStart stores an ISO timestamp for an existing token', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }));
    store.register({
      groupId: '192.168.50.25',
      token: 'start-token',
      clientId: 'phone-a',
    });

    const startedAt = new Date('2026-06-24T12:34:56.789Z');
    store.recordStart('start-token', startedAt);

    assert.equal(store.forGroup('192.168.50.25')[0]?.lastStartAt, startedAt.toISOString());
    assert.equal(store.forGroup('192.168.50.25')[0]?.startAttemptCount, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('recordStart can update one group when the same token is registered for multiple groups', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }));
    store.register({
      groupId: '192.168.50.25',
      token: 'shared-start-token',
      clientId: 'phone-a',
    });
    store.register({
      groupId: '192.168.50.26',
      token: 'shared-start-token',
      clientId: 'phone-a',
    });

    const startedAt = new Date('2026-06-24T12:34:56.789Z');
    store.recordStart('shared-start-token', startedAt, '192.168.50.25');

    assert.equal(store.forGroup('192.168.50.25')[0]?.lastStartAt, startedAt.toISOString());
    assert.equal(store.forGroup('192.168.50.26')[0]?.lastStartAt, undefined);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('recordStart increments the start attempt count for repeated push-to-start sends', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }));
    store.register({
      groupId: '192.168.50.25',
      token: 'start-token',
      clientId: 'phone-a',
    });

    store.recordStart('start-token', new Date('2026-06-24T12:00:00.000Z'));
    store.recordStart('start-token', new Date('2026-06-24T12:02:00.000Z'));

    assert.equal(store.forGroup('192.168.50.25')[0]?.startAttemptCount, 2);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('registering an activity token resets start attempts for that client group', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }));
    store.register({
      groupId: '192.168.50.25',
      token: 'start-token',
      clientId: 'phone-a',
    });
    store.recordStart('start-token', new Date('2026-06-24T12:00:00.000Z'));
    store.recordStart('start-token', new Date('2026-06-24T12:02:00.000Z'));

    store.recordActivityRegistered('192.168.50.25', 'phone-a');

    assert.equal(store.forGroup('192.168.50.25')[0]?.startAttemptCount, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('recordStart persists lastStartAt across load', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }), { flushDelayMs: 0 });
    store.register({
      groupId: '192.168.50.25',
      token: 'start-token',
      clientId: 'phone-a',
    });

    const startedAt = new Date('2026-06-24T12:34:56.789Z');
    store.recordStart('start-token', startedAt);

    await waitForPersistedTokens(dir, tokens =>
      tokens.some(entry => entry.token === 'start-token' && entry.lastStartAt === startedAt.toISOString()));

    const loaded = new StartTokenStore(dir, pino({ enabled: false }));
    await loaded.load();

    assert.equal(loaded.forGroup('192.168.50.25')[0]?.lastStartAt, startedAt.toISOString());
    assert.equal(loaded.forGroup('192.168.50.25')[0]?.startAttemptCount, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('unregister persists token removal across load', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }), { flushDelayMs: 0 });
    store.register({ groupId: '192.168.50.25', token: 'token-a', clientId: 'phone-a' });
    store.register({ groupId: '192.168.50.25', token: 'token-b', clientId: 'phone-b' });

    await waitForPersistedTokens(dir, tokens => tokens.length === 2);
    assert.equal(store.unregister('token-a'), true);
    await waitForPersistedTokens(dir, tokens =>
      tokens.length === 1 && tokens[0]?.token === 'token-b');

    const loaded = new StartTokenStore(dir, pino({ enabled: false }));
    await loaded.load();

    assert.deepEqual(
      loaded.forGroup('192.168.50.25').map(entry => entry.token),
      ['token-b'],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('mutations during an in-flight flush are persisted by a follow-up write', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    let firstWriteStarted: (() => void) | null = null;
    let releaseFirstWrite: (() => void) | null = null;
    const firstWriteStartedPromise = new Promise<void>(resolve => {
      firstWriteStarted = resolve;
    });
    const releaseFirstWritePromise = new Promise<void>(resolve => {
      releaseFirstWrite = resolve;
    });
    let writeCount = 0;

    const store = new StartTokenStore(dir, pino({ enabled: false }), {
      flushDelayMs: 0,
      writeFile: async (filePath, data, options) => {
        writeCount += 1;
        if (writeCount === 1) {
          firstWriteStarted?.();
          await releaseFirstWritePromise;
        }
        await writeFile(filePath, data, options);
      },
    });

    store.register({ groupId: '192.168.50.25', token: 'start-token', clientId: 'phone-a' });
    await withTimeout(firstWriteStartedPromise, 1000, 'first write did not start');

    const startedAt = new Date('2026-06-24T12:34:56.789Z');
    store.recordStart('start-token', startedAt);
    releaseFirstWrite?.();

    await waitForPersistedTokens(dir, tokens =>
      tokens.some(entry => entry.token === 'start-token' && entry.lastStartAt === startedAt.toISOString()));

    const loaded = new StartTokenStore(dir, pino({ enabled: false }));
    await loaded.load();

    assert.equal(loaded.forGroup('192.168.50.25')[0]?.lastStartAt, startedAt.toISOString());
    assert.equal(writeCount, 2);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('tokens for other clients and groups are preserved when registering a new token', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }));

    store.register({
      groupId: '192.168.50.25',
      token: 'same-client-other-group',
      clientId: 'phone-a',
    });
    store.register({
      groupId: '192.168.50.26',
      token: 'other-client-same-group',
      clientId: 'phone-b',
    });
    store.register({
      groupId: '192.168.50.26',
      token: 'new-start-token',
      clientId: 'phone-a',
    });

    assert.deepEqual(
      store.forGroup('192.168.50.25').map(entry => entry.token),
      ['same-client-other-group'],
    );
    assert.deepEqual(
      store.forGroup('192.168.50.26').map(entry => entry.token),
      ['other-client-same-group', 'new-start-token'],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('count reports the current push-to-start token count', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }));

    store.register({ groupId: '192.168.50.25', token: 'token-a', clientId: 'phone-a' });
    store.register({ groupId: '192.168.50.25', token: 'token-b', clientId: 'phone-b' });

    assert.equal(store.count(), 2);
    assert.equal(store.unregister('token-a'), true);
    assert.equal(store.count(), 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

async function waitForPersistedTokens(
  dir: string,
  predicate: (tokens: PushToStartTokenEntry[]) => boolean,
): Promise<PushToStartTokenEntry[]> {
  const filePath = path.join(dir, 'start-tokens.json');
  const deadline = Date.now() + 1000;
  let lastTokens: PushToStartTokenEntry[] = [];

  while (Date.now() < deadline) {
    try {
      lastTokens = JSON.parse(await readFile(filePath, 'utf8')) as PushToStartTokenEntry[];
      if (predicate(lastTokens)) return lastTokens;
    } catch (err: any) {
      if (err.code !== 'ENOENT' && !(err instanceof SyntaxError)) throw err;
    }
    await new Promise(resolve => setTimeout(resolve, 10));
  }

  assert.fail(`timed out waiting for persisted tokens; last tokens: ${JSON.stringify(lastTokens)}`);
}

async function withTimeout<T>(promise: Promise<T>, ms: number, message: string): Promise<T> {
  let timeout: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error(message)), ms);
      }),
    ]);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}
