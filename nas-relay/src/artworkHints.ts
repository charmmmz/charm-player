import { Router } from 'express';
import type { Logger } from 'pino';

export interface ArtworkHintInput {
  id?: string | null;
  uri?: string | null;
  title?: string | null;
  artist?: string | null;
  album?: string | null;
  cloudType?: string | null;
  artworkUrl?: string | null;
  artworkURL?: string | null;
}

export interface ArtworkHintLookup {
  title?: string | null;
  artist?: string | null;
  album?: string | null;
  objectIds?: Array<string | null | undefined>;
  currentArtworkUrl?: string | null;
}

interface ArtworkHintEntry {
  url: string | null;
  cacheKey: string;
  ambiguous: boolean;
}

type ArtworkHintKey = string;

export class ArtworkHintStore {
  private readonly entries = new Map<ArtworkHintKey, ArtworkHintEntry>();

  remember(hints: ArtworkHintInput[]): { accepted: number; rejected: number } {
    let accepted = 0;
    let rejected = 0;

    for (const hint of hints) {
      const url = normalizedArtworkUrl(hint.artworkUrl ?? hint.artworkURL);
      const keys = lookupKeysForHint(hint);
      if (!url || keys.length === 0) {
        rejected += 1;
        continue;
      }

      for (const key of keys) {
        this.rememberKey(key, url);
      }
      accepted += 1;
    }

    return { accepted, rejected };
  }

  resolve(input: ArtworkHintLookup): string | null {
    if (!shouldReplaceArtworkUrl(input.currentArtworkUrl)) return null;

    for (const key of lookupKeysForLookup(input)) {
      const entry = this.entries.get(key);
      if (!entry || entry.ambiguous || !entry.url) continue;
      return entry.url;
    }
    return null;
  }

  private rememberKey(key: ArtworkHintKey, url: string): void {
    const cacheKey = artworkCacheKey(url);
    const existing = this.entries.get(key);
    if (!existing) {
      this.entries.set(key, { url, cacheKey, ambiguous: false });
      return;
    }

    if (existing.cacheKey === cacheKey) return;
    this.entries.set(key, { url: null, cacheKey: existing.cacheKey, ambiguous: true });
  }
}

export function createArtworkHintsRouter(store: ArtworkHintStore, log: Logger): Router {
  const router = Router();

  router.post('/artwork-hints', (req, res) => {
    const hints = artworkHintsFromBody(req.body);
    if (!hints) {
      res.status(400).json({ ok: false, error: 'hints array required' });
      return;
    }

    const result = store.remember(hints.slice(0, 500));
    log.info({ accepted: result.accepted, rejected: result.rejected }, 'artwork hints stored');
    res.json({ ok: true, ...result });
  });

  return router;
}

export function isLocalSonosArtworkUrl(value: string | null | undefined): boolean {
  const trimmed = value?.trim() ?? '';
  if (!trimmed) return false;
  if (trimmed.startsWith('/getaa')) return true;

  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return false;
  }

  return url.protocol === 'http:'
    && url.port === '1400'
    && url.pathname.toLowerCase().includes('getaa');
}

function shouldReplaceArtworkUrl(value: string | null | undefined): boolean {
  const trimmed = value?.trim() ?? '';
  if (!trimmed) return true;
  return isLocalSonosArtworkUrl(trimmed);
}

function artworkHintsFromBody(body: unknown): ArtworkHintInput[] | null {
  if (!body || typeof body !== 'object') return null;
  const hints = (body as { hints?: unknown }).hints;
  if (!Array.isArray(hints)) return null;
  return hints.filter((hint): hint is ArtworkHintInput => Boolean(hint) && typeof hint === 'object');
}

function lookupKeysForHint(hint: ArtworkHintInput): ArtworkHintKey[] {
  const keys: ArtworkHintKey[] = [];
  const seen = new Set<ArtworkHintKey>();

  const append = (key: ArtworkHintKey | null) => {
    if (!key || seen.has(key)) return;
    seen.add(key);
    keys.push(key);
  };

  for (const objectId of objectIdsFromValues(hint.id, hint.uri)) {
    append(`object:${objectId}`);
  }
  append(trackKey(hint.title, hint.artist, hint.album));
  append(albumKey(hint.artist, hint.album));
  return keys;
}

