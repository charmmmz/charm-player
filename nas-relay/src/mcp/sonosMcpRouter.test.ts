import assert from 'node:assert/strict';
import express from 'express';
import { test } from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import pino from 'pino';

import type { SonosGroupSnapshot } from '../types.js';
import {
  createSonosMcpRouter,
  resolveMcpTarget,
  sonosMcpOptionsFromEnv,
  type SonosMcpController,
} from './sonosMcpRouter.js';

test('MCP target resolution accepts group id, exact room name, and unique partial room name', () => {
  const snapshots = [snapshot(), snapshot({ groupId: '192.168.50.30', speakerName: 'Kitchen' })];

  assert.equal(resolveMcpTarget('192.168.50.25', snapshots).speakerName, 'Living Room');
  assert.equal(resolveMcpTarget('living room', snapshots).groupId, '192.168.50.25');
  assert.equal(resolveMcpTarget('Kit', snapshots).groupId, '192.168.50.30');
  assert.throws(() => resolveMcpTarget('bedroom', snapshots), /Available rooms: Kitchen, Living Room/);
});

test('MCP target resolution rejects ambiguous partial room names', () => {
  const snapshots = [
    snapshot({ speakerName: 'Living Room' }),
    snapshot({ groupId: '192.168.50.30', speakerName: 'Living Room TV' }),
  ];

  assert.throws(() => resolveMcpTarget('living', snapshots), /Ambiguous Sonos target/);
});

test('MCP environment options fail closed and clamp the volume ceiling', () => {
  assert.deepEqual(
    sonosMcpOptionsFromEnv({ MCP_MAX_VOLUME: '250', MCP_ALLOWED_ORIGINS: 'http://a.test, http://b.test' }),
    {
      token: '',
      maxVolume: 100,
      allowedOrigins: ['http://a.test', 'http://b.test'],
    },
  );
  assert.equal(sonosMcpOptionsFromEnv({ MCP_MAX_VOLUME: 'invalid' }).maxVolume, 70);
});

test('LAN MCP endpoint requires its bearer token and rejects unknown browser origins', async () => {
  const service = await startMcpServer(new FakeSonosController(), {
    token: 'test-secret',
    maxVolume: 70,
    allowedOrigins: ['http://allowed.test'],
  });

  try {
    const missingToken = await fetch(`${service.baseURL}/mcp`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(initializeRequest()),
    });
    assert.equal(missingToken.status, 401);

    const unknownOrigin = await fetch(`${service.baseURL}/mcp`, {
      method: 'POST',
      headers: {
        Authorization: 'Bearer test-secret',
        'Content-Type': 'application/json',
        Origin: 'http://evil.test',
      },
      body: JSON.stringify(initializeRequest()),
    });
    assert.equal(unknownOrigin.status, 403);

    const preflight = await fetch(`${service.baseURL}/mcp`, {
      method: 'OPTIONS',
      headers: { Origin: 'http://allowed.test' },
    });
    assert.equal(preflight.status, 204);
    assert.equal(preflight.headers.get('access-control-allow-origin'), 'http://allowed.test');
  } finally {
    await service.close();
  }
});

