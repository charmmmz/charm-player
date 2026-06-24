# Live Activity Push-To-Start Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow `nas-relay` to start the Sonos Live Activity on the iPhone when selected Sonos playback begins, without requiring the user to open the iOS app first for each playback session.

**Architecture:** Add a second token lane for ActivityKit push-to-start tokens. The iOS app registers a per-install push-to-start token and observes remotely started activities; `nas-relay` persists those start tokens, sends APNs `event: "start"` only when playback begins and no update-token-backed activity is already active, then reuses the existing activity update-token path after iOS reports the new activity token. The iOS app remains the local fallback when relay or APNs is not ready.

**Tech Stack:** Swift/ActivityKit/WidgetKit on iOS, Express/TypeScript on `nas-relay`, `@parse/node-apn` for APNs liveactivity pushes, existing XCTest and Node `node:test` suites.

---

## File Structure

- Modify `Shared/Models.swift`
  - Add optional `groupId` to `SonosActivityAttributes` so remotely started activities can be matched to the selected Sonos group after app relaunch.
- Modify `Shared/SharedStorage.swift`
  - Persist the latest push-to-start token and successful registration timestamp.
- Modify `Shared/RelayClient.swift`
  - Add `PushToStartRegistrationBody` and `registerPushToStart(...)` for `POST /api/register-push-to-start`.
- Modify `SonosWidget/SonosManager.swift`
  - Observe `Activity<SonosActivityAttributes>.pushToStartTokenUpdates`.
  - Observe `Activity<SonosActivityAttributes>.activityUpdates` to reattach remotely started activities and register their update token.
  - Gate local `Activity.request(...)` creation when relay push-to-start is ready.
- Modify `SonosWidgetTests/RelayManagerTests.swift`
  - Cover push-to-start registration JSON encoding.
- Modify `SonosWidgetTests/LiveActivityUpdatePolicyTests.swift`
  - Cover local-create gating and `groupId` attribute matching policy.
- Create `nas-relay/src/startTokenStore.ts`
  - Disk-backed store for push-to-start tokens, separate from update-token `TokenStore`.
- Create `nas-relay/src/startTokenStore.test.ts`
  - Cover rotation, group lookup, cooldown recording, and pruning.
- Modify `nas-relay/src/types.ts`
  - Add push-to-start registration and start attribute types.
- Modify `nas-relay/src/apns.ts`
  - Add `pushStart(...)` using APNs `event: "start"`, `attributes-type`, `attributes`, `content-state`, and `input-push-token`.
- Modify `nas-relay/src/apns.test.ts`
  - Cover the start notification payload shape in dry-run mode.
- Modify `nas-relay/src/index.ts`
  - Add `/api/register-push-to-start`.
  - Instantiate `StartTokenStore`.
  - Add a small start coordinator called from Sonos change events and registration.
- Create `nas-relay/src/liveActivityStartPolicy.ts`
  - Pure decision helpers for when start pushes are allowed.
- Create `nas-relay/src/liveActivityStartPolicy.test.ts`
  - Cover no-duplicate, cooldown, stopped playback, and fallback cases.

## Task 1: Add Stable Activity Identity

**Files:**
- Modify: `Shared/Models.swift`
- Modify: `SonosWidget/SonosManager.swift`
- Test: `SonosWidgetTests/LiveActivityUpdatePolicyTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these tests to `SonosWidgetTests/LiveActivityUpdatePolicyTests.swift`:

```swift
func testLiveActivityAttributesCarryOptionalGroupID() {
    let attrs = SonosActivityAttributes(
        speakerName: "Playroom",
        groupId: "192.168.50.25"
    )

    XCTAssertEqual(attrs.speakerName, "Playroom")
    XCTAssertEqual(attrs.groupId, "192.168.50.25")
}

func testRelayStartReadyPreventsLocalActivityCreation() {
    XCTAssertFalse(
        SonosManager.shouldCreateLocalLiveActivity(
            currentActivityExists: false,
            shouldKeepActivity: true,
            relayPushToStartReady: true
        )
    )
}

