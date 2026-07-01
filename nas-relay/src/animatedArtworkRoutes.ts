import { Router } from 'express';
import type { Logger } from 'pino';

import {
  type AnimatedAppleMusicArtworkResolver,
  type AnimatedArtworkResolution,
} from './animatedAppleMusicArtwork.js';

type Resolver = Pick<AnimatedAppleMusicArtworkResolver, 'resolveByURL' | 'resolveByMetadata'>;

export function createAnimatedArtworkRouter(log: Logger, resolver: Resolver): Router {
  const router = Router();

  router.get('/animated-artwork/url', async (req, res) => {
    const url = stringQuery(req.query.url);
    if (!url) {
      res.status(400).json({ ok: false, error: 'url query parameter required' });
      return;
    }

    try {
      res.json(await resolver.resolveByURL(url, countryQuery(req.query.country)));
    } catch (err) {
      log.warn({ err, url }, 'animated artwork URL resolution failed');
      res.json(errorResolution());
    }
  });

  router.get('/animated-artwork/search', async (req, res) => {
    const artist = stringQuery(req.query.artist);
    const album = stringQuery(req.query.album);
    if (!artist || !album) {
      res.status(400).json({ ok: false, error: 'artist and album query parameters required' });
      return;
    }

    try {
      res.json(await resolver.resolveByMetadata(artist, album, countryQuery(req.query.country)));
    } catch (err) {
      log.warn({ err, artist, album }, 'animated artwork metadata resolution failed');
      res.json(errorResolution());
    }
  });

  return router;
}

function stringQuery(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function countryQuery(value: unknown): string | null {
  const country = stringQuery(value);
  return country ? country.toUpperCase() : null;
}

function errorResolution(): AnimatedArtworkResolution {
  return {
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
  };
}
