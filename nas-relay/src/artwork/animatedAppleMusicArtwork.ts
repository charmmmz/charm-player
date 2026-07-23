import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

export type AnimatedArtworkStatus =
  | 'hit'
  | 'miss'
  | 'negative-cache'
  | 'rate-limited'
  | 'disabled'
  | 'error';

export type AnimatedArtworkSource = 'url' | 'metadata-search' | 'cache' | 'none';

export interface AnimatedArtworkResolution {
  ok: true;
  status: AnimatedArtworkStatus;
  artist: string | null;
  album: string | null;
  appleMusicUrl: string | null;
  squareUrl: string | null;
  squareWidth: number | null;
  squareHeight: number | null;
  squareAspectRatio: number | null;
  tallUrl: string | null;
  tallWidth: number | null;
  tallHeight: number | null;
  tallAspectRatio: number | null;
  source: AnimatedArtworkSource;
}

export interface AnimatedAppleMusicArtworkResolverOptions {
  dataDir: string;
  enabled?: boolean;
  fetchBearerToken?: () => Promise<string | null>;
  fetchText?: (url: URL, signal: AbortSignal) => Promise<string>;
  fetchJson?: (url: URL, bearerToken: string, signal: AbortSignal) => Promise<unknown>;
  searchAppleMusicAlbumURL?: (
    artist: string,
    album: string,
    country: string,
    signal: AbortSignal,
  ) => Promise<string | null>;
  lookupAppleMusicAlbumURL?: (
    catalogID: string,
    country: string,
    signal: AbortSignal,
  ) => Promise<string | null>;
  now?: () => number;
  timeoutMs?: number;
  backoffMs?: number;
}

export interface ParsedAppleMusicAlbumURL {
  storefront: string;
  albumId: string;
}

type CacheFile = {
  entries?: Record<string, CacheEntry>;
};

type CacheEntry = {
  expiresAt: number;
  status: 'hit' | 'miss';
  resolution: AnimatedArtworkResolution;
};

type AmpAlbumAttributes = {
  artistName?: unknown;
  name?: unknown;
  url?: unknown;
  editorialVideo?: unknown;
};

type ArtworkDimensions = {
  width: number | null;
  height: number | null;
  aspectRatio: number | null;
};

const CACHE_FILE_NAME = 'animated-artwork-cache.json';
const POSITIVE_TTL_MS = 30 * 24 * 60 * 60 * 1_000;
const MISS_TTL_MS = 30 * 24 * 60 * 60 * 1_000;
const METADATA_MISS_TTL_MS = 7 * 24 * 60 * 60 * 1_000;
const DEFAULT_TIMEOUT_MS = 3_000;
const DEFAULT_BACKOFF_MS = 15 * 60 * 1_000;
let globalBackoffUntil = 0;

export class AnimatedAppleMusicArtworkResolver {
  private readonly dataDir: string;
  private readonly enabled: boolean;
  private readonly fetchBearerToken: () => Promise<string | null>;
  private readonly fetchText: (url: URL, signal: AbortSignal) => Promise<string>;
  private readonly fetchJson: (url: URL, bearerToken: string, signal: AbortSignal) => Promise<unknown>;
  private readonly searchAppleMusicAlbumURL: (
    artist: string,
    album: string,
    country: string,
    signal: AbortSignal,
  ) => Promise<string | null>;
  private readonly lookupAppleMusicAlbumURL: (
    catalogID: string,
    country: string,
    signal: AbortSignal,
  ) => Promise<string | null>;
  private readonly now: () => number;
  private readonly timeoutMs: number;
  private readonly backoffMs: number;
  private cache: Record<string, CacheEntry> | null = null;

