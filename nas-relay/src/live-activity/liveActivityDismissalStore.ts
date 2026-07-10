import { promises as fs } from 'node:fs';
import path from 'node:path';
import type { Logger } from 'pino';
import type { LiveActivityDismissedRequest, PushToStartSuppressionEntry } from '../types.js';

type WriteFile = typeof fs.writeFile;

interface LiveActivityDismissalStoreOptions {
  flushDelayMs?: number;
  writeFile?: WriteFile;
}

export class LiveActivityDismissalStore {
  private readonly entries = new Map<string, PushToStartSuppressionEntry>();
  private readonly path: string;
  private readonly log: Logger;
  private readonly flushDelayMs: number;
  private readonly writeFile: WriteFile;
  private dirty = false;
  private flushPromise: Promise<void> | null = null;

  constructor(dataDir: string, log: Logger, options: LiveActivityDismissalStoreOptions = {}) {
    this.path = path.join(dataDir, 'live-activity-dismissals.json');
    this.log = log.child({ module: 'liveActivityDismissalStore' });
    this.flushDelayMs = options.flushDelayMs ?? 100;
    this.writeFile = options.writeFile ?? fs.writeFile;
  }

  async load(): Promise<void> {
    try {
      const raw = await fs.readFile(this.path, 'utf8');
      const parsed = JSON.parse(raw) as PushToStartSuppressionEntry[];
      this.entries.clear();
      for (const entry of parsed) {
        this.entries.set(entryKey(entry.groupId, entry.clientId, entry.activityId), entry);
      }
      this.log.info({ count: this.entries.size }, 'loaded persisted Live Activity dismissals');
    } catch (err: any) {
      if (err.code !== 'ENOENT') {
        this.log.warn({ err }, 'failed to load live-activity-dismissals.json - starting empty');
      }
    }
  }

  recordDismissal(entry: PushToStartSuppressionEntry): PushToStartSuppressionEntry {
    this.entries.set(entryKey(entry.groupId, entry.clientId, entry.activityId), entry);
    this.markDirty();
    this.log.info({
      groupId: entry.groupId,
      clientId: entry.clientId ?? null,
      activityId: entry.activityId ?? null,
      suppressUntil: entry.suppressUntil,
    }, 'recorded Live Activity dismissal suppression');
    return entry;
  }

  recordDismissalRequest(
    req: LiveActivityDismissedRequest,
    now: Date,
    defaultSuppressForSeconds: number,
  ): PushToStartSuppressionEntry {
    const requestedSeconds = Number.isFinite(req.suppressForSeconds)
      ? Math.max(0, Math.min(req.suppressForSeconds ?? 0, 24 * 3600))
      : defaultSuppressForSeconds;
    const suppressUntil = new Date(now.getTime() + requestedSeconds * 1000);
    return this.recordDismissal({
      groupId: req.groupId,
      clientId: cleanOptionalString(req.clientId),
      activityId: cleanOptionalString(req.activityId),
      reason: 'user-dismissed',
      recordedAt: now.toISOString(),
      suppressUntil: suppressUntil.toISOString(),
    });
  }

  activeForGroup(groupId: string, now: Date): PushToStartSuppressionEntry[] {
    const active: PushToStartSuppressionEntry[] = [];
    let pruned = false;
    for (const [key, entry] of this.entries.entries()) {
      if (Date.parse(entry.suppressUntil) <= now.getTime()) {
        this.entries.delete(key);
        pruned = true;
        continue;
      }
      if (entry.groupId === groupId) active.push(entry);
    }
    if (pruned) this.markDirty();
    return active;
  }

  clearForActivity(groupId: string, clientId?: string, activityId?: string): number {
    let removed = 0;
    for (const [key, entry] of this.entries.entries()) {
      if (entry.groupId !== groupId) continue;
      if (clientId && entry.clientId !== clientId) continue;
      if (activityId && entry.activityId !== activityId) continue;
      this.entries.delete(key);
      removed += 1;
    }
    if (removed > 0) {
      this.markDirty();
      this.log.info({ groupId, clientId: clientId ?? null, activityId: activityId ?? null, removed },
        'cleared Live Activity dismissal suppression');
    }
    return removed;
  }

  count(now = new Date()): number {
    let count = 0;
    for (const entry of this.entries.values()) {
      if (Date.parse(entry.suppressUntil) > now.getTime()) count += 1;
    }
    return count;
  }

  private markDirty(): void {
    this.dirty = true;
    void this.flush();
  }

  private flush(): Promise<void> {
    if (this.flushPromise) return this.flushPromise;
    this.flushPromise = this.flushDirtyEntries().finally(() => {
      this.flushPromise = null;
    });
    return this.flushPromise;
  }

  private async flushDirtyEntries(): Promise<void> {
    while (this.dirty) {
      await new Promise(resolve => setTimeout(resolve, this.flushDelayMs));
      const data = JSON.stringify(Array.from(this.entries.values()), null, 2);
      this.dirty = false;

      try {
        await this.writeFile(this.path, data, 'utf8');
      } catch (err) {
        this.dirty = true;
        this.log.error({ err }, 'failed to persist live-activity-dismissals.json');
        break;
      }
    }
  }
}

function entryKey(groupId: string, clientId?: string, activityId?: string): string {
  return [
    groupId,
    clientId ?? '',
    activityId ?? '',
  ].join('|');
}

function cleanOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim() ?? '';
  return trimmed.length > 0 ? trimmed : undefined;
}
