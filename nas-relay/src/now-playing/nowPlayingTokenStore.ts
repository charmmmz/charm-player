import { promises as fs } from 'node:fs';
import path from 'node:path';
import type { Logger } from 'pino';

import type {
  NowPlayingRegisterRequest,
  NowPlayingTokenEntry,
  NowPlayingTokenKind,
} from '../types.js';

export class NowPlayingTokenStore {
  private readonly entries = new Map<string, NowPlayingTokenEntry>();
  private readonly path: string;
  private readonly log: Logger;
  private readonly flushDelayMs: number;
  private flushPromise: Promise<void> | null = null;

  constructor(dataDir: string, log: Logger, options: { flushDelayMs?: number } = {}) {
    this.path = path.join(dataDir, 'now-playing-tokens.json');
    this.log = log.child({ module: 'nowPlayingTokenStore' });
    this.flushDelayMs = options.flushDelayMs ?? 100;
  }

  async load(): Promise<void> {
    try {
      const raw = await fs.readFile(this.path, 'utf8');
      const parsed = JSON.parse(raw) as NowPlayingTokenEntry[];
      for (const entry of parsed) {
        if (isValidEntry(entry)) this.entries.set(entryKey(entry), entry);
      }
      this.log.info({ count: this.entries.size }, 'loaded persisted Now Playing tokens');
    } catch (err: any) {
      if (err.code !== 'ENOENT') {
        this.log.warn({ err }, 'failed to load now-playing-tokens.json — starting empty');
      }
    }
  }

  register(request: NowPlayingRegisterRequest): NowPlayingTokenEntry {
    const key = entryKey(request);
    const existing = this.entries.get(key);
    if (existing && hasSameRegistrationMetadata(existing, request)) {
      if (request.kind === 'start'
        && request.requestStart === true
        && request.sessionGeneration
        && existing.sessionGeneration !== request.sessionGeneration) {
        existing.sessionGeneration = request.sessionGeneration;
        delete existing.lastSentHash;
        void this.flush();
      }
      this.log.debug({
        kind: request.kind,
        groupId: request.groupId,
        sessionId: request.sessionId,
        clientId: request.clientId,
        token: shortToken(request.token),
      }, 'ignored duplicate Now Playing token registration');
      return existing;
    }

    // A push-to-start token represents this app install's selected session.
    // Re-registering it for a new Sonos group must not keep starting the old room.
    if (request.kind === 'start') {
      for (const [candidateKey, entry] of this.entries) {
        const supersededStart = entry.kind === 'start'
          && entry.clientId === request.clientId
          && candidateKey !== key;
        const staleSessionUpdate = entry.kind === 'update'
          && entry.clientId === request.clientId
          && entry.sessionId !== request.sessionId;
        if (supersededStart || staleSessionUpdate) {
          this.entries.delete(candidateKey);
        }
      }
    } else {
      // APNs can rotate the per-session update token. Keep one current token
      // for each app install/session pair.
      for (const [candidateKey, entry] of this.entries) {
        if (entry.kind === 'update'
          && entry.clientId === request.clientId
          && entry.sessionId === request.sessionId
          && candidateKey !== key) {
          this.entries.delete(candidateKey);
        }
      }
    }

    const entry: NowPlayingTokenEntry = {
      ...request,
      registeredAt: new Date().toISOString(),
    };
    this.entries.set(key, entry);
    void this.flush();
    this.log.info({
      kind: request.kind,
      groupId: request.groupId,
      sessionId: request.sessionId,
      clientId: request.clientId,
      token: shortToken(request.token),
    }, 'registered Now Playing token');
    return entry;
  }

  hasRegistration(request: NowPlayingRegisterRequest): boolean {
    const existing = this.entries.get(entryKey(request));
    return existing ? hasSameRegistrationMetadata(existing, request) : false;
  }

  forGroup(groupId: string, kind: NowPlayingTokenKind): NowPlayingTokenEntry[] {
    return Array.from(this.entries.values()).filter(
      entry => entry.groupId === groupId && entry.kind === kind,
    );
  }

