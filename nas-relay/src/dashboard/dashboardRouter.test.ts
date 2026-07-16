import assert from 'node:assert/strict';
import express from 'express';
import { test } from 'node:test';
import pino from 'pino';

import { DeviceLogService } from '../diagnostics/deviceLogs.js';
import { RelayLogBuffer } from '../diagnostics/relayLogs.js';
import type { HueAmbienceMappingConfiguration, HueSonosMapping } from '../hue/hueTypes.js';
import type { SonosGroupSnapshot } from '../types.js';
import {
  createDashboardRouter,
  dashboardOptionsFromEnv,
  type DashboardDependencies,
} from './dashboardRouter.js';

test('dashboard options reuse the MCP token and clamp session lifetime', () => {
  assert.deepEqual(dashboardOptionsFromEnv({ DASHBOARD_SESSION_HOURS: '999' }, 'mcp-secret'), {
    token: 'mcp-secret',
    sessionTtlMs: 168 * 60 * 60 * 1_000,
    secureCookie: false,
  });
  assert.equal(dashboardOptionsFromEnv({ DASHBOARD_TOKEN: 'dashboard-secret' }, 'mcp-secret').token, 'dashboard-secret');
});

test('dashboard requires login, returns sanitized aggregate state, and reuses Sonos controls', async () => {
  const controller = new FakeDashboardSonos();
  const relayLogs = new RelayLogBuffer();
  relayLogs.capture(30, [{ token: 'relay-log-secret', groupId: '192.168.50.25' }, 'ready']);
  const dependencies = fakeDependencies(controller, relayLogs);
  const service = await startDashboardServer(dependencies);

  try {
    const unauthenticated = await fetch(`${service.baseURL}/api/dashboard/state`);
    assert.equal(unauthenticated.status, 401);

    const badLogin = await fetch(`${service.baseURL}/api/dashboard/session`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'wrong' }),
    });
    assert.equal(badLogin.status, 401);

    const login = await fetch(`${service.baseURL}/api/dashboard/session`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'dashboard-secret' }),
    });
    assert.equal(login.status, 200);
    const cookie = login.headers.get('set-cookie')?.split(';')[0];
    assert(cookie);
    assert.match(login.headers.get('set-cookie') ?? '', /HttpOnly/);
    assert.match(login.headers.get('set-cookie') ?? '', /SameSite=Strict/);

    const stateResponse = await fetch(`${service.baseURL}/api/dashboard/state`, {
      headers: { Cookie: cookie },
    });
    assert.equal(stateResponse.status, 200);
    const stateText = await stateResponse.text();
    assert.doesNotMatch(stateText, /dashboard-secret|mcp-secret|push-token|hue-application-key/);
    const state = JSON.parse(stateText);
    assert.equal(state.sonos.groups[0].speakerName, 'Living Room');
    assert.equal(state.sonos.groups[0].groupVolume, 28);
    assert.equal(state.liveActivity.updateTokenCount, 1);
    assert.equal(state.mcp.maxVolume, 70);
    assert.deepEqual(state.hue.mappingSetup.targets.map((target: { id: string }) => target.id), ['ent-1', 'room-1']);
    assert.equal(state.hue.mappingSetup.assignments[0].relayGroupID, '192.168.50.25');

    const themeResponse = await fetch(
      `${service.baseURL}/api/dashboard/artwork-theme?url=${encodeURIComponent('https://example.com/cover.jpg')}`,
      { headers: { Cookie: cookie } },
    );
    assert.equal(themeResponse.status, 200);
    assert.deepEqual(await themeResponse.json(), { ok: true, color: '#E58A66' });

    const invalidThemeResponse = await fetch(
      `${service.baseURL}/api/dashboard/artwork-theme?url=${encodeURIComponent('file:///etc/passwd')}`,
      { headers: { Cookie: cookie } },
    );
    assert.equal(invalidThemeResponse.status, 400);

    const overLimit = await fetch(`${service.baseURL}/api/dashboard/sonos/volume`, {
      method: 'POST',
      headers: { Cookie: cookie, 'Content-Type': 'application/json' },
      body: JSON.stringify({ target: 'Living Room', volume: 71 }),
    });
    assert.equal(overLimit.status, 400);

    const control = await fetch(`${service.baseURL}/api/dashboard/sonos/pause`, {
      method: 'POST',
      headers: { Cookie: cookie, 'Content-Type': 'application/json' },
      body: JSON.stringify({ target: 'Living' }),
    });
    assert.equal(control.status, 200);
    assert.deepEqual(controller.calls, [{ action: 'pause', groupId: '192.168.50.25' }]);

    const memberVolume = await fetch(`${service.baseURL}/api/dashboard/sonos/member-volume`, {
      method: 'POST',
      headers: { Cookie: cookie, 'Content-Type': 'application/json' },
      body: JSON.stringify({ target: 'Living Room', memberId: 'uuid-living', volume: 24 }),
    });
    assert.equal(memberVolume.status, 200);
    assert.deepEqual(controller.calls.slice(-1), [
      { action: 'member-volume', groupId: '192.168.50.25' },
    ]);

    const grouped = await fetch(`${service.baseURL}/api/dashboard/sonos/group`, {
      method: 'POST',
      headers: { Cookie: cookie, 'Content-Type': 'application/json' },
      body: JSON.stringify({ source: 'Kitchen', into: 'Living Room' }),
    });
    assert.equal(grouped.status, 200);

    const ungrouped = await fetch(`${service.baseURL}/api/dashboard/sonos/ungroup`, {
      method: 'POST',
      headers: { Cookie: cookie, 'Content-Type': 'application/json' },
      body: JSON.stringify({ target: 'Living Room' }),
    });
    assert.equal(ungrouped.status, 200);
    assert.deepEqual(controller.calls.slice(-2), [
      { action: 'group', groupId: '192.168.50.30', intoGroupId: '192.168.50.25' },
      { action: 'ungroup', groupId: '192.168.50.25' },
    ]);

    const logsResponse = await fetch(`${service.baseURL}/api/dashboard/logs`, {
      headers: { Cookie: cookie },
    });
    const logsText = await logsResponse.text();
    assert.doesNotMatch(logsText, /relay-log-secret/);
    assert.match(logsText, /\[redacted\]/);

    const savedMapping = await fetch(`${service.baseURL}/api/dashboard/hue/mapping`, {
      method: 'PUT',
      headers: { Cookie: cookie, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        groupId: '192.168.50.30',
        target: { kind: 'room', id: 'room-1' },
      }),
    });
    assert.equal(savedMapping.status, 200);
    const kitchenMapping = dependencies.hue.mappingConfiguration()?.mappings
      .find(mapping => mapping.relayGroupID === '192.168.50.30');
    assert.deepEqual(kitchenMapping, {
      sonosID: '192.168.50.30',
      sonosName: 'Kitchen',
      relayGroupID: '192.168.50.30',
      preferredTarget: { kind: 'room', id: 'room-1' },
      fallbackTarget: null,
      includedLightIDs: [],
      excludedLightIDs: [],
      capability: 'gradientReady',
    });

    const changedMapping = await fetch(`${service.baseURL}/api/dashboard/hue/mapping`, {
      method: 'PUT',
      headers: { Cookie: cookie, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        groupId: '192.168.50.25',
        target: { kind: 'entertainmentArea', id: 'ent-1' },
      }),
    });
    assert.equal(changedMapping.status, 200);
    const livingMapping = dependencies.hue.mappingConfiguration()?.mappings
      .find(mapping => mapping.relayGroupID === '192.168.50.25');
    assert.equal(livingMapping?.sonosID, 'uuid-living');
    assert.equal(livingMapping?.capability, 'liveEntertainment');
    assert.deepEqual(livingMapping?.includedLightIDs, []);
    assert.deepEqual(livingMapping?.excludedLightIDs, []);

    const invalidMapping = await fetch(`${service.baseURL}/api/dashboard/hue/mapping`, {
      method: 'PUT',
      headers: { Cookie: cookie, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        groupId: '192.168.50.25',
        target: { kind: 'light', id: 'light-1' },
      }),
    });
    assert.equal(invalidMapping.status, 400);

    const rejectedOrigin = await fetch(`${service.baseURL}/api/dashboard/hue/stop`, {
      method: 'POST',
      headers: { Cookie: cookie, Origin: 'http://evil.test' },
    });
    assert.equal(rejectedOrigin.status, 403);
  } finally {
    await service.close();
  }
});

