export type ITunesArtworkKind = 'song' | 'album' | 'artist';

export interface ITunesArtworkSearchInput {
  kind: ITunesArtworkKind;
  title: string;
  artist?: string | null;
  album?: string | null;
  countryCode?: string | null;
}

export interface ITunesArtworkClientOptions {
  fetchJson?: (url: URL, signal: AbortSignal) => Promise<ITunesLookupResponse>;
  timeoutMs?: number;
  cacheTtlMs?: number;
  maxCacheEntries?: number;
  now?: () => number;
}

interface ITunesLookupResponse {
  resultCount?: number;
  results?: ITunesResult[];
}

interface ITunesResult {
  wrapperType?: string | null;
  kind?: string | null;
  trackId?: number | null;
  trackName?: string | null;
  collectionName?: string | null;
  artistName?: string | null;
  artworkUrl30?: string | null;
  artworkUrl60?: string | null;
  artworkUrl100?: string | null;
}

interface CacheEntry {
  expiresAt: number;
  url: string | null;
}

const DEFAULT_TIMEOUT_MS = 1_500;
const DEFAULT_CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1_000;
const DEFAULT_MAX_CACHE_ENTRIES = 500;

export class ITunesArtworkClient {
  private readonly fetchJson: (url: URL, signal: AbortSignal) => Promise<ITunesLookupResponse>;
  private readonly timeoutMs: number;
  private readonly cacheTtlMs: number;
  private readonly maxCacheEntries: number;
  private readonly now: () => number;
  private readonly cache = new Map<string, CacheEntry>();

  constructor(options: ITunesArtworkClientOptions = {}) {
    this.fetchJson = options.fetchJson ?? defaultFetchJson;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.cacheTtlMs = options.cacheTtlMs ?? DEFAULT_CACHE_TTL_MS;
    this.maxCacheEntries = options.maxCacheEntries ?? DEFAULT_MAX_CACHE_ENTRIES;
    this.now = options.now ?? (() => Date.now());
  }

  async lookupArtworkURLString(catalogID: string, countryCode?: string | null): Promise<string | null> {
    const trimmedID = catalogID.trim();
    if (!/^\d+$/.test(trimmedID)) return null;

    const url = new URL('https://itunes.apple.com/lookup');
    url.searchParams.set('id', trimmedID);
    url.searchParams.set('country', normalizedCountryCode(countryCode));

    return this.cached(`lookup:${url.toString()}`, async () => {
      const response = await this.request(url);
      return firstArtworkURL(response.results ?? []);
    });
  }

  async searchArtworkURLString(input: ITunesArtworkSearchInput): Promise<string | null> {
    const entity = iTunesEntity(input.kind);
    if (!entity) return null;

    const term = searchTerm(input);
    if (!term) return null;

    const url = new URL('https://itunes.apple.com/search');
    url.searchParams.set('term', term);
    url.searchParams.set('media', 'music');
    url.searchParams.set('entity', entity);
    url.searchParams.set('limit', '5');
    url.searchParams.set('country', normalizedCountryCode(input.countryCode));

    return this.cached(`search:${url.toString()}`, async () => {
      const response = await this.request(url);
      const match = bestResult(response.results ?? [], input);
      return match ? artworkURLString(match) : null;
    });
  }

  private async cached(key: string, load: () => Promise<string | null>): Promise<string | null> {
    const existing = this.cache.get(key);
    const now = this.now();
    if (existing && existing.expiresAt > now) {
      return existing.url;
    }
    if (existing) this.cache.delete(key);

    const url = await load();
    this.cache.set(key, {
      url,
      expiresAt: now + this.cacheTtlMs,
    });
    while (this.cache.size > this.maxCacheEntries) {
      const oldestKey = this.cache.keys().next().value as string | undefined;
      if (!oldestKey) break;
      this.cache.delete(oldestKey);
    }
    return url;
  }