  constructor(options: AnimatedAppleMusicArtworkResolverOptions) {
    this.dataDir = options.dataDir;
    this.enabled = options.enabled ?? true;
    this.fetchText = options.fetchText ?? defaultFetchText;
    this.fetchBearerToken = options.fetchBearerToken ?? (() => defaultFetchBearerToken(this.fetchText));
    this.fetchJson = options.fetchJson ?? defaultFetchJson;
    this.searchAppleMusicAlbumURL = options.searchAppleMusicAlbumURL
      ?? ((artist, album, country, signal) => (
        defaultSearchAppleMusicAlbumURL(artist, album, country, signal, this.fetchText)
      ));
    this.lookupAppleMusicAlbumURL = options.lookupAppleMusicAlbumURL
      ?? ((catalogID, country, signal) => (
        defaultLookupAppleMusicAlbumURL(catalogID, country, signal, this.fetchText)
      ));
    this.now = options.now ?? (() => Date.now());
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.backoffMs = options.backoffMs ?? DEFAULT_BACKOFF_MS;
  }

  async resolveByURL(value: string, _country?: string | null): Promise<AnimatedArtworkResolution> {
    if (!this.enabled) return emptyResolution('disabled');

    const parsed = parseAppleMusicAlbumURL(value);
    if (!parsed) return emptyResolution('miss');

    const key = `album:${parsed.storefront}:${parsed.albumId}`;
    const cached = await this.cachedResolution(key);
    if (cached) return cached;

    if (this.isBackedOff()) return emptyResolution('rate-limited');

    try {
      const token = await this.fetchBearerToken();
      if (!token) return emptyResolution('error');

      const resolution = await this.withTimeout(async signal => {
        const response = await this.fetchJson(ampAlbumURL(parsed.storefront, parsed.albumId), token, signal);
        return await this.resolutionWithArtworkDimensions(resolutionFromAmpResponse(response), signal);
      });
      const ttl = resolution.status === 'hit' ? POSITIVE_TTL_MS : MISS_TTL_MS;
      await this.writeCacheEntry(key, resolution, ttl);
      return resolution;
    } catch (err) {
      if (isRateLimitError(err)) {
        globalBackoffUntil = this.now() + this.backoffMs;
        return emptyResolution('rate-limited');
      }
      return emptyResolution('error');
    }
  }

  async resolveByMetadata(
    artist: string,
    album: string,
    country: string | null = null,
    catalogID: string | null = null,
  ): Promise<AnimatedArtworkResolution> {
    if (!this.enabled) return emptyResolution('disabled');

    const normalizedArtist = normalizeMetadata(artist);
    const normalizedAlbum = normalizeMetadata(album);
    const normalizedCountry = normalizeCountry(country);
    const normalizedCatalogID = normalizeCatalogID(catalogID);
    if (!normalizedArtist || !normalizedAlbum) return emptyResolution('miss');

    const key = `metadata:${normalizedArtist}:${normalizedAlbum}:${normalizedCountry}`;
    const knownAlbum = await this.cachedAlbumHit(normalizedArtist, normalizedAlbum);
    if (knownAlbum) return knownAlbum;

    const cached = await this.cachedResolution(key);
    // A metadata-search miss is not authoritative when Sonos exposes an exact
    // Apple Music catalog ID. Let the ID lookup repair the stale negative key.
    if (cached && (cached.status !== 'negative-cache' || !normalizedCatalogID)) return cached;

    if (this.isBackedOff()) return emptyResolution('rate-limited');

    try {
      const albumURL = await this.withTimeout(async signal => {
        let exactURL: string | null = null;
        if (normalizedCatalogID) {
          try {
            exactURL = await this.lookupAppleMusicAlbumURL(
              normalizedCatalogID,
              normalizedCountry,
              signal,
            );
          } catch (err) {
            if (isRateLimitError(err)) throw err;
          }
        }
        return exactURL ?? await this.searchAppleMusicAlbumURL(
          artist.trim(),
          album.trim(),
          normalizedCountry,
          signal,
        );
      });
      if (!albumURL) {
        const miss = emptyResolution('miss');
        await this.writeCacheEntry(key, miss, METADATA_MISS_TTL_MS);
        return miss;
      }

      const resolved = await this.resolveByURL(albumURL, normalizedCountry);
      const source = resolved.status === 'hit' ? 'metadata-search' : resolved.source;
      const resolution: AnimatedArtworkResolution = { ...resolved, source };
      if (resolution.status === 'hit') {
        await this.writeCacheEntry(key, resolution, POSITIVE_TTL_MS);
      }
      return resolution;
    } catch (err) {
      if (isRateLimitError(err)) {
        globalBackoffUntil = this.now() + this.backoffMs;
        return emptyResolution('rate-limited');
      }
      return emptyResolution('error');
    }
  }