class FakeDashboardSonos {
  readonly discovery = { mode: 'auto' as const, status: 'ready' as const, error: null };
  readonly calls: Array<{ action: string; groupId: string; intoGroupId?: string }> = [];
  private readonly snapshots = [snapshot(), snapshot({
    groupId: '192.168.50.30',
    speakerName: 'Kitchen',
    groupMemberCount: 1,
  })];

  allSnapshots() { return this.snapshots; }
  current(groupId: string) { return this.snapshots.find(value => value.groupId === groupId); }
  async pullFreshSnapshot(groupId: string) { return this.current(groupId); }
  async play(groupId: string) { this.calls.push({ action: 'play', groupId }); }
  async pause(groupId: string) { this.calls.push({ action: 'pause', groupId }); }
  async next(groupId: string) { this.calls.push({ action: 'next', groupId }); }
  async previous(groupId: string) { this.calls.push({ action: 'previous', groupId }); }
  async setGroupVolume(groupId: string) { this.calls.push({ action: 'volume', groupId }); }
  async setMemberVolume(groupId: string) { this.calls.push({ action: 'member-volume', groupId }); }
  async setSoundbarNightMode(groupId: string) { this.calls.push({ action: 'night', groupId }); }
  async setSoundbarSpeechEnhancementRawLevel(groupId: string) { this.calls.push({ action: 'speech', groupId }); }
  async mergeGroups(groupId: string, intoGroupId: string) { this.calls.push({ action: 'group', groupId, intoGroupId }); }
  async separateGroup(groupId: string) { this.calls.push({ action: 'ungroup', groupId }); }
}