func testLocalActivityCreationRemainsFallbackWhenRelayStartIsNotReady() {
    XCTAssertTrue(
        SonosManager.shouldCreateLocalLiveActivity(
            currentActivityExists: false,
            shouldKeepActivity: true,
            relayPushToStartReady: false
        )
    )
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test \
  -project /Users/charm/Documents/workspace/SonosWidget/SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SonosWidgetTests/LiveActivityUpdatePolicyTests/testLiveActivityAttributesCarryOptionalGroupID \
  -only-testing:SonosWidgetTests/LiveActivityUpdatePolicyTests/testRelayStartReadyPreventsLocalActivityCreation \
  -only-testing:SonosWidgetTests/LiveActivityUpdatePolicyTests/testLocalActivityCreationRemainsFallbackWhenRelayStartIsNotReady
```

Expected: FAIL because `SonosActivityAttributes` has no `groupId` and `shouldCreateLocalLiveActivity(...)` does not exist.

- [ ] **Step 3: Add the minimal model and policy**

In `Shared/Models.swift`, change the attributes struct:

```swift
struct SonosActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var trackTitle: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var positionSeconds: Double
        var durationSeconds: Double
        var dominantColorHex: String?
        var startedAt: Date?
        var endsAt: Date?
        var albumArtThumbnail: Data?
        var groupMemberCount: Int = 1
        var playbackSourceRaw: String? = nil
        var soundbarNightMode: Bool? = nil
        var soundbarSpeechEnhancementRawLevel: Int? = nil
        var liveActivityStyleRaw: String? = nil
        var audioQualityLabel: String? = nil
    }

    var speakerName: String
    var groupId: String? = nil
}
```

In `SonosWidget/SonosManager.swift`, add this pure helper near the other Live Activity policy helpers:

```swift
nonisolated static func shouldCreateLocalLiveActivity(
    currentActivityExists: Bool,
    shouldKeepActivity: Bool,
    relayPushToStartReady: Bool
) -> Bool {
    shouldKeepActivity && !currentActivityExists && !relayPushToStartReady
}
```

When constructing attributes in `manageLiveActivity()`, pass the selected group ID:

```swift
let attrs = SonosActivityAttributes(
    speakerName: speaker.name,
    groupId: liveActivityGroupId()
)
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same `xcodebuild test` command from Step 2.

Expected: PASS for all three tests.

- [ ] **Step 5: Commit**

```bash
git add Shared/Models.swift SonosWidget/SonosManager.swift SonosWidgetTests/LiveActivityUpdatePolicyTests.swift
git commit -m "feat: identify live activities by Sonos group"
```

## Task 2: Add Relay Push-To-Start Token Store

**Files:**
- Create: `nas-relay/src/startTokenStore.ts`
- Create: `nas-relay/src/startTokenStore.test.ts`
- Modify: `nas-relay/src/types.ts`

- [ ] **Step 1: Write the failing tests**

Create `nas-relay/src/startTokenStore.test.ts`:

```ts
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import pino from 'pino';

import { StartTokenStore } from './startTokenStore.js';

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

test('recordStart stores the last start timestamp for cooldown checks', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'sonos-start-token-store-'));
  try {
    const store = new StartTokenStore(dir, pino({ enabled: false }));
    store.register({
      groupId: '192.168.50.25',
      token: 'start-token',
      clientId: 'phone-a',
      speakerName: 'Playroom',
    });

    store.recordStart('start-token', new Date('2026-06-24T08:00:00.000Z'));

    assert.equal(store.forGroup('192.168.50.25')[0]?.lastStartAt, '2026-06-24T08:00:00.000Z');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
```

Add these interfaces to `nas-relay/src/types.ts`:

```ts
export interface PushToStartRegisterRequest {
  groupId: string;
  token: string;
  clientId?: string;
  speakerName?: string;
  liveActivityStyleRaw?: string | null;
}

export interface PushToStartTokenEntry extends PushToStartRegisterRequest {
  registeredAt: string;
  lastStartAt?: string;
}

export interface LiveActivityStartAttributes {
  speakerName: string;
  groupId?: string | null;
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/nas-relay
node --import tsx --test src/startTokenStore.test.ts
```

Expected: FAIL because `startTokenStore.ts` does not exist.

- [ ] **Step 3: Implement the store**

Create `nas-relay/src/startTokenStore.ts`:

```ts
import { promises as fs } from 'node:fs';
import path from 'node:path';
import type { Logger } from 'pino';
import type { PushToStartRegisterRequest, PushToStartTokenEntry } from './types.js';

export class StartTokenStore {
  private readonly tokens = new Map<string, PushToStartTokenEntry>();
  private readonly path: string;
  private readonly log: Logger;
  private flushPromise: Promise<void> | null = null;

  constructor(dataDir: string, log: Logger) {
    this.path = path.join(dataDir, 'start-tokens.json');
    this.log = log.child({ module: 'startTokenStore' });
  }

  async load(): Promise<void> {
    try {
      const raw = await fs.readFile(this.path, 'utf8');
      const parsed = JSON.parse(raw) as PushToStartTokenEntry[];
      for (const entry of parsed) this.tokens.set(entry.token, entry);
      this.log.info({ count: this.tokens.size }, 'loaded persisted push-to-start tokens');
    } catch (err: any) {
      if (err.code !== 'ENOENT') {
        this.log.warn({ err }, 'failed to load start-tokens.json');
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
    };
    this.tokens.set(req.token, entry);
    void this.flush();
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
    if (removed) void this.flush();
    return removed;
  }

  forGroup(groupId: string): PushToStartTokenEntry[] {
    return Array.from(this.tokens.values()).filter(entry => entry.groupId === groupId);
  }

  recordStart(token: string, date: Date): void {
    const entry = this.tokens.get(token);
    if (!entry) return;
    entry.lastStartAt = date.toISOString();
    void this.flush();
  }

  private pruneSupersededTokens(req: PushToStartRegisterRequest): number {
    if (!req.clientId) return 0;
    let removed = 0;
    for (const [token, entry] of this.tokens.entries()) {
      if (token === req.token) continue;
      if (entry.groupId === req.groupId && entry.clientId === req.clientId) {
        this.tokens.delete(token);
        removed += 1;
      }
    }
    return removed;
  }

  private async flush(): Promise<void> {
    if (this.flushPromise) return this.flushPromise;
    this.flushPromise = new Promise<void>(resolve => {
      setTimeout(async () => {
        try {
          const data = JSON.stringify(Array.from(this.tokens.values()), null, 2);
          await fs.writeFile(this.path, data, 'utf8');
        } catch (err) {
          this.log.error({ err }, 'failed to persist start-tokens.json');
        } finally {
          this.flushPromise = null;
          resolve();
        }
      }, 100);
    });
    return this.flushPromise;
  }
}

function shortToken(token: string): string {
  return token.length <= 12 ? token : `${token.slice(0, 8)}…${token.slice(-4)}`;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/nas-relay
node --import tsx --test src/startTokenStore.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add nas-relay/src/types.ts nas-relay/src/startTokenStore.ts nas-relay/src/startTokenStore.test.ts
git commit -m "feat: persist live activity push-to-start tokens"
```