function lookupKeysForLookup(input: ArtworkHintLookup): ArtworkHintKey[] {
  const keys: ArtworkHintKey[] = [];
  const seen = new Set<ArtworkHintKey>();

  const append = (key: ArtworkHintKey | null) => {
    if (!key || seen.has(key)) return;
    seen.add(key);
    keys.push(key);
  };

  for (const objectId of objectIdsFromValues(...(input.objectIds ?? []), input.currentArtworkUrl)) {
    append(`object:${objectId}`);
  }
  append(trackKey(input.title, input.artist, input.album));
  append(albumKey(input.artist, input.album));
  return keys;
}

function trackKey(
  title: string | null | undefined,
  artist: string | null | undefined,
  album: string | null | undefined,
): ArtworkHintKey | null {
  const normalizedTitle = normalizedText(title);
  const normalizedArtist = normalizedText(artist);
  const normalizedAlbum = normalizedText(album);
  if (!normalizedTitle || !normalizedArtist || !normalizedAlbum) return null;
  return `track:${normalizedTitle}|${normalizedArtist}|${normalizedAlbum}`;
}

function albumKey(
  artist: string | null | undefined,
  album: string | null | undefined,
): ArtworkHintKey | null {
  const normalizedArtist = normalizedText(artist);
  const normalizedAlbum = normalizedText(album);
  if (!normalizedArtist || !normalizedAlbum) return null;
  return `album:${normalizedArtist}|${normalizedAlbum}`;
}

function normalizedText(value: string | null | undefined): string | null {
  const normalized = (value ?? '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');
  return normalized.length > 0 ? normalized : null;
}

function normalizedArtworkUrl(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? '';
  if (!trimmed || isLocalSonosArtworkUrl(trimmed)) return null;

  try {
    const url = new URL(trimmed);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
    return url.toString();
  } catch {
    return null;
  }
}

function artworkCacheKey(value: string): string {
  try {
    const url = new URL(value);
    url.protocol = url.protocol.toLowerCase();
    url.hostname = url.hostname.toLowerCase();
    url.hash = '';
    return url.toString();
  } catch {
    return value;
  }
}

function objectIdsFromValues(...values: Array<string | null | undefined>): string[] {
  const ids: string[] = [];
  const seen = new Set<string>();

  const append = (value: string | null) => {
    if (!value || seen.has(value)) return;
    seen.add(value);
    ids.push(value);
  };

  for (const value of values) {
    for (const objectId of objectIdsFromValue(value)) {
      append(objectId);
    }
  }
  return ids;
}

function objectIdsFromValue(value: string | null | undefined): string[] {
  const trimmed = value?.trim() ?? '';
  if (!trimmed) return [];

  const ids: string[] = [];
  const append = (candidate: string | null) => {
    const normalized = normalizedObjectId(candidate);
    if (normalized) ids.push(normalized);
  };

  append(trimmed);

  try {
    const url = new URL(trimmed);
    append(url.searchParams.get('u'));
  } catch {
    // Not a URL; plain Sonos object IDs and URIs are handled above.
  }

  return ids;
}

function normalizedObjectId(value: string | null | undefined): string | null {
  let candidate = value?.trim() ?? '';
  if (!candidate) return null;

  for (let index = 0; index < 2; index += 1) {
    try {
      const decoded = decodeURIComponent(candidate);
      if (decoded === candidate) break;
      candidate = decoded;
    } catch {
      break;
    }
  }

  candidate = candidate.trim();
  if (!candidate) return null;
  const hashIndex = candidate.indexOf('#');
  if (hashIndex >= 0) candidate = candidate.slice(0, hashIndex);
  const queryIndex = candidate.indexOf('?');
  if (queryIndex >= 0) candidate = candidate.slice(0, queryIndex);
  return candidate.trim().toLowerCase() || null;
}
