import type { SonosGroupSnapshot, TokenEntry } from './types.js';

export interface LiveActivityPushDecisionOptions {
  force?: boolean;
}

export function shouldPushLiveActivityUpdate(
  token: TokenEntry,
  contentHash: string,
  options: LiveActivityPushDecisionOptions = {},
): boolean {
  return options.force === true || token.lastSentHash !== contentHash;
}

export class LiveActivityPushInFlightRegistry {
  private readonly hashesByToken = new Map<string, string>();

  acquire(
    tokens: TokenEntry[],
    contentHash: string,
    options: LiveActivityPushDecisionOptions = {},
  ): TokenEntry[] {
    const acquired: TokenEntry[] = [];
    for (const token of tokens) {
      if (!shouldPushLiveActivityUpdate(token, contentHash, options)) continue;
      if (this.hashesByToken.get(token.token) === contentHash) continue;
      this.hashesByToken.set(token.token, contentHash);
      acquired.push(token);
    }
    return acquired;
  }

  release(tokens: TokenEntry[], contentHash: string): void {
    for (const token of tokens) {
      if (this.hashesByToken.get(token.token) === contentHash) {
        this.hashesByToken.delete(token.token);
      }
    }
  }
}

export function shouldForceLiveActivityCalibration(snap: SonosGroupSnapshot): boolean {
  return snap.isPlaying && snap.durationSeconds > 0;
}
