import type { ApnsResult } from './apns.js';
import { selectPushToStartTargets } from './liveActivityStartPolicy.js';
import type {
  LiveActivityContentState,
  LiveActivityStartAttributes,
  PushToStartSuppressionEntry,
  PushToStartTokenEntry,
  SonosGroupSnapshot,
  TokenEntry,
} from './types.js';

export async function maybeStartLiveActivityForSnapshot(input: {
  snap: SonosGroupSnapshot;
  startTokens: PushToStartTokenEntry[];
  activityTokens: TokenEntry[];
  startSuppressions?: PushToStartSuppressionEntry[];
  buildState: (snap: SonosGroupSnapshot) => Promise<LiveActivityContentState>;
  pushStart: (
    tokens: string[],
    attributes: LiveActivityStartAttributes,
    state: LiveActivityContentState
  ) => Promise<ApnsResult>;
  recordStart: (token: string, date: Date, groupId: string) => void;
  unregisterStartToken: (token: string) => void;
  now: Date;
  bypassCooldown?: boolean;
}): Promise<{ reason: string; sent: number; failed: number }> {
  const decision = selectPushToStartTargets({
    snap: input.snap,
    startTokens: input.startTokens,
    activityTokens: input.activityTokens,
    startSuppressions: input.startSuppressions,
    now: input.now,
    bypassCooldown: input.bypassCooldown,
  });

  if (decision.targets.length === 0) {
    return { reason: decision.reason, sent: 0, failed: 0 };
  }

  const state = await input.buildState(input.snap);
  const attributes: LiveActivityStartAttributes = {
    speakerName: input.snap.speakerName,
    groupId: input.snap.groupId,
  };
  const targetTokens = decision.targets.map(target => target.token);
  const result = await input.pushStart(targetTokens, attributes, state);

  for (const token of targetTokens) {
    input.recordStart(token, input.now, input.snap.groupId);
  }
  for (const token of result.unregistered) {
    input.unregisterStartToken(token);
  }

  return {
    reason: decision.reason,
    sent: result.sent,
    failed: result.failed,
  };
}