  private async cachedResolution(key: string): Promise<AnimatedArtworkResolution | null> {
    const cache = await this.loadCache();
    const entry = cache[key];
    if (!entry) return null;
    if (entry.expiresAt <= this.now()) {
      delete cache[key];
      await this.saveCache();
      return null;
    }
    if (entry.status === 'miss') {
      return withDimensionDefaults({ ...entry.resolution, status: 'negative-cache', source: 'cache' });
    }
    return withDimensionDefaults({ ...entry.resolution, source: 'cache' });
  }

  private async cachedAlbumHit(
    normalizedArtist: string,
    normalizedAlbum: string,
  ): Promise<AnimatedArtworkResolution | null> {
    const cache = await this.loadCache();
    let removedExpiredEntry = false;
    for (const [key, entry] of Object.entries(cache)) {
      if (entry.expiresAt <= this.now()) {
        delete cache[key];
        removedExpiredEntry = true;
        continue;
      }
      if (entry.status !== 'hit' || entry.resolution.status !== 'hit') continue;
      if (normalizeMetadata(entry.resolution.artist ?? '') !== normalizedArtist) continue;
      if (normalizeMetadata(entry.resolution.album ?? '') !== normalizedAlbum) continue;
      if (removedExpiredEntry) await this.saveCache();
      return withDimensionDefaults({ ...entry.resolution, source: 'cache' });
    }
    if (removedExpiredEntry) await this.saveCache();
    return null;
  }

  private async resolutionWithArtworkDimensions(
    resolution: AnimatedArtworkResolution,
    signal: AbortSignal,
  ): Promise<AnimatedArtworkResolution> {
    if (resolution.status !== 'hit') return resolution;

    const [square, tall] = await Promise.all([
      this.dimensionsForPlaylist(resolution.squareUrl, signal),
      this.dimensionsForPlaylist(resolution.tallUrl, signal),
    ]);

    return {
      ...resolution,
      squareWidth: square.width,
      squareHeight: square.height,
      squareAspectRatio: square.aspectRatio,
      tallWidth: tall.width,
      tallHeight: tall.height,
      tallAspectRatio: tall.aspectRatio,
    };
  }

  private async dimensionsForPlaylist(
    urlString: string | null,
    signal: AbortSignal,
  ): Promise<ArtworkDimensions> {
    if (!urlString) return emptyDimensions();
    try {
      const playlist = await this.fetchText(new URL(urlString), signal);
      return dimensionsFromHLSMasterPlaylist(playlist);
    } catch {
      return emptyDimensions();
    }
  }

  private async writeCacheEntry(
    key: string,
    resolution: AnimatedArtworkResolution,
    ttlMs: number,
  ): Promise<void> {
    const cache = await this.loadCache();
    cache[key] = {
      expiresAt: this.now() + ttlMs,
      status: resolution.status === 'hit' ? 'hit' : 'miss',
      resolution,
    };
    await this.saveCache();
  }

  private async loadCache(): Promise<Record<string, CacheEntry>> {
    if (this.cache) return this.cache;
    try {
      const raw = await readFile(this.cachePath(), 'utf8');
      const parsed = JSON.parse(raw) as CacheFile;
      this.cache = parsed.entries && typeof parsed.entries === 'object' ? parsed.entries : {};
    } catch {
      this.cache = {};
    }
    return this.cache;
  }