  private async request(url: URL): Promise<ITunesLookupResponse> {
    const controller = new AbortController();
    const timer = setTimeout(() => {
      controller.abort();
    }, this.timeoutMs);
    timer.unref?.();

    try {
      return await this.fetchJson(url, controller.signal);
    } finally {
      clearTimeout(timer);
    }
  }
}

async function defaultFetchJson(url: URL, signal: AbortSignal): Promise<ITunesLookupResponse> {
  const response = await fetch(url, {
    method: 'GET',
    headers: { Accept: 'application/json' },
    signal,
  });
  if (!response.ok) {
    throw new Error(`iTunes artwork request failed: HTTP ${response.status}`);
  }
  return await response.json() as ITunesLookupResponse;
}

function firstArtworkURL(results: ITunesResult[]): string | null {
  for (const result of results) {
    const url = artworkURLString(result);
    if (url) return url;
  }
  return null;
}

function bestResult(results: ITunesResult[], input: ITunesArtworkSearchInput): ITunesResult | null {
  let best: { result: ITunesResult; score: number } | null = null;

  for (const result of results) {
    if (!artworkURLString(result)) continue;
    const score = resultScore(result, input);
    if (score <= 0) continue;
    if (!best || score > best.score) {
      best = { result, score };
    }
  }

  return best?.result ?? null;
}

function resultScore(result: ITunesResult, input: ITunesArtworkSearchInput): number {
  const targetTitle = normalized(input.title);
  const targetArtist = normalized(input.artist ?? '');
  const targetAlbum = normalized(input.album ?? '');
  const resultTitle = normalized(input.kind === 'album'
    ? result.collectionName ?? result.trackName ?? ''
    : input.kind === 'artist'
      ? result.artistName ?? result.trackName ?? ''
      : result.trackName ?? '');
  const resultArtist = normalized(result.artistName ?? '');
  const resultAlbum = normalized(result.collectionName ?? '');

  if (!targetTitle || resultTitle !== targetTitle) return 0;

  let score = 4;
  const artistMatches = Boolean(targetArtist && resultArtist === targetArtist);
  const albumMatches = Boolean(targetAlbum && resultAlbum === targetAlbum);

  if ((targetArtist || targetAlbum) && !artistMatches && !albumMatches) {
    return 0;
  }

  if (artistMatches) score += 3;
  if (albumMatches) score += 2;

  const wrapper = (result.wrapperType ?? '').toLowerCase();
  if (input.kind === 'song' && wrapper === 'track') score += 1;
  if (input.kind === 'album' && wrapper === 'collection') score += 1;
  if (input.kind === 'artist' && wrapper === 'artist') score += 1;
  return score;
}

function artworkURLString(result: ITunesResult): string | null {
  const raw = result.artworkUrl100 ?? result.artworkUrl60 ?? result.artworkUrl30;
  if (!raw) return null;

  try {
    const url = new URL(raw);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
    url.pathname = url.pathname.replace(/\/\d+x\d+bb(?:\.[a-z0-9]+)?$/i, '/600x600bb.jpg');
    return url.toString();
  } catch {
    return null;
  }
}

function iTunesEntity(kind: ITunesArtworkKind): string | null {
  switch (kind) {
    case 'song':
      return 'song';
    case 'album':
      return 'album';
    case 'artist':
      return 'musicArtist';
  }
}

function searchTerm(input: ITunesArtworkSearchInput): string {
  const parts = input.kind === 'song'
    ? [input.title, input.artist, input.album]
    : input.kind === 'album'
      ? [input.title, input.artist]
      : [input.title];
  return parts
    .map(value => value?.trim() ?? '')
    .filter(Boolean)
    .join(' ');
}

function normalizedCountryCode(value: string | null | undefined): string {
  const trimmed = value?.trim() ?? '';
  return (trimmed || 'US').toUpperCase();
}

function normalized(value: string): string {
  return value
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');
}
