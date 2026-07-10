import assert from 'node:assert/strict';
import express from 'express';
import { test } from 'node:test';
import pino from 'pino';

import {
  type AnimatedArtworkResolution,
  type AnimatedAppleMusicArtworkResolver,
} from './animatedAppleMusicArtwork.js';
import { createAnimatedArtworkRouter } from './animatedArtworkRoutes.js';

test('animated artwork URL route returns resolver success envelope', async () => {
  const app = express();
  const resolver = {
    resolveByURL: async (url: string, country?: string | null) => ({
      ok: true,
      status: 'hit',
      artist: 'Daniel Caesar',
      album: 'Freudian',
      appleMusicUrl: url,
      squareUrl: 'https://cdn.example.com/square.m3u8',
      squareWidth: null,
      squareHeight: null,
      squareAspectRatio: null,
      tallUrl: null,
      tallWidth: null,
      tallHeight: null,
      tallAspectRatio: null,
      source: country === 'GB' ? 'url' : 'none',
    }),
    resolveByMetadata: async () => disabledResolution(),
  } satisfies Pick<AnimatedAppleMusicArtworkResolver, 'resolveByURL' | 'resolveByMetadata'>;

  app.use('/api', createAnimatedArtworkRouter(pino({ enabled: false }), resolver));
  const server = await listen(app);
  try {
    const response = await fetch(
      `${server.baseURL}/api/animated-artwork/url?url=${encodeURIComponent('https://music.apple.com/gb/album/freudian/1547315522')}&country=gb`,
    );

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      ok: true,
      status: 'hit',
      artist: 'Daniel Caesar',
      album: 'Freudian',
      appleMusicUrl: 'https://music.apple.com/gb/album/freudian/1547315522',
      squareUrl: 'https://cdn.example.com/square.m3u8',
      squareWidth: null,
      squareHeight: null,
      squareAspectRatio: null,
      tallUrl: null,
      tallWidth: null,
      tallHeight: null,
      tallAspectRatio: null,
      source: 'url',
    });
  } finally {
    await server.close();
  }
});

test('animated artwork routes validate required inputs', async () => {
  const app = express();
  const resolver = {
    resolveByURL: async () => disabledResolution(),
    resolveByMetadata: async () => disabledResolution(),
  } satisfies Pick<AnimatedAppleMusicArtworkResolver, 'resolveByURL' | 'resolveByMetadata'>;

  app.use('/api', createAnimatedArtworkRouter(pino({ enabled: false }), resolver));
  const server = await listen(app);
  try {
    const missingUrl = await fetch(`${server.baseURL}/api/animated-artwork/url`);
    assert.equal(missingUrl.status, 400);
    assert.deepEqual(await missingUrl.json(), { ok: false, error: 'url query parameter required' });

    const missingAlbum = await fetch(`${server.baseURL}/api/animated-artwork/search?artist=Daniel%20Caesar`);
    assert.equal(missingAlbum.status, 400);
    assert.deepEqual(await missingAlbum.json(), { ok: false, error: 'artist and album query parameters required' });
  } finally {
    await server.close();
  }
});