## Task 3: Add APNs Start Push Support

**Files:**
- Modify: `nas-relay/src/apns.ts`
- Modify: `nas-relay/src/apns.test.ts`

- [ ] **Step 1: Write the failing tests**

Add to `nas-relay/src/apns.test.ts`:

```ts
import { makeLiveActivityStartNotification } from './apns.js';

test('APNs start notification includes ActivityKit start fields', () => {
  const note = makeLiveActivityStartNotification(
    'com.charm.SonosWidget',
    { speakerName: 'Playroom', groupId: '192.168.50.25' },
    {
      trackTitle: 'Nude',
      artist: 'Radiohead',
      album: 'In Rainbows',
      isPlaying: true,
      positionSeconds: 12,
      durationSeconds: 255,
      groupMemberCount: 1,
      playbackSourceRaw: 'appleMusic',
      liveActivityStyleRaw: 'widget',
    },
    1_782_000_000,
  ) as any;

  assert.equal(note.topic, 'com.charm.SonosWidget.push-type.liveactivity');
  assert.equal(note.pushType, 'liveactivity');
  assert.equal(note.aps.event, 'start');
  assert.equal(note.aps['attributes-type'], 'SonosActivityAttributes');
  assert.deepEqual(note.aps.attributes, {
    speakerName: 'Playroom',
    groupId: '192.168.50.25',
  });
  assert.equal(note.aps['input-push-token'], 1);
  assert.equal(note.aps['content-state'].trackTitle, 'Nude');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/nas-relay
node --import tsx --test src/apns.test.ts
```

Expected: FAIL because `makeLiveActivityStartNotification` does not exist.

- [ ] **Step 3: Implement notification construction and pushStart**

In `nas-relay/src/apns.ts`, import the start attributes type:

```ts
import type { LiveActivityContentState, LiveActivityStartAttributes } from './types.js';
```

Add this helper near the existing APNs methods:

```ts
export function makeLiveActivityStartNotification(
  bundleId: string,
  attributes: LiveActivityStartAttributes,
  contentState: LiveActivityContentState,
  nowUnixSeconds = Math.floor(Date.now() / 1000),
): apn.Notification {
  type LiveActivityStartNote = apn.Notification & {
    pushType: string;
    timestamp: number;
    staleDate: number;
    event: 'start';
    attributesType: string;
    attributes: Record<string, unknown>;
    contentState: Record<string, unknown>;
    inputPushToken: number;
  };

  const note = new apn.Notification() as LiveActivityStartNote;
  note.topic = `${bundleId}.push-type.liveactivity`;
  note.pushType = 'liveactivity';
  note.expiry = nowUnixSeconds + 3600;
  note.timestamp = nowUnixSeconds;
  note.staleDate = nowUnixSeconds + 8 * 3600;
  note.event = 'start';
  note.attributesType = 'SonosActivityAttributes';
  note.attributes = attributes as Record<string, unknown>;
  note.contentState = contentState as unknown as Record<string, unknown>;
  note.inputPushToken = 1;
  return note;
}
```

Add this method to `ApnsClient`:

```ts
async pushStart(
  tokens: string[],
  attributes: LiveActivityStartAttributes,
  contentState: LiveActivityContentState,
): Promise<ApnsResult> {
  if (tokens.length === 0) return { sent: 0, failed: 0, unregistered: [] };
  const note = makeLiveActivityStartNotification(this.config.bundleId, attributes, contentState);

  if (this.dryRun || !this.provider) {
    this.log.info({
      source: 'relay',
      action: 'apns-dry-run',
      event: 'start',
      tokens: tokens.length,
      attributes,
      state: summarizeLiveActivityState(contentState),
    }, 'live_activity');
    return { sent: tokens.length, failed: 0, unregistered: [] };
  }

  const result: ApnsResult = { sent: 0, failed: 0, unregistered: [] };
  try {
    const response = await this.provider.send(note, tokens);
    result.sent = response.sent.length;
    for (const failure of response.failed) {
      result.failed += 1;
      if (failure.status === 410 && failure.device) {
        result.unregistered.push(failure.device);
      } else {
        this.log.warn({ failure }, 'APNs push-to-start failed');
      }
    }
  } catch (err) {
    this.log.error({ err }, 'APNs push-to-start threw');
    result.failed = tokens.length;
  }
  return result;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/nas-relay
node --import tsx --test src/apns.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add nas-relay/src/apns.ts nas-relay/src/apns.test.ts
git commit -m "feat: build live activity push-to-start payloads"
```

