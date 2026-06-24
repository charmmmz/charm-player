import type { PushToStartTokenEntry, SonosGroupSnapshot, TokenEntry } from './types.js';

export type PushToStartDecisionReason =
  | 'start'
  | 'not-playing'
  | 'no-start-token'
  | 'activity-token-active'
  | 'cooldown';

export interface PushToStartDecisionInput {
  snap: SonosGroupSnapshot;
  startTokens: PushToStartTokenEntry[];
  activityTokens: TokenEntry[];
  now: Date;
  cooldownMs?: number;
}

export interface PushToStartDecision {
  reason: PushToStartDecisionReason;
  targets: PushToStartTokenEntry[];
}

export function selectPushToStartTargets(input: PushToStartDecisionInput): PushToStartDecision {
  if (!input.snap.isPlaying) {
    return { reason: 'not-playing', targets: [] };
  }

  if (input.activityTokens.length > 0) {
    return { reason: 'activity-token-active', targets: [] };
  }

  if (input.startTokens.length === 0) {
    return { reason: 'no-start-token', targets: [] };
  }

  const cooldownMs = input.cooldownMs ?? 90_000;
  const targets = input.startTokens.filter(token => isOutsideCooldown(token, input.now, cooldownMs));

  if (targets.length === 0) {
    return { reason: 'cooldown', targets: [] };
  }

  return { reason: 'start', targets };
}

function isOutsideCooldown(token: PushToStartTokenEntry, now: Date, cooldownMs: number): boolean {
  if (!token.lastStartAt) {
    return true;
  }

  const lastStartMs = Date.parse(token.lastStartAt);
  return Number.isNaN(lastStartMs) || now.getTime() - lastStartMs >= cooldownMs;
}
