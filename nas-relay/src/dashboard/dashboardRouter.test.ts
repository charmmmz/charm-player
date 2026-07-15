import assert from 'node:assert/strict';
import express from 'express';
import { test } from 'node:test';
import pino from 'pino';

import { DeviceLogService } from '../diagnostics/deviceLogs.js';
import { RelayLogBuffer } from '../diagnostics/relayLogs.js';
import type { SonosMcpController } from '../mcp/sonosMcpRouter.js';
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

    const logsResponse = await fetch(`${service.baseURL}/api/dashboard/logs`, {
      headers: { Cookie: cookie },
    });
    const logsText = await logsResponse.text();
    assert.doesNotMatch(logsText, /relay-log-secret/);
    assert.match(logsText, /\[redacted\]/);

    const rejectedOrigin = await fetch(`${service.baseURL}/api/dashboard/hue/stop`, {
      method: 'POST',
      headers: { Cookie: cookie, Origin: 'http://evil.test' },
    });
    assert.equal(rejectedOrigin.status, 403);
  } finally {
    await service.close();
  }
});

class FakeDashboardSonos implements SonosMcpController {
  readonly discovery = { mode: 'auto' as const, status: 'ready' as const, error: null };
  readonly calls: Array<{ action: string; groupId: string }> = [];
  private readonly snapshots = [snapshot()];

  allSnapshots() { return this.snapshots; }
  current(groupId: string) { return this.snapshots.find(value => value.groupId === groupId); }
  async pullFreshSnapshot(groupId: string) { return this.current(groupId); }
  async play(groupId: string) { this.calls.push({ action: 'play', groupId }); }
  async pause(groupId: string) { this.calls.push({ action: 'pause', groupId }); }
  async next(groupId: string) { this.calls.push({ action: 'next', groupId }); }
  async previous(groupId: string) { this.calls.push({ action: 'previous', groupId }); }
  async setGroupVolume(groupId: string) { this.calls.push({ action: 'volume', groupId }); }
  async setSoundbarNightMode(groupId: string) { this.calls.push({ action: 'night', groupId }); }
  async setSoundbarSpeechEnhancementRawLevel(groupId: string) { this.calls.push({ action: 'speech', groupId }); }
}

function fakeDependencies(
  sonos: FakeDashboardSonos,
  relayLogs: RelayLogBuffer,
): DashboardDependencies {
  const deviceLogs = new DeviceLogService();
  deviceLogs.receive({ entries: [{ level: 'info', category: 'Relay', message: 'device ready' }] });
  return {
    sonos,
    hue: {
      status: () => ({ configured: true, enabled: true, runtimeActive: false }),
      entertainmentStatus: async () => ({ configured: true, bridgeReachable: true, streaming: 'free', lastError: null }),
      stop: async () => undefined,
    },
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

function snapshot(): SonosGroupSnapshot {
  return {
    groupId: '192.168.50.25', speakerName: 'Living Room', trackTitle: 'Song', artist: 'Artist', album: 'Album',
    albumArtUri: null, isPlaying: true, groupVolume: 28, playbackSourceRaw: 'appleMusic', positionSeconds: 10,
    durationSeconds: 200, groupMemberCount: 2, sampledAt: new Date('2026-07-15T00:00:00Z'),
  };
}
