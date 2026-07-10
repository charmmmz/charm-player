import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import pino from 'pino';

import { LiveActivityDismissalStore } from './liveActivityDismissalStore.js';
import type { PushToStartSuppressionEntry } from '../types.js';

test('dismissal store returns active suppressions for a group and ignores expired entries', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-live-activity-dismissal-store-'));
  try {
    const store = new LiveActivityDismissalStore(dir, pino({ enabled: false }));
    store.recordDismissal({
      groupId: '192.168.50.25',
      clientId: 'phone-a',
      activityId: 'activity-a',
      reason: 'user-dismissed',
      recordedAt: '2026-06-24T08:00:00.000Z',
      suppressUntil: '2026-06-24T08:30:00.000Z',
    });

    assert.deepEqual(
      store.activeForGroup('192.168.50.25', new Date('2026-06-24T08:10:00.000Z'))
        .map(entry => entry.clientId),
      ['phone-a'],
    );
    assert.deepEqual(
      store.activeForGroup('192.168.50.25', new Date('2026-06-24T08:30:01.000Z')),
      [],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('dismissal store persists suppressions and clears them when an activity registers', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-live-activity-dismissal-store-'));
  try {
    const store = new LiveActivityDismissalStore(dir, pino({ enabled: false }), { flushDelayMs: 0 });
    store.recordDismissal({
      groupId: '192.168.50.25',
      clientId: 'phone-a',
      activityId: 'activity-a',
      reason: 'user-dismissed',
      recordedAt: '2026-06-24T08:00:00.000Z',
      suppressUntil: '2026-06-24T08:30:00.000Z',
    });

    await waitForPersistedSuppressions(dir, entries => entries.length === 1);

    const loaded = new LiveActivityDismissalStore(dir, pino({ enabled: false }), {
      flushDelayMs: 0,
    });
    await loaded.load();

    assert.equal(
      loaded.activeForGroup('192.168.50.25', new Date('2026-06-24T08:10:00.000Z')).length,
      1,
    );

    assert.equal(loaded.clearForActivity('192.168.50.25', 'phone-a', 'activity-a'), 1);
    await waitForPersistedSuppressions(dir, entries => entries.length === 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

async function waitForPersistedSuppressions(
  dir: string,
  predicate: (entries: PushToStartSuppressionEntry[]) => boolean,
): Promise<PushToStartSuppressionEntry[]> {
  const filePath = path.join(dir, 'live-activity-dismissals.json');
  const deadline = Date.now() + 1000;
  let lastEntries: PushToStartSuppressionEntry[] = [];

  while (Date.now() < deadline) {
    try {
      lastEntries = JSON.parse(await readFile(filePath, 'utf8')) as PushToStartSuppressionEntry[];
      if (predicate(lastEntries)) return lastEntries;
    } catch (err: any) {
      if (err.code !== 'ENOENT' && !(err instanceof SyntaxError)) throw err;
    }
    await new Promise(resolve => setTimeout(resolve, 10));
  }

  assert.fail(`timed out waiting for persisted suppressions; last entries: ${
    JSON.stringify(lastEntries)
  }`);
}
