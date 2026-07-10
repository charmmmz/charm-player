import { Router } from 'express';
import type { Logger } from 'pino';

import {
  AlbumArtFetchCache,
  type AlbumArtFetcher,
  sharedAlbumArtFetchCache,
} from './albumArtFetchCache.js';

type ArtworkRouterOptions = {
  cache?: AlbumArtFetchCache;
  fetcher?: AlbumArtFetcher;
};

export function createArtworkRouter(log: Logger, options: ArtworkRouterOptions = {}): Router {
  const router = Router();
  const cache = options.cache ?? sharedAlbumArtFetchCache;

  router.get('/artwork', async (req, res) => {
    const normalized = normalizedArtworkURL(req.query.url);
    if ('error' in normalized) {
      res.status(400).json({ ok: false, error: normalized.error });
      return;
    }

    try {
      const data = await cache.fetch(normalized.url, options.fetcher);
      res.status(200);
      res.setHeader('Content-Type', albumArtContentType(data));
      res.setHeader('Cache-Control', 'public, max-age=86400');
      res.send(data);
    } catch (err) {
      log.warn({ err, url: normalized.url }, 'album art proxy fetch failed');
      res.status(502).json({ ok: false, error: 'album_art_fetch_failed' });
    }
  });

  return router;
}

export function albumArtContentType(data: Buffer): string {
  if (data.length >= 3
    && data[0] === 0xff
    && data[1] === 0xd8
    && data[2] === 0xff) {
    return 'image/jpeg';
  }
  if (data.length >= 8
    && data[0] === 0x89
    && data[1] === 0x50
    && data[2] === 0x4e
    && data[3] === 0x47
    && data[4] === 0x0d
    && data[5] === 0x0a
    && data[6] === 0x1a
    && data[7] === 0x0a) {
    return 'image/png';
  }
  if (data.length >= 12
    && data.subarray(0, 4).toString('ascii') === 'RIFF'
    && data.subarray(8, 12).toString('ascii') === 'WEBP') {
    return 'image/webp';
  }
  if (data.length >= 6) {
    const signature = data.subarray(0, 6).toString('ascii');
    if (signature === 'GIF87a' || signature === 'GIF89a') {
      return 'image/gif';
    }
  }
  return 'application/octet-stream';
}

function normalizedArtworkURL(value: unknown): { url: string; error?: never } | { url?: never; error: string } {
  if (typeof value !== 'string' || value.trim() === '') {
    return { error: 'url query parameter required' };
  }

  let parsed: URL;
  try {
    parsed = new URL(value.trim());
  } catch {
    return { error: 'url query parameter must be a valid URL' };
  }

  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return { error: 'artwork url must use http or https' };
  }

  return { url: parsed.toString() };
}
