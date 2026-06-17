const MAX_ALBUM_ART_BYTES = 5 * 1024 * 1024;
const DEFAULT_MAX_CACHE_ENTRIES = 50;

export type AlbumArtFetcher = (uri: string) => Promise<Buffer>;

export class AlbumArtFetchCache {
  private readonly maxEntries: number;
  private readonly memory = new Map<string, Buffer>();
  private readonly inFlight = new Map<string, Promise<Buffer>>();

  constructor(maxEntries = DEFAULT_MAX_CACHE_ENTRIES) {
    this.maxEntries = Math.max(1, Math.floor(maxEntries));
  }

  fetch(uri: string, fetcher: AlbumArtFetcher = networkFetchAlbumArt): Promise<Buffer> {
    const key = normalizedAlbumArtUri(uri);
    const cached = this.memory.get(key);
    if (cached) {
      this.memory.delete(key);
      this.memory.set(key, cached);
      return Promise.resolve(cached);
    }

    const inFlight = this.inFlight.get(key);
    if (inFlight) return inFlight;

    const request = fetcher(key)
      .then(data => {
        this.remember(key, data);
        return data;
      })
      .finally(() => {
        this.inFlight.delete(key);
      });

    this.inFlight.set(key, request);
    return request;
  }

  clear(): void {
    this.memory.clear();
    this.inFlight.clear();
  }

  private remember(uri: string, data: Buffer): void {
    this.memory.set(uri, data);
    while (this.memory.size > this.maxEntries) {
      const oldest = this.memory.keys().next().value;
      if (oldest === undefined) return;
      this.memory.delete(oldest);
    }
  }
}

export const sharedAlbumArtFetchCache = new AlbumArtFetchCache();

export function fetchAlbumArt(uri: string): Promise<Buffer> {
  return sharedAlbumArtFetchCache.fetch(uri);
}

export function clearSharedAlbumArtFetchCacheForTests(): void {
  sharedAlbumArtFetchCache.clear();
}

async function networkFetchAlbumArt(uri: string): Promise<Buffer> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5_000);
  try {
    const response = await fetch(uri, { signal: controller.signal });
    if (!response.ok) {
      throw new Error(`Album art request failed with HTTP ${response.status}`);
    }

    const contentLength = Number(response.headers.get('content-length') ?? '0');
    if (contentLength > MAX_ALBUM_ART_BYTES) {
      throw new Error('Album art response is too large');
    }

    const arrayBuffer = await response.arrayBuffer();
    if (arrayBuffer.byteLength > MAX_ALBUM_ART_BYTES) {
      throw new Error('Album art response is too large');
    }

    return Buffer.from(arrayBuffer);
  } finally {
    clearTimeout(timeout);
  }
}

function normalizedAlbumArtUri(uri: string): string {
  return uri.trim();
}
