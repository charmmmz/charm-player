import assert from 'node:assert/strict';
import express from 'express';
import { test } from 'node:test';
import pino from 'pino';

import { AlbumArtFetchCache } from './albumArtFetchCache.js';
import { createArtworkRouter } from './artworkRoutes.js';

test('artwork route proxies image bytes through the shared fetch cache', async () => {
  const app = express();
  const cache = new AlbumArtFetchCache();
  let fetchCalls = 0;
  app.use('/api', createArtworkRouter(pino({ enabled: false }), {
    cache,
    fetcher: async uri => {
      fetchCalls += 1;
      assert.equal(uri, 'https://example.com/cover.png');
      return pngBytes();
    },
  }));

  const server = app.listen(0);
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address === 'object');
  const baseURL = `http://127.0.0.1:${address.port}`;

  try {
    const encoded = encodeURIComponent(' https://example.com/cover.png ');
    const first = await fetch(`${baseURL}/api/artwork?url=${encoded}`);
    const second = await fetch(`${baseURL}/api/artwork?url=${encoded}`);

    assert.equal(first.status, 200);
    assert.equal(first.headers.get('content-type'), 'image/png');
    assert.equal(first.headers.get('cache-control'), 'public, max-age=86400');
    assert.deepEqual(Buffer.from(await first.arrayBuffer()), pngBytes());

    assert.equal(second.status, 200);
    assert.deepEqual(Buffer.from(await second.arrayBuffer()), pngBytes());
    assert.equal(fetchCalls, 1);
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
    });
  }
});

test('artwork route rejects unsupported artwork URL schemes', async () => {
  const app = express();
  app.use('/api', createArtworkRouter(pino({ enabled: false })));

  const server = app.listen(0);
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address === 'object');

  try {
    const response = await fetch(
      `http://127.0.0.1:${address.port}/api/artwork?url=${encodeURIComponent('file:///etc/passwd')}`,
    );

    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), {
      ok: false,
      error: 'artwork url must use http or https',
    });
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
    });
  }
});

function pngBytes(): Buffer {
  return Buffer.from([
    0x89, 0x50, 0x4e, 0x47,
    0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x00,
  ]);
}