test('animated artwork search route returns resolver success envelope', async () => {
  const app = express();
  const resolver = {
    resolveByURL: async () => disabledResolution(),
    resolveByMetadata: async (artist: string, album: string, country?: string | null) => ({
      ok: true,
      status: 'hit',
      artist,
      album,
      appleMusicUrl: `country:${country}`,
      squareUrl: 'https://cdn.example.com/search-square.m3u8',
      squareWidth: null,
      squareHeight: null,
      squareAspectRatio: null,
      tallUrl: 'https://cdn.example.com/search-tall.m3u8',
      tallWidth: 1080,
      tallHeight: 1440,
      tallAspectRatio: 0.75,
      source: 'metadata-search',
    }),
  } satisfies Pick<AnimatedAppleMusicArtworkResolver, 'resolveByURL' | 'resolveByMetadata'>;

  app.use('/api', createAnimatedArtworkRouter(pino({ enabled: false }), resolver));
  const server = await listen(app);
  try {
    const response = await fetch(
      `${server.baseURL}/api/animated-artwork/search?artist=Daniel%20Caesar&album=Freudian&country=gb`,
    );

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      ok: true,
      status: 'hit',
      artist: 'Daniel Caesar',
      album: 'Freudian',
      appleMusicUrl: 'country:GB',
      squareUrl: 'https://cdn.example.com/search-square.m3u8',
      squareWidth: null,
      squareHeight: null,
      squareAspectRatio: null,
      tallUrl: 'https://cdn.example.com/search-tall.m3u8',
      tallWidth: 1080,
      tallHeight: 1440,
      tallAspectRatio: 0.75,
      source: 'metadata-search',
    });
  } finally {
    await server.close();
  }
});

test('animated artwork route converts resolver exceptions to error envelopes', async () => {
  const app = express();
  const resolver = {
    resolveByURL: async () => {
      throw new Error('upstream exploded');
    },
    resolveByMetadata: async () => disabledResolution(),
  } satisfies Pick<AnimatedAppleMusicArtworkResolver, 'resolveByURL' | 'resolveByMetadata'>;

  app.use('/api', createAnimatedArtworkRouter(pino({ enabled: false }), resolver));
  const server = await listen(app);
  try {
    const response = await fetch(
      `${server.baseURL}/api/animated-artwork/url?url=${encodeURIComponent('https://music.apple.com/us/album/freudian/1547315522')}`,
    );

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      ok: true,
      status: 'error',
      artist: null,
      album: null,
      appleMusicUrl: null,
      squareUrl: null,
      squareWidth: null,
      squareHeight: null,
      squareAspectRatio: null,
      tallUrl: null,
      tallWidth: null,
      tallHeight: null,
      tallAspectRatio: null,
      source: 'none',
    });
  } finally {
    await server.close();
  }
});

test('animated artwork search route converts resolver exceptions to error envelopes', async () => {
  const app = express();
  const resolver = {
    resolveByURL: async () => disabledResolution(),
    resolveByMetadata: async () => {
      throw new Error('search exploded');
    },
  } satisfies Pick<AnimatedAppleMusicArtworkResolver, 'resolveByURL' | 'resolveByMetadata'>;

  app.use('/api', createAnimatedArtworkRouter(pino({ enabled: false }), resolver));
  const server = await listen(app);
  try {
    const response = await fetch(
      `${server.baseURL}/api/animated-artwork/search?artist=Daniel%20Caesar&album=Freudian`,
    );

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      ok: true,
      status: 'error',
      artist: null,
      album: null,
      appleMusicUrl: null,
      squareUrl: null,
      squareWidth: null,
      squareHeight: null,
      squareAspectRatio: null,
      tallUrl: null,
      tallWidth: null,
      tallHeight: null,
      tallAspectRatio: null,
      source: 'none',
    });
  } finally {
    await server.close();
  }
});

function disabledResolution(): AnimatedArtworkResolution {
  return {
    ok: true,
    status: 'disabled',
    artist: null,
    album: null,
    appleMusicUrl: null,
    squareUrl: null,
    squareWidth: null,
    squareHeight: null,
    squareAspectRatio: null,
    tallUrl: null,
    tallWidth: null,
    tallHeight: null,
    tallAspectRatio: null,
    source: 'none',
  };
}

async function listen(app: express.Express): Promise<{ baseURL: string; close: () => Promise<void> }> {
  const server = app.listen(0);
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address === 'object');
  return {
    baseURL: `http://127.0.0.1:${address.port}`,
    close: async () => {
      await new Promise<void>((resolve, reject) => {
        server.close(error => error ? reject(error) : resolve());
      });
    },
  };
}