  private async saveCache(): Promise<void> {
    await mkdir(this.dataDir, { recursive: true });
    await writeFile(
      this.cachePath(),
      JSON.stringify({ entries: this.cache ?? {} }, null, 2),
      'utf8',
    );
  }

  private cachePath(): string {
    return path.join(this.dataDir, CACHE_FILE_NAME);
  }

  private isBackedOff(): boolean {
    return globalBackoffUntil > this.now();
  }

  private async withTimeout<T>(operation: (signal: AbortSignal) => Promise<T>): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => {
      controller.abort();
    }, this.timeoutMs);
    timer.unref?.();
    try {
      return await operation(controller.signal);
    } finally {
      clearTimeout(timer);
    }
  }
}

export function parseAppleMusicAlbumURL(value: string): ParsedAppleMusicAlbumURL | null {
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    return null;
  }

  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
  if (url.hostname !== 'music.apple.com') return null;

  const parts = url.pathname.split('/').filter(Boolean);
  if (parts.length < 4) return null;
  const storefront = parts[0]?.toLowerCase();
  const kind = parts[1];
  if (!storefront || kind !== 'album') return null;

  const albumId = [...parts].reverse().find(part => /^\d+$/.test(part));
  if (!albumId) return null;
  return { storefront, albumId };
}

function ampAlbumURL(storefront: string, albumId: string): URL {
  const url = new URL(`https://amp-api.music.apple.com/v1/catalog/${storefront}/albums/${albumId}`);
  url.searchParams.set('extend', 'editorialVideo');
  url.searchParams.set('platform', 'web');
  return url;
}

function resolutionFromAmpResponse(response: unknown): AnimatedArtworkResolution {
  const attributes = firstAlbumAttributes(response);
  const squareUrl = firstM3U8URL(videoValue(attributes?.editorialVideo, 'motionDetailSquare'));
  const tallUrl = firstM3U8URL(videoValue(attributes?.editorialVideo, 'motionDetailTall'));
  const hasVideo = Boolean(squareUrl || tallUrl);
  return {
    ok: true,
    status: hasVideo ? 'hit' : 'miss',
    artist: stringValue(attributes?.artistName),
    album: stringValue(attributes?.name),
    appleMusicUrl: stringValue(attributes?.url),
    squareUrl,
    squareWidth: null,
    squareHeight: null,
    squareAspectRatio: null,
    tallUrl,
    tallWidth: null,
    tallHeight: null,
    tallAspectRatio: null,
    source: hasVideo ? 'url' : 'none',
  };
}

function dimensionsFromHLSMasterPlaylist(value: string): ArtworkDimensions {
  let best: { width: number; height: number } | null = null;
  for (const match of value.matchAll(/RESOLUTION=(\d+)x(\d+)/gi)) {
    const width = Number(match[1]);
    const height = Number(match[2]);
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      continue;
    }
    if (!best || width * height > best.width * best.height) {
      best = { width, height };
    }
  }
  if (!best) return emptyDimensions();
  return {
    width: best.width,
    height: best.height,
    aspectRatio: Number((best.width / best.height).toFixed(6)),
  };
}

function emptyDimensions(): ArtworkDimensions {
  return { width: null, height: null, aspectRatio: null };
}

function withDimensionDefaults(resolution: AnimatedArtworkResolution): AnimatedArtworkResolution {
  return {
    ...resolution,
    squareWidth: resolution.squareWidth ?? null,
    squareHeight: resolution.squareHeight ?? null,
    squareAspectRatio: resolution.squareAspectRatio ?? null,
    tallWidth: resolution.tallWidth ?? null,
    tallHeight: resolution.tallHeight ?? null,
    tallAspectRatio: resolution.tallAspectRatio ?? null,
  };
}

