import assert from 'node:assert/strict';
import express from 'express';
import { test } from 'node:test';
import pino from 'pino';

import { ArtworkHintStore, createArtworkHintsRouter } from './artworkHints.js';

test('artwork hint store resolves CDN artwork for speaker-local getaa artwork', () => {
  const store = new ArtworkHintStore();
  store.remember([
    {
      id: 'song:123',
      title: 'Moon',
      artist: 'Daniel Caesar',
      album: 'Freudian',
      artworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg',
    },
  ]);

  assert.equal(
    store.resolve({
      title: ' moon ',
      artist: 'DANIEL CAESAR',
      album: 'Freudian',
      currentArtworkUrl: 'http://192.168.50.25:1400/getaa?s=1&u=x-sonos-http%3atrack',
    }),
    'https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg',
  );
});

test('artwork hint store keeps existing public artwork', () => {
  const store = new ArtworkHintStore();
  store.remember([
    {
      title: 'Moon',
      artist: 'Daniel Caesar',
      album: 'Freudian',
      artworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/Music/freudian.jpg/600x600bb.jpg',
    },
  ]);

  assert.equal(
    store.resolve({
      title: 'Moon',
      artist: 'Daniel Caesar',
      album: 'Freudian',
      currentArtworkUrl: 'https://cdn.example.com/current.jpg',
    }),
    null,
  );
});

test('artwork hint store treats conflicting metadata keys as ambiguous', () => {
  const store = new ArtworkHintStore();
  store.remember([
    {
      title: 'Intro',
      artist: 'Artist',
      album: 'Album',
      artworkUrl: 'https://cdn.example.com/a.jpg',
    },
    {
      title: 'Intro',
      artist: 'Artist',
      album: 'Album',
      artworkUrl: 'https://cdn.example.com/b.jpg',
    },
  ]);

  assert.equal(
    store.resolve({
      title: 'Intro',
      artist: 'Artist',
      album: 'Album',
      currentArtworkUrl: 'http://192.168.50.25:1400/getaa?s=1',
    }),
    null,
  );
});

test('artwork hints route stores valid hints', async () => {
  const app = express();
  const store = new ArtworkHintStore();
  app.use(express.json());
  app.use('/api', createArtworkHintsRouter(store, pino({ enabled: false })));

  const server = app.listen(0);
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address === 'object');

  try {
    const response = await fetch(`http://127.0.0.1:${address.port}/api/artwork-hints`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        hints: [
          {
            title: 'Blue Train',
            artist: 'John Coltrane',
            album: 'Blue Train',
            artworkUrl: 'https://cdn.example.com/blue-train.jpg',
          },
        ],
      }),
    });

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true, accepted: 1, rejected: 0 });
    assert.equal(
      store.resolve({
        title: 'Blue Train',
        artist: 'John Coltrane',
        album: 'Blue Train',
        currentArtworkUrl: 'http://192.168.50.25:1400/getaa?s=1',
      }),
      'https://cdn.example.com/blue-train.jpg',
    );
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
    });
  }
});