  hasTokenForGroup(groupId: string, token: string): boolean {
    return Array.from(this.entries.values()).some(
      entry => entry.groupId === groupId && entry.token === token,
    );
  }

  recordSent(entry: NowPlayingTokenEntry, hash: string, sessionGeneration?: string): void {
    const current = this.entries.get(entryKey(entry));
    if (!current) return;
    current.lastSentHash = hash;
    if (sessionGeneration) current.sessionGeneration = sessionGeneration;
    void this.flush();
  }

  resetStartSentForGroup(groupId: string): void {
    let changed = false;
    for (const entry of this.entries.values()) {
      if (entry.kind !== 'start' || entry.groupId !== groupId || !entry.lastSentHash) continue;
      delete entry.lastSentHash;
      delete entry.sessionGeneration;
      changed = true;
    }
    if (changed) void this.flush();
  }

  unregister(kind: NowPlayingTokenKind, token: string): number {
    let removed = 0;
    for (const [key, entry] of this.entries) {
      if (entry.kind !== kind || entry.token !== token) continue;
      this.entries.delete(key);
      removed += 1;
    }
    if (removed > 0) void this.flush();
    return removed;
  }

  removeUpdatesForGroup(groupId: string): number {
    let removed = 0;
    for (const [key, entry] of this.entries) {
      if (entry.kind !== 'update' || entry.groupId !== groupId) continue;
      this.entries.delete(key);
      removed += 1;
    }
    if (removed > 0) void this.flush();
    return removed;
  }

  removeUpdatesForClientSession(groupId: string, clientId: string, sessionId: string): number {
    let removed = 0;
    for (const [key, entry] of this.entries) {
      if (entry.kind !== 'update'
        || entry.groupId !== groupId
        || entry.clientId !== clientId
        || entry.sessionId !== sessionId) continue;
      this.entries.delete(key);
      removed += 1;
    }
    if (removed > 0) void this.flush();
    return removed;
  }

  count(kind?: NowPlayingTokenKind): number {
    if (!kind) return this.entries.size;
    return Array.from(this.entries.values()).filter(entry => entry.kind === kind).length;
  }

  private async flush(): Promise<void> {
    if (this.flushPromise) return this.flushPromise;
    this.flushPromise = new Promise<void>(resolve => {
      setTimeout(async () => {
        try {
          await fs.writeFile(
            this.path,
            JSON.stringify(Array.from(this.entries.values()), null, 2),
            'utf8',
          );
        } catch (err) {
          this.log.error({ err }, 'failed to persist now-playing-tokens.json');
        } finally {
          this.flushPromise = null;
          resolve();
        }
      }, this.flushDelayMs);
    });
    return this.flushPromise;
  }
}

function entryKey(entry: Pick<NowPlayingTokenEntry, 'kind' | 'groupId' | 'token'>): string {
  return `${entry.kind}|${entry.groupId}|${entry.token}`;
}

function hasSameRegistrationMetadata(
  existing: NowPlayingTokenEntry,
  request: NowPlayingRegisterRequest,
): boolean {
  return existing.sessionId === request.sessionId
    && existing.clientId === request.clientId
    && existing.speakerName === request.speakerName
    && existing.relayURLString === request.relayURLString
    && (request.kind === 'start'
      || existing.sessionGeneration === request.sessionGeneration);
}

function isValidEntry(entry: Partial<NowPlayingTokenEntry>): entry is NowPlayingTokenEntry {
  return (entry.kind === 'start' || entry.kind === 'update')
    && typeof entry.groupId === 'string'
    && typeof entry.token === 'string'
    && typeof entry.sessionId === 'string'
    && typeof entry.clientId === 'string'
    && typeof entry.speakerName === 'string'
    && typeof entry.relayURLString === 'string'
    && (entry.sessionGeneration === undefined || typeof entry.sessionGeneration === 'string')
    && typeof entry.registeredAt === 'string';
}

function shortToken(token: string): string {
  return token.length <= 12 ? token : `${token.slice(0, 6)}…${token.slice(-4)}`;
}