class FakeDashboardHue {
  private config: HueAmbienceMappingConfiguration = {
    resources: {
      lights: [{
        id: 'light-1',
        name: 'Floor lamp',
        supportsColor: true,
        supportsGradient: true,
        supportsEntertainment: true,
        function: 'decorative' as const,
        functionMetadataResolved: true,
      }],
      areas: [{
        id: 'room-1', name: 'Living Room', kind: 'room' as const, childLightIDs: ['light-1'],
      }, {
        id: 'ent-1', name: 'TV Area', kind: 'entertainmentArea' as const, childLightIDs: ['light-1'],
      }],
    },
    mappings: [{
      sonosID: 'uuid-living',
      sonosName: 'Living Room',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'room' as const, id: 'room-1' },
      fallbackTarget: null,
      includedLightIDs: ['light-1'],
      excludedLightIDs: ['light-1'],
      capability: 'gradientReady' as const,
    }],
  };

  status() {
    return {
      configured: true,
      enabled: true,
      runtimeActive: false,
      runtimePaused: false,
      mappings: this.config.mappings.length,
      lights: this.config.resources.lights.length,
      areas: this.config.resources.areas.length,
    };
  }

  async entertainmentStatus() {
    return { configured: true, bridgeReachable: true, streaming: 'free' as const, lastError: null };
  }

  mappingConfiguration() { return this.config; }

  async saveMappings(mappings: HueSonosMapping[]) {
    this.config = { ...this.config, mappings };
  }

  async start() { return undefined; }
  async stop() { return undefined; }
}

function fakeDependencies(
  sonos: FakeDashboardSonos,
  relayLogs: RelayLogBuffer,
): DashboardDependencies {
  const deviceLogs = new DeviceLogService();
  deviceLogs.receive({ entries: [{ level: 'info', category: 'Relay', message: 'device ready' }] });
  return {
    sonos,
    hue: new FakeDashboardHue(),
    apns: {
      status: () => ({
        mode: 'ready', environment: 'production', bundleId: 'com.charm.SonosWidget',
        keyIdConfigured: true, teamIdConfigured: true, keyFilePresent: true, missing: [],
      }),
    },
    updateTokens: {
      count: () => 1,
      summaries: () => [{ groupId: '192.168.50.25', clientId: 'client-1', activityId: 'activity-1' }],
    },
    startTokens: { count: () => 0, summaries: () => [] },
    dismissals: { count: () => 0, activeSummaries: () => [] },
    deviceLogs,
    relayLogs,
    mcp: { token: 'mcp-secret', maxVolume: 70, allowedOrigins: [] },
    version: 'test',
    artworkTheme: async () => '#E58A66',
  };
}

async function startDashboardServer(dependencies: DashboardDependencies) {
  const app = express();
  app.use(express.json());
  app.use('/api/dashboard', createDashboardRouter(dependencies, pino({ enabled: false }), {
    token: 'dashboard-secret',
    sessionTtlMs: 60_000,
    secureCookie: false,
  }));
  const server = app.listen(0);
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address === 'object');
  return {
    baseURL: `http://127.0.0.1:${address.port}`,
    close: () => new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())),
  };
}

function snapshot(overrides: Partial<SonosGroupSnapshot> = {}): SonosGroupSnapshot {
  return {
    groupId: '192.168.50.25', speakerName: 'Living Room', trackTitle: 'Song', artist: 'Artist', album: 'Album',
    albumArtUri: 'https://example.com/cover.jpg', isPlaying: true, groupVolume: 28, playbackSourceRaw: 'appleMusic', positionSeconds: 10,
    durationSeconds: 200, groupMemberCount: 2, sampledAt: new Date('2026-07-15T00:00:00Z'),
    ...overrides,
  };
}