test('LAN MCP endpoint exposes Sonos tools and reuses the relay controller', async () => {
  const controller = new FakeSonosController();
  const service = await startMcpServer(controller, {
    token: 'test-secret',
    maxVolume: 70,
    allowedOrigins: [],
  });
  const transport = new StreamableHTTPClientTransport(new URL(`${service.baseURL}/mcp`), {
    requestInit: { headers: { Authorization: 'Bearer test-secret' } },
  });
  const client = new Client({ name: 'sonos-mcp-test', version: '1.0.0' });

  try {
    await client.connect(transport);
    const tools = await client.listTools();
    assert.deepEqual(
      tools.tools.map(tool => tool.name),
      [
        'sonos_list_groups',
        'sonos_get_state',
        'sonos_play',
        'sonos_pause',
        'sonos_next',
        'sonos_previous',
        'sonos_set_volume',
        'sonos_set_night_mode',
        'sonos_set_speech_enhancement',
      ],
    );

    const groups = await client.readResource({ uri: 'sonos://groups' });
    assert.equal(groups.contents[0]?.mimeType, 'application/json');
    assert.match(String(groups.contents[0]?.text), /Living Room/);

    const result = await client.callTool({
      name: 'sonos_set_volume',
      arguments: { target: 'Living', volume: 42 },
    });
    assert.equal(result.isError, undefined);
    assert.deepEqual(controller.calls, [
      { action: 'setGroupVolume', groupId: '192.168.50.25', value: 42 },
    ]);

    const capped = await client.callTool({
      name: 'sonos_set_volume',
      arguments: { target: 'Living Room', volume: 71 },
    });
    assert.equal(capped.isError, true);
    assert.equal(controller.calls.length, 1);
  } finally {
    await client.close();
    await service.close();
  }
});

class FakeSonosController implements SonosMcpController {
  readonly calls: Array<{ action: string; groupId: string; value?: number | boolean }> = [];
  private readonly snapshots = [snapshot()];

  allSnapshots(): SonosGroupSnapshot[] {
    return this.snapshots;
  }

  current(groupId: string): SonosGroupSnapshot | undefined {
    return this.snapshots.find(value => value.groupId === groupId);
  }

  async pullFreshSnapshot(groupId: string): Promise<SonosGroupSnapshot | undefined> {
    this.calls.push({ action: 'pullFreshSnapshot', groupId });
    return this.current(groupId);
  }

  async play(groupId: string): Promise<void> {
    this.calls.push({ action: 'play', groupId });
  }

  async pause(groupId: string): Promise<void> {
    this.calls.push({ action: 'pause', groupId });
  }

  async next(groupId: string): Promise<void> {
    this.calls.push({ action: 'next', groupId });
  }

  async previous(groupId: string): Promise<void> {
    this.calls.push({ action: 'previous', groupId });
  }

  async setGroupVolume(groupId: string, volume: number): Promise<void> {
    this.calls.push({ action: 'setGroupVolume', groupId, value: volume });
  }

  async setSoundbarNightMode(groupId: string, enabled: boolean): Promise<void> {
    this.calls.push({ action: 'setSoundbarNightMode', groupId, value: enabled });
  }

  async setSoundbarSpeechEnhancementRawLevel(groupId: string, rawLevel: number): Promise<void> {
    this.calls.push({ action: 'setSoundbarSpeechEnhancementRawLevel', groupId, value: rawLevel });
  }
}

async function startMcpServer(
  controller: SonosMcpController,
  options: { token: string; allowedOrigins: string[]; maxVolume: number },
) {
  const app = express();
  app.use(express.json());
  app.use('/mcp', createSonosMcpRouter(controller, pino({ enabled: false }), options));
  const server = app.listen(0);
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address === 'object');
  return {
    baseURL: `http://127.0.0.1:${address.port}`,
    close: () => new Promise<void>((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
    }),
  };
}

function initializeRequest() {
  return {
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'manual-test', version: '1.0.0' },
    },
  };
}

function snapshot(overrides: Partial<SonosGroupSnapshot> = {}): SonosGroupSnapshot {
  return {
    groupId: '192.168.50.25',
    speakerName: 'Living Room',
    trackTitle: 'Song A',
    artist: 'Artist A',
    album: 'Album A',
    albumArtUri: 'http://192.168.50.25:1400/getaa?u=x',
    isPlaying: true,
    playbackSourceRaw: 'appleMusic',
    audioQualityLabel: 'Lossless',
    positionSeconds: 42,
    durationSeconds: 240,
    groupMemberCount: 2,
    sampledAt: new Date('2026-06-18T00:00:00Z'),
    ...overrides,
  };
}
