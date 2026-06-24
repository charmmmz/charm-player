import { promises as fs } from 'node:fs';
import path from 'node:path';
import type { Logger } from 'pino';
import type { PushToStartRegisterRequest, PushToStartTokenEntry } from './types.js';

type WriteFile = typeof fs.writeFile;

interface StartTokenStoreOptions {
  flushDelayMs?: number;
  writeFile?: WriteFile;
}

/// Disk-backed registry for ActivityKit push-to-start tokens. This is separate
/// from update-token storage because start tokens identify an install/group
/// lane, not an already-created Live Activity.
export class StartTokenStore {
  private readonly tokens = new Map<string, PushToStartTokenEntry>();
  private readonly path: string;
  private readonly log: Logger;
  private readonly flushDelayMs: number;
  private readonly writeFile: WriteFile;
  private dirty = false;
  private flushPromise: Promise<void> | null = null;

  constructor(dataDir: string, log: Logger, options: StartTokenStoreOptions = {}) {
    this.path = path.join(dataDir, 'start-tokens.json');
    this.log = log.child({ module: 'startTokenStore' });
    this.flushDelayMs = options.flushDelayMs ?? 100;
    this.writeFile = options.writeFile ?? fs.writeFile;
  }

  async load(): Promise<void> {
    try {
      const raw = await fs.readFile(this.path, 'utf8');
      const parsed = JSON.parse(raw) as PushToStartTokenEntry[];
      this.tokens.clear();
      for (const entry of parsed) this.tokens.set(entry.token, entry);
      this.log.info({ count: this.tokens.size }, 'loaded persisted push-to-start tokens');
    } catch (err: any) {
      if (err.code !== 'ENOENT') {
        this.log.warn({ err }, 'failed to load start-tokens.json - starting empty');
      }
    }
  }

  register(req: PushToStartRegisterRequest): PushToStartTokenEntry {
    const existing = this.tokens.get(req.token);
    const removed = this.pruneSupersededTokens(req);
    const entry: PushToStartTokenEntry = {
      ...req,
      registeredAt: existing?.registeredAt ?? new Date().toISOString(),
      lastStartAt: existing?.lastStartAt,
      startAttemptCount: existing?.startAttemptCount,
    };
    this.tokens.set(req.token, entry);
    this.markDirty();
    this.log.info({
      token: shortToken(req.token),
      groupId: req.groupId,
      clientId: req.clientId ?? null,
      speakerName: req.speakerName ?? null,
      removed,
    }, 'registered push-to-start token');
    return entry;
  }

  unregister(token: string): boolean {
    const removed = this.tokens.delete(token);
    if (removed) {
      this.markDirty();
      this.log.info({ token: shortToken(token) }, 'unregistered push-to-start token');
    }
    return removed;
  }

  forGroup(groupId: string): PushToStartTokenEntry[] {
    const out: PushToStartTokenEntry[] = [];
    for (const entry of this.tokens.values()) {
      if (entry.groupId === groupId) out.push(entry);
    }
    return out;
  }

  recordStart(token: string, date: Date): void {
    const entry = this.tokens.get(token);
    if (entry) {
      entry.lastStartAt = date.toISOString();
      entry.startAttemptCount = (entry.startAttemptCount ?? 0) + 1;
      this.markDirty();
    }
  }

  recordActivityRegistered(groupId: string, clientId?: string): void {
    let changed = false;
    for (const entry of this.tokens.values()) {
      if (entry.groupId !== groupId) continue;
      if (clientId && entry.clientId !== clientId) continue;
      if ((entry.startAttemptCount ?? 0) !== 0) {
        entry.startAttemptCount = 0;
        changed = true;
      }
    }
    if (changed) this.markDirty();
  }

  count(): number {
    return this.tokens.size;
  }

  private markDirty(): void {
    this.dirty = true;
    void this.flush();
  }

  /// Coalesce repeated mutations while ensuring mutations during a write get a follow-up flush.
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
      const data = JSON.stringify(Array.from(this.tokens.values()), null, 2);
      this.dirty = false;

      try {
        await this.writeFile(this.path, data, 'utf8');
      } catch (err) {
        this.dirty = true;
        this.log.error({ err }, 'failed to persist start-tokens.json');
        break;
      }
    }
  }

  private pruneSupersededTokens(req: PushToStartRegisterRequest): number {
    if (!req.clientId) return 0;

    let removed = 0;
    for (const [token, entry] of this.tokens.entries()) {
      if (token === req.token) continue;
      if (entry.groupId !== req.groupId) continue;
      if (entry.clientId !== req.clientId) continue;

      this.tokens.delete(token);
      removed += 1;
    }
    return removed;
  }
}

function shortToken(token: string): string {
  return token.length <= 12 ? token : `${token.slice(0, 6)}...${token.slice(-4)}`;
}