## Task 4: Add Relay Start Policy

**Files:**
- Create: `nas-relay/src/liveActivityStartPolicy.ts`
- Create: `nas-relay/src/liveActivityStartPolicy.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `nas-relay/src/liveActivityStartPolicy.test.ts`:

```ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { PushToStartTokenEntry, SonosGroupSnapshot, TokenEntry } from './types.js';
import { selectPushToStartTargets } from './liveActivityStartPolicy.js';

const snap: SonosGroupSnapshot = {
  groupId: '192.168.50.25',
  speakerName: 'Playroom',
  trackTitle: 'Nude',
  artist: 'Radiohead',
  album: 'In Rainbows',
  albumArtUri: null,
  isPlaying: true,
  positionSeconds: 10,
  durationSeconds: 255,
  groupMemberCount: 1,
  sampledAt: new Date('2026-06-24T08:00:00.000Z'),
};

const startToken: PushToStartTokenEntry = {
  groupId: '192.168.50.25',
  token: 'start-token',
  clientId: 'phone-a',
  speakerName: 'Playroom',
  registeredAt: '2026-06-24T07:00:00.000Z',
};

test('selects start tokens when playback is active and no activity token exists', () => {
  const decision = selectPushToStartTargets({
    snap,
    startTokens: [startToken],
    activityTokens: [],
    now: new Date('2026-06-24T08:00:00.000Z'),
  });

  assert.equal(decision.reason, 'start');
  assert.deepEqual(decision.targets.map(t => t.token), ['start-token']);
});

test('does not start when an update-token-backed activity is already active', () => {
  const activityTokens: TokenEntry[] = [{
    groupId: '192.168.50.25',
    token: 'activity-token',
    clientId: 'phone-a',
    activityId: 'activity-1',
    registeredAt: '2026-06-24T07:59:00.000Z',
  }];

  const decision = selectPushToStartTargets({
    snap,
    startTokens: [startToken],
    activityTokens,
    now: new Date('2026-06-24T08:00:00.000Z'),
  });

  assert.equal(decision.reason, 'activity-token-active');
  assert.deepEqual(decision.targets, []);
});

