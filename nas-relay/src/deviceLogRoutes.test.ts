import assert from 'node:assert/strict';
import { test } from 'node:test';

import express from 'express';
import pino from 'pino';

import { DeviceLogService } from './deviceLogs.js';
import { createDeviceLogRouter } from './deviceLogRoutes.js';

test('device log router accepts batches and exposes recent entries', async () => {
  const app = express();
  const service = new DeviceLogService();
  app.use(express.json());
  app.use('/api', createDeviceLogRouter(service, pino({ enabled: false })));

  const server = app.listen(0);
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address === 'object');
  const baseURL = `http://127.0.0.1:${address.port}`;

  try {
    const postResponse = await fetch(`${baseURL}/api/device-logs`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clientId: 'client-1',
        bundleId: 'com.charm.SonosWidget',
        processName: 'TheWidgetExtension',
        entries: [
          {
            timestamp: '2026-06-25T01:02:03.000Z',
            category: 'Relay',
            level: 'info',
            message: 'registered activity',
            line: '[Relay] registered activity',
          },
          {
            timestamp: '2026-06-25T01:02:04.000Z',
            category: 'NowPlaying',
            level: 'error',
            message: 'art decode failed',
            line: '[NowPlaying] ERROR: art decode failed',
          },
        ],
      }),
    });

    assert.equal(postResponse.status, 200);
    assert.deepEqual(await postResponse.json(), { ok: true, accepted: 2 });

    const recentResponse = await fetch(`${baseURL}/api/device-logs/recent`);
    assert.equal(recentResponse.status, 200);
    const recent = await recentResponse.json() as {
      ok: boolean;
      entries: Array<{
        id: number;
        clientId?: string;
        bundleId?: string;
        processName?: string;
        timestamp?: string;
        category: string;
        level: string;
        message: string;
        line: string;
      }>;
    };

    assert.equal(recent.ok, true);
    assert.equal(recent.entries.length, 2);
    assert.equal(recent.entries[0]?.id, 1);
    assert.equal(recent.entries[0]?.clientId, 'client-1');
    assert.equal(recent.entries[0]?.bundleId, 'com.charm.SonosWidget');
    assert.equal(recent.entries[0]?.processName, 'TheWidgetExtension');
    assert.equal(recent.entries[0]?.category, 'Relay');
    assert.equal(recent.entries[0]?.level, 'info');
    assert.equal(recent.entries[1]?.category, 'NowPlaying');
    assert.equal(recent.entries[1]?.level, 'error');
    assert.equal(recent.entries[1]?.message, 'art decode failed');
  } finally {
    await closeServer(server);
  }
});

test('device log service keeps a bounded recent buffer', () => {
  const service = new DeviceLogService({ recentLimit: 2 });

  service.receive({
    clientId: 'client-1',
    entries: [
      { category: 'Relay', level: 'info', message: 'first', line: '[Relay] first' },
      { category: 'Relay', level: 'info', message: 'second', line: '[Relay] second' },
      { category: 'Relay', level: 'info', message: 'third', line: '[Relay] third' },
    ],
  });

  assert.deepEqual(service.recent().map(entry => entry.message), ['second', 'third']);
});

test('device log stream emits newly posted entries', async () => {
  const app = express();
  const service = new DeviceLogService();
  app.use(express.json());
  app.use('/api', createDeviceLogRouter(service, pino({ enabled: false })));

  const server = app.listen(0);
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address === 'object');
  const baseURL = `http://127.0.0.1:${address.port}`;
  const abortController = new AbortController();

  try {
    const streamResponse = await fetch(`${baseURL}/api/device-logs/stream`, {
      signal: abortController.signal,
    });
    assert.equal(streamResponse.status, 200);
    assert.equal(streamResponse.headers.get('content-type'), 'text/event-stream; charset=utf-8');
    assert(streamResponse.body);

    const reader = streamResponse.body.getReader();
    await fetch(`${baseURL}/api/device-logs`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clientId: 'client-1',
        entries: [
          {
            timestamp: '2026-06-25T01:02:05.000Z',
            category: 'NowPlaying',
            level: 'info',
            message: 'live_activity_artwork trace=art_123',
            line: '[NowPlaying] live_activity_artwork trace=art_123',
          },
        ],
      }),
    });

    const text = await readUntil(reader, 'event: device-log');
    assert.match(text, /event: device-log/);
    assert.match(text, /"clientId":"client-1"/);
    assert.match(text, /"category":"NowPlaying"/);
    assert.match(text, /"live_activity_artwork trace=art_123"/);
    await reader.cancel();
  } finally {
    abortController.abort();
    await closeServer(server);
  }
});

async function closeServer(server: ReturnType<typeof express.application.listen>): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
  });
}

async function readUntil(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  expectedText: string,
): Promise<string> {
  const decoder = new TextDecoder();
  let text = '';
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const { done, value } = await reader.read();
    if (done) break;
    text += decoder.decode(value, { stream: true });
    if (text.includes(expectedText)) return text;
  }
  return text;
}