function firstAlbumAttributes(response: unknown): AmpAlbumAttributes | null {
  if (!response || typeof response !== 'object') return null;
  const data = (response as { data?: unknown }).data;
  if (!Array.isArray(data)) return null;
  const first = data[0];
  if (!first || typeof first !== 'object') return null;
  const attributes = (first as { attributes?: unknown }).attributes;
  return attributes && typeof attributes === 'object' ? attributes as AmpAlbumAttributes : null;
}

function videoValue(editorialVideo: unknown, key: string): unknown {
  if (!editorialVideo || typeof editorialVideo !== 'object') return null;
  const detail = (editorialVideo as Record<string, unknown>)[key];
  if (!detail || typeof detail !== 'object') return null;
  return (detail as Record<string, unknown>).video;
}

function firstM3U8URL(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const matches = value.match(/https?:\/\/[^\s"',)]+\.m3u8(?:\?[^\s"',)]*)?/gi) ?? [];
  for (const match of matches) {
    try {
      const url = new URL(match);
      if ((url.protocol === 'http:' || url.protocol === 'https:') && url.pathname.endsWith('.m3u8')) {
        return url.toString();
      }
    } catch {
      // Ignore malformed candidates.
    }
  }
  return null;
}

async function defaultFetchJson(url: URL, bearerToken: string, signal: AbortSignal): Promise<unknown> {
  const response = await fetch(url, {
    headers: {
      Accept: 'application/json',
      Authorization: `Bearer ${bearerToken}`,
      Origin: 'https://music.apple.com',
    },
    signal,
  });
  if (!response.ok) throw httpError(response.status, `Apple Music AMP request failed: HTTP ${response.status}`);
  return await response.json() as unknown;
}

async function defaultFetchText(url: URL, signal: AbortSignal): Promise<string> {
  const response = await fetch(url, { headers: { Accept: 'text/html,*/*' }, signal });
  if (!response.ok) throw httpError(response.status, `Apple Music text request failed: HTTP ${response.status}`);
  return await response.text();
}

async function defaultFetchBearerToken(
  fetchText: (url: URL, signal: AbortSignal) => Promise<string>,
): Promise<string | null> {
  const controller = new AbortController();
  const html = await fetchText(new URL('https://music.apple.com/'), controller.signal);
  const scriptPaths = new Set<string>();
  for (const match of html.matchAll(/<script[^>]+src=["']([^"']+\.js(?:\?[^"']*)?)["']/gi)) {
    scriptPaths.add(match[1] ?? '');
  }
  for (const pathOrUrl of scriptPaths) {
    const scriptURL = new URL(pathOrUrl, 'https://music.apple.com/');
    if (scriptURL.origin !== 'https://music.apple.com') continue;
    const js = await fetchText(scriptURL, controller.signal);
    const token = bearerTokenFromText(js);
    if (token) return token;
  }
  return bearerTokenFromText(html);
}

function bearerTokenFromText(value: string): string | null {
  const patterns = [
    /(?:bearerToken|developerToken|token)\s*[:=]\s*["']([A-Za-z0-9._-]{50,})["']/,
    /Bearer\s+([A-Za-z0-9._-]{50,})/,
  ];
  for (const pattern of patterns) {
    const match = value.match(pattern);
    if (match?.[1]) return match[1];
  }
  return bareAppleJWTFromText(value);
}

function bareAppleJWTFromText(value: string): string | null {
  const pattern = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g;
  for (const match of value.matchAll(pattern)) {
    const token = match[0];
    const payload = jwtPayload(token);
    if (payload && isAppleMusicTokenPayload(payload)) return token;
  }
  return null;
}

function jwtPayload(token: string): Record<string, unknown> | null {
  const payload = token.split('.')[1];
  if (!payload) return null;
  try {
    const parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as unknown;
    return parsed && typeof parsed === 'object' ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

function isAppleMusicTokenPayload(payload: Record<string, unknown>): boolean {
  const exp = payload.exp;
  if (typeof exp === 'number' && exp <= Math.floor(Date.now() / 1_000)) return false;

  const issuer = stringValue(payload.iss);
  if (issuer === 'AMPWebPlay') return true;

  const rootOrigins = payload.root_https_origin;
  if (Array.isArray(rootOrigins) && rootOrigins.some(origin => stringValue(origin)?.endsWith('apple.com'))) {
    return true;
  }

  const origin = stringValue(payload.origin);
  return origin ? origin.includes('apple.com') : false;
}

async function defaultSearchAppleMusicAlbumURL(
  artist: string,
  album: string,
  country: string,
  signal: AbortSignal,
  fetchText: (url: URL, signal: AbortSignal) => Promise<string>,
): Promise<string | null> {
  const url = new URL('https://itunes.apple.com/search');
  url.searchParams.set('term', `${artist} ${album}`);
  url.searchParams.set('media', 'music');
  url.searchParams.set('entity', 'album');
  url.searchParams.set('limit', '10');
  url.searchParams.set('country', country);

  const body = JSON.parse(await fetchText(url, signal)) as { results?: unknown[] };
  const targetArtist = normalizeMetadata(artist);
  const targetAlbum = normalizeMetadata(album);
  for (const result of body.results ?? []) {
    if (!result || typeof result !== 'object') continue;
    const row = result as Record<string, unknown>;
    if (normalizeMetadata(stringValue(row.artistName) ?? '') !== targetArtist) continue;
    if (normalizeMetadata(stringValue(row.collectionName) ?? '') !== targetAlbum) continue;
    const collectionViewUrl = stringValue(row.collectionViewUrl);
    if (collectionViewUrl && parseAppleMusicAlbumURL(collectionViewUrl)) return collectionViewUrl;
  }
  return null;
}

async function defaultLookupAppleMusicAlbumURL(
  catalogID: string,
  country: string,
  signal: AbortSignal,
  fetchText: (url: URL, signal: AbortSignal) => Promise<string>,
): Promise<string | null> {
  const url = new URL('https://itunes.apple.com/lookup');
  url.searchParams.set('id', catalogID);
  url.searchParams.set('entity', 'song');
  url.searchParams.set('country', country);

  const body = JSON.parse(await fetchText(url, signal)) as { results?: unknown[] };
  for (const result of body.results ?? []) {
    if (!result || typeof result !== 'object') continue;
    const row = result as Record<string, unknown>;
    const collectionViewUrl = stringValue(row.collectionViewUrl);
    if (collectionViewUrl && parseAppleMusicAlbumURL(collectionViewUrl)) return collectionViewUrl;

    const collectionID = numberStringValue(row.collectionId);
    if (collectionID) {
      return `https://music.apple.com/${country.toLowerCase()}/album/-/${collectionID}`;
    }
  }
  return null;
}

function emptyResolution(status: AnimatedArtworkStatus): AnimatedArtworkResolution {
  return {
    ok: true,
    status,
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

function normalizeMetadata(value: string): string {
  return value
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');
}

function normalizeCatalogID(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? '';
  return /^\d+$/.test(trimmed) ? trimmed : null;
}

function numberStringValue(value: unknown): string | null {
  if (typeof value === 'number' && Number.isSafeInteger(value) && value > 0) return String(value);
  if (typeof value === 'string' && /^\d+$/.test(value.trim())) return value.trim();
  return null;
}

function normalizeCountry(value: string | null | undefined): string {
  const trimmed = value?.trim() ?? '';
  return (trimmed || 'US').toUpperCase();
}

function stringValue(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function isRateLimitError(err: unknown): boolean {
  const status = typeof err === 'object' && err !== null
    ? (err as { status?: unknown; statusCode?: unknown }).status
      ?? (err as { statusCode?: unknown }).statusCode
    : undefined;
  return status === 403 || status === 429;
}

function httpError(status: number, message: string): Error & { status: number } {
  const error = new Error(message) as Error & { status: number };
  error.status = status;
  return error;
}