test('does not start during cooldown after a recent start push', () => {
  const decision = selectPushToStartTargets({
    snap,
    startTokens: [{ ...startToken, lastStartAt: '2026-06-24T07:59:30.000Z' }],
    activityTokens: [],
    now: new Date('2026-06-24T08:00:00.000Z'),
    cooldownMs: 90_000,
  });

  assert.equal(decision.reason, 'cooldown');
  assert.deepEqual(decision.targets, []);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/nas-relay
node --import tsx --test src/liveActivityStartPolicy.test.ts
```

Expected: FAIL because `liveActivityStartPolicy.ts` does not exist.

- [ ] **Step 3: Implement the pure policy**

Create `nas-relay/src/liveActivityStartPolicy.ts`:

```ts
import type { PushToStartTokenEntry, SonosGroupSnapshot, TokenEntry } from './types.js';

export interface PushToStartDecisionInput {
  snap: SonosGroupSnapshot;
  startTokens: PushToStartTokenEntry[];
  activityTokens: TokenEntry[];
  now: Date;
  cooldownMs?: number;
}

export interface PushToStartDecision {
  reason: 'start' | 'not-playing' | 'no-start-token' | 'activity-token-active' | 'cooldown';
  targets: PushToStartTokenEntry[];
}

export function selectPushToStartTargets(input: PushToStartDecisionInput): PushToStartDecision {
  if (!input.snap.isPlaying) return { reason: 'not-playing', targets: [] };
  if (input.activityTokens.length > 0) {
    return { reason: 'activity-token-active', targets: [] };
  }
  if (input.startTokens.length === 0) return { reason: 'no-start-token', targets: [] };

  const cooldownMs = input.cooldownMs ?? 90_000;
  const targets = input.startTokens.filter(entry => {
    if (!entry.lastStartAt) return true;
    const lastStartMs = Date.parse(entry.lastStartAt);
    return Number.isNaN(lastStartMs) || input.now.getTime() - lastStartMs >= cooldownMs;
  });

  if (targets.length === 0) return { reason: 'cooldown', targets: [] };
  return { reason: 'start', targets };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/nas-relay
node --import tsx --test src/liveActivityStartPolicy.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add nas-relay/src/liveActivityStartPolicy.ts nas-relay/src/liveActivityStartPolicy.test.ts
git commit -m "feat: decide when relay may start live activities"
```

## Task 5: Wire Relay Registration And Start Coordinator

**Files:**
- Modify: `nas-relay/src/index.ts`
- Modify: `nas-relay/src/types.ts`
- Test: `nas-relay/src/liveActivityContentState.test.ts` or new route tests if the current test harness already spins Express routes.

- [ ] **Step 1: Write the failing route/policy integration test**

If no Express app factory exists, keep this as a pure test around an exported helper. Export this helper from `nas-relay/src/index.ts` or a small new file `nas-relay/src/liveActivityStartCoordinator.ts`:

```ts
export async function maybeStartLiveActivityForSnapshot(input: {
  snap: SonosGroupSnapshot;
  startTokens: PushToStartTokenEntry[];
  activityTokens: TokenEntry[];
  buildState: (snap: SonosGroupSnapshot) => Promise<LiveActivityContentState>;
  pushStart: (
    tokens: string[],
    attributes: LiveActivityStartAttributes,
    state: LiveActivityContentState
  ) => Promise<ApnsResult>;
  recordStart: (token: string, date: Date) => void;
  unregisterStartToken: (token: string) => void;
  now: Date;
}): Promise<{ reason: string; sent: number; failed: number }>;
```

Add a test asserting the coordinator sends one start push with attributes:

```ts
test('coordinator starts live activity with Sonos attributes and content state', async () => {
  const sent: Array<{ tokens: string[]; attributes: LiveActivityStartAttributes }> = [];
  const result = await maybeStartLiveActivityForSnapshot({
    snap,
    startTokens: [startToken],
    activityTokens: [],
    now: new Date('2026-06-24T08:00:00.000Z'),
    buildState: async () => ({
      trackTitle: 'Nude',
      artist: 'Radiohead',
      album: 'In Rainbows',
      isPlaying: true,
      positionSeconds: 10,
      durationSeconds: 255,
      groupMemberCount: 1,
    }),
    pushStart: async (tokens, attributes) => {
      sent.push({ tokens, attributes });
      return { sent: tokens.length, failed: 0, unregistered: [] };
    },
    recordStart: () => {},
    unregisterStartToken: () => {},
  });

  assert.equal(result.reason, 'start');
  assert.equal(result.sent, 1);
  assert.deepEqual(sent, [{
    tokens: ['start-token'],
    attributes: { speakerName: 'Playroom', groupId: '192.168.50.25' },
  }]);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/nas-relay
node --import tsx --test src/liveActivityStartCoordinator.test.ts
```

Expected: FAIL because the coordinator does not exist.

- [ ] **Step 3: Implement coordinator and endpoint**

Create `nas-relay/src/liveActivityStartCoordinator.ts` with:

```ts
import type {
  ApnsResult,
} from './apns.js';
import type {
  LiveActivityContentState,
  LiveActivityStartAttributes,
  PushToStartTokenEntry,
  SonosGroupSnapshot,
  TokenEntry,
} from './types.js';
import { selectPushToStartTargets } from './liveActivityStartPolicy.js';

export async function maybeStartLiveActivityForSnapshot(input: {
  snap: SonosGroupSnapshot;
  startTokens: PushToStartTokenEntry[];
  activityTokens: TokenEntry[];
  buildState: (snap: SonosGroupSnapshot) => Promise<LiveActivityContentState>;
  pushStart: (
    tokens: string[],
    attributes: LiveActivityStartAttributes,
    state: LiveActivityContentState
  ) => Promise<ApnsResult>;
  recordStart: (token: string, date: Date) => void;
  unregisterStartToken: (token: string) => void;
  now: Date;
}): Promise<{ reason: string; sent: number; failed: number }> {
  const decision = selectPushToStartTargets({
    snap: input.snap,
    startTokens: input.startTokens,
    activityTokens: input.activityTokens,
    now: input.now,
  });
  if (decision.targets.length === 0) {
    return { reason: decision.reason, sent: 0, failed: 0 };
  }

  const state = await input.buildState(input.snap);
  const attributes: LiveActivityStartAttributes = {
    speakerName: input.snap.speakerName,
    groupId: input.snap.groupId,
  };
  const result = await input.pushStart(
    decision.targets.map(entry => entry.token),
    attributes,
    state,
  );
  for (const entry of decision.targets) input.recordStart(entry.token, input.now);
  for (const dead of result.unregistered) input.unregisterStartToken(dead);
  return { reason: decision.reason, sent: result.sent, failed: result.failed };
}
```

In `nas-relay/src/index.ts`:

```ts
import { StartTokenStore } from './startTokenStore.js';
import { maybeStartLiveActivityForSnapshot } from './liveActivityStartCoordinator.js';
```

After `TokenStore` creation:

```ts
const startTokens = new StartTokenStore(DATA_DIR, log);
await startTokens.load();
```

Add route:

```ts
app.post('/api/register-push-to-start', async (req, res) => {
  const body = req.body as Partial<PushToStartRegisterRequest>;
  if (!body.groupId || !body.token) {
    res.status(400).json({ error: 'groupId and token are required' });
    return;
  }

  const entry = startTokens.register({
    groupId: body.groupId,
    token: body.token,
    clientId: body.clientId,
    speakerName: body.speakerName,
    liveActivityStyleRaw: body.liveActivityStyleRaw,
  });
  liveActivityPreferences.update({
    groupId: body.groupId,
    liveActivityStyleRaw: body.liveActivityStyleRaw,
  });

  const snap = sonos.current(body.groupId);
  if (snap?.isPlaying) {
    const enrichedSnap = liveActivityPreferences.apply(snap);
    await maybeStartLiveActivityForSnapshot({
      snap: enrichedSnap,
      startTokens: [entry],
      activityTokens: tokens.forGroup(body.groupId),
      now: new Date(),
      buildState: currentSnap => buildLiveActivityContentState(currentSnap, {
        logger: liveActivityArtworkLog,
        logContext: { trigger: 'register-push-to-start' },
      }),
      pushStart: (targetTokens, attributes, state) => apns.pushStart(targetTokens, attributes, state),
      recordStart: (token, date) => startTokens.recordStart(token, date),
      unregisterStartToken: token => startTokens.unregister(token),
    });
  }

  res.json({ ok: true });
});
```

In the existing `sonos.on('change', ...)` handler, after computing `trigger` and before normal update pushes:

```ts
await maybeStartLiveActivityForSnapshot({
  snap: liveActivityPreferences.apply(snap),
  startTokens: startTokens.forGroup(snap.groupId),
  activityTokens: tokens.forGroup(snap.groupId),
  now: new Date(),
  buildState: currentSnap => buildLiveActivityContentState(currentSnap, {
    logger: liveActivityArtworkLog,
    logContext: { trigger: `${trigger}:start` },
  }),
  pushStart: (targetTokens, attributes, state) => apns.pushStart(targetTokens, attributes, state),
  recordStart: (token, date) => startTokens.recordStart(token, date),
  unregisterStartToken: token => startTokens.unregister(token),
});
```

- [ ] **Step 4: Run tests and typecheck**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/nas-relay
node --import tsx --test src/liveActivityStartCoordinator.test.ts src/liveActivityStartPolicy.test.ts src/startTokenStore.test.ts
npm run build
```

Expected: tests PASS and TypeScript build exits 0.

- [ ] **Step 5: Commit**

```bash
git add nas-relay/src/index.ts nas-relay/src/liveActivityStartCoordinator.ts nas-relay/src/liveActivityStartCoordinator.test.ts
git commit -m "feat: start live activities from relay playback events"
```

## Task 6: Add iOS Push-To-Start Registration Client

**Files:**
- Modify: `Shared/RelayClient.swift`
- Modify: `SonosWidgetTests/RelayManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `SonosWidgetTests/RelayManagerTests.swift`:

```swift
func testPushToStartRegistrationEncodesClientGroupAndStyle() throws {
    let body = RelayClient.PushToStartRegistrationBody(
        groupId: "192.168.50.25",
        token: "push-to-start-token",
        clientId: "client-1",
        speakerName: "Playroom",
        liveActivityStyleRaw: "widget"
    )

    let data = try JSONEncoder().encode(body)
    let json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    XCTAssertEqual(json["groupId"] as? String, "192.168.50.25")
    XCTAssertEqual(json["token"] as? String, "push-to-start-token")
    XCTAssertEqual(json["clientId"] as? String, "client-1")
    XCTAssertEqual(json["speakerName"] as? String, "Playroom")
    XCTAssertEqual(json["liveActivityStyleRaw"] as? String, "widget")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test \
  -project /Users/charm/Documents/workspace/SonosWidget/SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SonosWidgetTests/RelayManagerTests/testPushToStartRegistrationEncodesClientGroupAndStyle
```

Expected: FAIL because `PushToStartRegistrationBody` does not exist.

- [ ] **Step 3: Implement RelayClient request**

In `Shared/RelayClient.swift`, add:

```swift
struct PushToStartRegistrationBody: Encodable, Sendable {
    let groupId: String
    let token: String
    let clientId: String
    let speakerName: String?
    let liveActivityStyleRaw: String?
}

static func registerPushToStart(
    baseURL: URL,
    groupId: String,
    token: String,
    clientId: String,
    speakerName: String?,
    liveActivityStyleRaw: String?
) async throws {
    let url = baseURL.appendingPathComponent("/api/register-push-to-start")
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
        PushToStartRegistrationBody(
            groupId: groupId,
            token: token,
            clientId: clientId,
            speakerName: speakerName,
            liveActivityStyleRaw: liveActivityStyleRaw
        )
    )
    let (_, response) = try await noProxySession.data(for: request)
    try validate(response)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild test` command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/RelayClient.swift SonosWidgetTests/RelayManagerTests.swift
git commit -m "feat: register live activity push-to-start tokens from iOS"
```

## Task 7: Observe Push-To-Start Tokens And Remote Activities In iOS

**Files:**
- Modify: `Shared/SharedStorage.swift`
- Modify: `SonosWidget/SonosManager.swift`
- Modify: `SonosWidgetTests/LiveActivityUpdatePolicyTests.swift`

- [ ] **Step 1: Write failing policy tests**

Add to `SonosWidgetTests/LiveActivityUpdatePolicyTests.swift`:

```swift
func testRelayPushToStartReadyRequiresRelayAndAPNsAndRegistration() {
    XCTAssertTrue(
        SonosManager.isRelayPushToStartReady(
            relayAvailable: true,
            apnsMode: .ready,
            hasRegisteredPushToStartToken: true
        )
    )

    XCTAssertFalse(
        SonosManager.isRelayPushToStartReady(
            relayAvailable: true,
            apnsMode: .dryRun,
            hasRegisteredPushToStartToken: true
        )
    )

    XCTAssertFalse(
        SonosManager.isRelayPushToStartReady(
            relayAvailable: true,
            apnsMode: .ready,
            hasRegisteredPushToStartToken: false
        )
    )
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test \
  -project /Users/charm/Documents/workspace/SonosWidget/SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SonosWidgetTests/LiveActivityUpdatePolicyTests/testRelayPushToStartReadyRequiresRelayAndAPNsAndRegistration
```

Expected: FAIL because `isRelayPushToStartReady(...)` does not exist.

- [ ] **Step 3: Add storage and policy**

In `Shared/SharedStorage.swift`, add:

```swift
nonisolated static var liveActivityPushToStartToken: String? {
    get { defaults.string(forKey: "liveActivityPushToStartToken") }
    set { defaults.set(newValue, forKey: "liveActivityPushToStartToken") }
}

nonisolated static var liveActivityPushToStartRegisteredAt: Date {
    get {
        let ts = defaults.double(forKey: "liveActivityPushToStartRegisteredAt")
        return ts == 0 ? .distantPast : Date(timeIntervalSince1970: ts)
    }
    set { defaults.set(newValue.timeIntervalSince1970, forKey: "liveActivityPushToStartRegisteredAt") }
}
```

In `SonosWidget/SonosManager.swift`, add:

```swift
nonisolated static func isRelayPushToStartReady(
    relayAvailable: Bool,
    apnsMode: RelayClient.HealthResponse.APNs.Mode?,
    hasRegisteredPushToStartToken: Bool
) -> Bool {
    relayAvailable && apnsMode == .ready && hasRegisteredPushToStartToken
}
```

- [ ] **Step 4: Add observers**

Add properties:

```swift
private var pushToStartTokenTask: Task<Void, Never>?
private var activityUpdatesTask: Task<Void, Never>?
```

Start them from the same lifecycle location that starts auto-refresh:

```swift
private func startLiveActivityPushToStartObservers() {
    pushToStartTokenTask?.cancel()
    pushToStartTokenTask = Task { [weak self] in
        for await tokenData in Activity<SonosActivityAttributes>.pushToStartTokenUpdates {
            guard !Task.isCancelled else { return }
            let hex = tokenData.map { String(format: "%02x", $0) }.joined()
            await MainActor.run {
                SharedStorage.liveActivityPushToStartToken = hex
                self?.registerPushToStartTokenIfPossible(hex, reason: "push-to-start-token-update")
            }
        }
    }

    activityUpdatesTask?.cancel()
    activityUpdatesTask = Task { [weak self] in
        for await activity in Activity<SonosActivityAttributes>.activityUpdates {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.attachLiveActivityIfNeeded(activity, reason: "activity-updates")
            }
        }
    }
}
```

Add registration:

```swift
private func registerPushToStartTokenIfPossible(_ token: String, reason: String) {
    guard RelayManager.shared.isAvailable,
          let url = RelayManager.shared.url,
          let groupId = liveActivityGroupId() else {
        logLiveActivity(action: "register-push-to-start-skip", reason: "missing-relay-or-group")
        return
    }

    let speakerName = selectedSpeaker?.name
    Task {
        do {
            try await RelayClient.registerPushToStart(
                baseURL: url,
                groupId: groupId,
                token: token,
                clientId: SharedStorage.liveActivityRelayClientID,
                speakerName: speakerName,
                liveActivityStyleRaw: SharedStorage.liveActivityStyle.rawValue
            )
            await MainActor.run {
                SharedStorage.liveActivityPushToStartRegisteredAt = Date()
                self.logLiveActivity(action: "register-push-to-start-success",
                                     mode: "relay-token",
                                     token: token,
                                     groupId: groupId,
                                     relayURL: url,
                                     extra: ["reason=\(reason)"])
            }
        } catch {
            await MainActor.run {
                self.logLiveActivity(action: "register-push-to-start-failed",
                                     mode: "relay-token",
                                     reason: error.localizedDescription,
                                     token: token,
                                     groupId: groupId,
                                     relayURL: url)
            }
        }
    }
}
```

Add remote attach:

```swift
private func attachLiveActivityIfNeeded(
    _ activity: Activity<SonosActivityAttributes>,
    reason: String
) {
    let expectedGroupId = liveActivityGroupId()
    if let activityGroupId = activity.attributes.groupId,
       let expectedGroupId,
       activityGroupId != expectedGroupId {
        logLiveActivity(action: "remote-activity-ignore",
                        activityID: activity.id,
                        reason: "group-mismatch",
                        groupId: activityGroupId)
        return
    }

    currentActivity = activity
    currentActivityUsesRelay = true
    liveActivityRelayWriterReady = false
    logLiveActivity(action: "remote-activity-attach",
                    activityID: activity.id,
                    mode: "relay-token",
                    groupId: activity.attributes.groupId,
                    extra: ["reason=\(reason)"])
    spawnPushTokenObserver(
        activity: activity,
        speakerName: activity.attributes.speakerName
    )
}
```

- [ ] **Step 5: Gate local creation**

In `manageLiveActivity()`, before local creation:

```swift
let relayPushToStartReady = Self.isRelayPushToStartReady(
    relayAvailable: RelayManager.shared.isAvailable,
    apnsMode: RelayManager.shared.relayAPNs?.mode,
    hasRegisteredPushToStartToken: SharedStorage.liveActivityPushToStartRegisteredAt > .distantPast
)

guard Self.shouldCreateLocalLiveActivity(
    currentActivityExists: currentActivity != nil,
    shouldKeepActivity: shouldKeep,
    relayPushToStartReady: relayPushToStartReady
) else {
    if currentActivity == nil {
        logLiveActivity(action: "skip-create",
                        mode: "relay-token",
                        reason: "relay-push-to-start-ready")
        if let token = SharedStorage.liveActivityPushToStartToken {
            registerPushToStartTokenIfPossible(token, reason: "skip-create-refresh")
        }
    }
    return
}
```

- [ ] **Step 6: Run tests and build**

Run:

```bash
xcodebuild test \
  -project /Users/charm/Documents/workspace/SonosWidget/SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SonosWidgetTests/LiveActivityUpdatePolicyTests/testRelayPushToStartReadyRequiresRelayAndAPNsAndRegistration

xcodebuild build \
  -project /Users/charm/Documents/workspace/SonosWidget/SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Expected: test PASS and build exits 0.

- [ ] **Step 7: Commit**

```bash
git add Shared/SharedStorage.swift SonosWidget/SonosManager.swift SonosWidgetTests/LiveActivityUpdatePolicyTests.swift
git commit -m "feat: let iOS join relay-started live activities"
```

## Task 8: End-To-End Verification And Diagnostics

**Files:**
- Modify: `README.md` or `nas-relay/README.md`
- Modify: `nas-relay/src/index.ts`
- Test: existing iOS and relay suites

- [ ] **Step 1: Add visible health diagnostics**

In `nas-relay/src/index.ts` health response, include start token counts:

```ts
liveActivity: {
  startTokenCount: startTokens.count(),
  updateTokenCount: tokens.count(),
}
```

Add `count()` to both token stores:

```ts
count(): number {
  return this.tokens.size;
}
```

- [ ] **Step 2: Document setup**

In `nas-relay/README.md`, add:

```markdown
### Live Activity push-to-start

The relay can start the iOS Live Activity when Sonos playback begins. The iOS app must have run at least once after install so it can upload an ActivityKit push-to-start token. APNs must be configured with `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_PATH`, `APNS_PRODUCTION`, and `APNS_BUNDLE_ID`.

Expected flow:

1. Open Charm Player once on the iPhone while the relay is reachable.
2. Confirm `/api/health` reports `apns.mode: "ready"` and `liveActivity.startTokenCount > 0`.
3. Start playback on the selected Sonos group without opening the app.
4. The relay sends an APNs `start` push.
5. iOS creates the Live Activity and reports an update token back to `/api/register-activity`.
```

- [ ] **Step 3: Run relay verification**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/nas-relay
npm test
npm run build
```

Expected: all Node tests PASS and TypeScript build exits 0.

- [ ] **Step 4: Run iOS verification**

Run:

```bash
xcodebuild test \
  -project /Users/charm/Documents/workspace/SonosWidget/SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SonosWidgetTests/LiveActivityUpdatePolicyTests \
  -only-testing:SonosWidgetTests/RelayManagerTests

xcodebuild build \
  -project /Users/charm/Documents/workspace/SonosWidget/SonosWidget.xcodeproj \
  -scheme TheWidgetExtension \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Expected: selected XCTest suites PASS and Widget extension build exits 0.

- [ ] **Step 5: Manual device verification**

Use a real iPhone because APNs push-to-start cannot be validated fully in the simulator:

```bash
curl http://<relay-host>:8787/api/health
```

Expected before playback:

```json
{
  "apns": { "mode": "ready" },
  "liveActivity": {
    "startTokenCount": 1,
    "updateTokenCount": 0
  }
}
```

Then start Sonos playback without opening the iOS app. Expected relay log sequence:

```text
live_activity action=apns-start trigger=sonos-change groupId=<group>
live_activity action=register-request groupId=<group> activityId=<activity>
live_activity action=apns-update trigger=register-initial groupId=<group>
```

Expected iPhone behavior: one Live Activity appears, it updates track metadata, and opening the app does not create a duplicate.

- [ ] **Step 6: Commit**

```bash
git add README.md nas-relay/README.md nas-relay/src/index.ts nas-relay/src/tokenStore.ts nas-relay/src/startTokenStore.ts
git commit -m "docs: describe live activity push-to-start verification"
```

## Self-Review

- Spec coverage: The plan covers remote start token registration, APNs start push construction, relay no-duplicate policy, iOS reattachment, local fallback, diagnostics, automated tests, and real-device verification.
- Placeholder scan: The plan contains exact file paths, commands, payload fields, and code snippets. It avoids undefined future work.
- Type consistency: `PushToStartRegisterRequest`, `PushToStartTokenEntry`, and `LiveActivityStartAttributes` are introduced before use. `groupId` exists in both Swift attributes and relay start attributes. The existing `TokenStore` remains responsible only for activity update tokens.
