import assert from 'node:assert/strict';
import { test } from 'node:test';

import { AlbumArtFetchCache } from './albumArtFetchCache.js';

test('album art fetch cache coalesces concurrent requests for the same URI', async () => {
  const cache = new AlbumArtFetchCache();
  const pending = deferred<Buffer>();
  let fetchCalls = 0;

  const first = cache.fetch('http://192.168.50.25:1400/getaa?s=1', async () => {
    fetchCalls += 1;
    return pending.promise;
  });
  const second = cache.fetch('http://192.168.50.25:1400/getaa?s=1', async () => {
    fetchCalls += 1;
    return Buffer.from('unexpected-second-fetch');
  });

  assert.equal(fetchCalls, 1);
  pending.resolve(Buffer.from('cover-bytes'));

  assert.deepEqual(await first, Buffer.from('cover-bytes'));
  assert.deepEqual(await second, Buffer.from('cover-bytes'));
  assert.equal(fetchCalls, 1);
});

test('album art fetch cache reuses completed requests by normalized URI', async () => {
  const cache = new AlbumArtFetchCache();
  let fetchCalls = 0;

  const first = await cache.fetch(' http://example.test/art.jpg ', async () => {
    fetchCalls += 1;
    return Buffer.from('cached-cover');
  });
  const second = await cache.fetch('http://example.test/art.jpg', async () => {
    fetchCalls += 1;
    return Buffer.from('unexpected-second-fetch');
  });

  assert.deepEqual(first, Buffer.from('cached-cover'));
  assert.deepEqual(second, Buffer.from('cached-cover'));
  assert.equal(fetchCalls, 1);
});

test('album art fetch cache shares equivalent URL cache keys', async () => {
  const cache = new AlbumArtFetchCache();
  let fetchCalls = 0;

  const first = await cache.fetch(' HTTPS://Example.COM/cover.jpg#first ', async uri => {
    fetchCalls += 1;
    assert.equal(uri, 'https://example.com/cover.jpg');
    return Buffer.from('normalized-cover');
  });
  const second = await cache.fetch('https://example.com/cover.jpg#second', async () => {
    fetchCalls += 1;
    return Buffer.from('unexpected-second-fetch');
  });

  assert.deepEqual(first, Buffer.from('normalized-cover'));
  assert.deepEqual(second, Buffer.from('normalized-cover'));
  assert.equal(fetchCalls, 1);
});

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(innerResolve => {
    resolve = innerResolve;
  });
  return { promise, resolve };
}
