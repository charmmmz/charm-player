import type {
  PushToStartSuppressionEntry,
  PushToStartTokenEntry,
  SonosGroupSnapshot,
  TokenEntry,
} from './types.js';

export type PushToStartDecisionReason =
  | 'start'
  | 'not-playing'
  | 'no-start-token'
  | 'activity-token-active'
  | 'suppressed'
  | 'cooldown'
  | 'backoff';

export interface PushToStartDecisionInput {
  snap: SonosGroupSnapshot;
  startTokens: PushToStartTokenEntry[];
  activityTokens: TokenEntry[];
  startSuppressions?: PushToStartSuppressionEntry[];
  now: Date;
  cooldownMs?: number;
  retryBackoffMs?: number;
  bypassCooldown?: boolean;
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

  const eligibleBySuppression = input.startTokens.filter(token => (
    !isSuppressed(token, input.startSuppressions ?? [], input.now)
  ));
  if (eligibleBySuppression.length === 0) {
    return { reason: 'suppressed', targets: [] };
  }

  if (input.bypassCooldown === true) {
    return { reason: 'start', targets: eligibleBySuppression };
  }

  const cooldownMs = input.cooldownMs ?? 90_000;
  const retryBackoffMs = input.retryBackoffMs ?? 15 * 60_000;
  const targets = eligibleBySuppression.filter(token => (
    isOutsideCooldown(token, input.now, cooldownForToken(token, cooldownMs, retryBackoffMs))
  ));

  if (targets.length === 0) {
    const hasRepeatedAttempt = eligibleBySuppression.some(token => (
      startAttemptCount(token) >= 2
    ));
    return { reason: hasRepeatedAttempt ? 'backoff' : 'cooldown', targets: [] };
  }

  return { reason: 'start', targets };
}

function isSuppressed(
  token: PushToStartTokenEntry,
  suppressions: PushToStartSuppressionEntry[],
  now: Date,
): boolean {
  return suppressions.some(entry => {
    if (entry.groupId !== token.groupId) return false;
    if (Date.parse(entry.suppressUntil) <= now.getTime()) return false;
    if (!entry.clientId) return true;
    return token.clientId === entry.clientId;
  });
}

function cooldownForToken(
  token: PushToStartTokenEntry,
  cooldownMs: number,
  retryBackoffMs: number,
): number {
  return startAttemptCount(token) >= 2 ? retryBackoffMs : cooldownMs;
}

function startAttemptCount(token: PushToStartTokenEntry): number {
  return token.startAttemptCount ?? (token.lastStartAt ? 1 : 0);
}

function isOutsideCooldown(token: PushToStartTokenEntry, now: Date, cooldownMs: number): boolean {
  if (!token.lastStartAt) {
    return true;
  }

  const lastStartMs = Date.parse(token.lastStartAt);
  return Number.isNaN(lastStartMs) || now.getTime() - lastStartMs >= cooldownMs;
}
