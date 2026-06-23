import type { ArtworkHintLookup, ArtworkHintStore } from './artworkHints.js';
import { isLocalSonosArtworkUrl } from './artworkHints.js';
import { ITunesArtworkClient, type ITunesArtworkSearchInput } from './itunesArtwork.js';

export type SonosArtworkResolutionSource =
  | 'public'
  | 'hint'
  | 'itunesLookup'
  | 'itunesSearch'
  | 'getaa'
  | 'none';

export interface SonosArtworkResolution {
  source: SonosArtworkResolutionSource;
  url: string | null;
  catalogID?: string | null;
}

export interface SonosArtworkResolveInput {
  title?: string | null;
  artist?: string | null;
  album?: string | null;
  trackUri?: string | null;
  albumArtUri?: string | null;
  playbackSourceRaw?: string | null;
  countryCode?: string | null;
}

export interface SonosArtworkResolver {
  resolve(input: SonosArtworkResolveInput): Promise<SonosArtworkResolution>;
}

export interface SonosArtworkResolverOptions {
  artworkHints?: Pick<ArtworkHintStore, 'resolve'> | null;
  itunes?: ITunesArtworkLookupClient;
  countryCode?: string | null;
}

export interface ResolveSonosArtworkInput extends SonosArtworkResolveInput {
  artworkHints?: Pick<ArtworkHintStore, 'resolve'> | null;
  itunes?: ITunesArtworkLookupClient;
}

export interface ITunesArtworkLookupClient {
  lookupArtworkURLString(catalogID: string, countryCode?: string | null): Promise<string | null>;
  searchArtworkURLString(input: ITunesArtworkSearchInput): Promise<string | null>;
}

const sharedITunesArtworkClient = new ITunesArtworkClient();

export function createSonosArtworkResolver(options: SonosArtworkResolverOptions = {}): SonosArtworkResolver {
  const itunes = options.itunes ?? sharedITunesArtworkClient;
  const artworkHints = options.artworkHints ?? null;
  const countryCode = options.countryCode ?? null;
  return {
    resolve: input => resolveSonosArtwork({
      ...input,
      countryCode: input.countryCode ?? countryCode,
      artworkHints,
      itunes,
    }),
  };
}

export async function resolveSonosArtwork(input: ResolveSonosArtworkInput): Promise<SonosArtworkResolution> {
  const currentArtwork = trimmedOrNull(input.albumArtUri);
  if (isPublicArtworkURL(currentArtwork)) {
    return { source: 'public', url: currentArtwork };
  }

  const hint = input.artworkHints?.resolve(artworkHintLookup(input)) ?? null;
  if (isPublicArtworkURL(hint)) {
    return { source: 'hint', url: hint };
  }

  const catalogID = appleMusicCatalogIDFromSonosValues(input.trackUri, currentArtwork);
  const appleMusicCandidate = isAppleMusicCandidate(input, catalogID);
  const itunes = input.itunes ?? sharedITunesArtworkClient;

  if (appleMusicCandidate && catalogID) {
    const lookupURL = await safeResolve(() =>
      itunes.lookupArtworkURLString(catalogID, input.countryCode));
    if (isPublicArtworkURL(lookupURL)) {
      return { source: 'itunesLookup', url: lookupURL, catalogID };
    }
  }

  if (appleMusicCandidate && shouldSearchITunes(input)) {
    const searchURL = await safeResolve(() =>
      itunes.searchArtworkURLString({
        kind: 'song',
        title: input.title?.trim() ?? '',
        artist: input.artist,
        album: input.album,
        countryCode: input.countryCode,
      }));
    if (isPublicArtworkURL(searchURL)) {
      return { source: 'itunesSearch', url: searchURL, catalogID };
    }
  }

  if (currentArtwork && isLocalSonosArtworkUrl(currentArtwork)) {
    return { source: 'getaa', url: currentArtwork, catalogID };
  }

  return { source: 'none', url: currentArtwork, catalogID };
}

export function appleMusicCatalogIDFromSonosValues(
  ...values: Array<string | null | undefined>
): string | null {
  for (const value of values) {
    for (const candidate of sonosObjectCandidates(value)) {
      const decoded = decodeRepeated(candidate);
      const match = decoded.match(/(?:song|album):(\d+)/i);
      if (match?.[1]) return match[1];
    }
  }
  return null;
}

function sonosObjectCandidates(value: string | null | undefined): string[] {
  const trimmed = value?.trim() ?? '';
  if (!trimmed) return [];

  const candidates = [trimmed];
  try {
    const url = new URL(trimmed);
    const wrappedUri = url.searchParams.get('u');
    if (wrappedUri) candidates.push(wrappedUri);
  } catch {
    // Not an absolute URL; raw Sonos URIs are still candidates.
  }
  return candidates;
}

function isAppleMusicCandidate(input: SonosArtworkResolveInput, catalogID: string | null): boolean {
  if (input.playbackSourceRaw === 'appleMusic') return true;

  const haystack = [input.trackUri, input.albumArtUri]
    .flatMap(value => sonosObjectCandidates(value))
    .map(decodeRepeated)
    .join(' ')
    .toLowerCase();

  if (!haystack) return false;
  if (haystack.includes('sid=204')) return true;
  if (haystack.includes('x-sonosprog-http:')) return true;
  return Boolean(catalogID && haystack.includes('x-sonos-http:') && haystack.includes('song:'));
}

function shouldSearchITunes(input: SonosArtworkResolveInput): boolean {
  const title = input.title?.trim() ?? '';
  const artist = input.artist?.trim() ?? '';
  const album = input.album?.trim() ?? '';
  return Boolean(title && (artist || album));
}

function artworkHintLookup(input: SonosArtworkResolveInput): ArtworkHintLookup {
  return {
    title: input.title,
    artist: input.artist,
    album: input.album,
    objectIds: [input.trackUri],
    currentArtworkUrl: input.albumArtUri,
  };
}

function isPublicArtworkURL(value: string | null | undefined): value is string {
  const trimmed = trimmedOrNull(value);
  if (!trimmed || isLocalSonosArtworkUrl(trimmed)) return false;

  try {
    const url = new URL(trimmed);
    return url.protocol === 'http:' || url.protocol === 'https:';
  } catch {
    return false;
  }
}

async function safeResolve(resolve: () => Promise<string | null>): Promise<string | null> {
  try {
    return await resolve();
  } catch {
    return null;
  }
}

function trimmedOrNull(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? '';
  return trimmed.length > 0 ? trimmed : null;
}

function decodeRepeated(value: string): string {
  let decoded = value;
  for (let index = 0; index < 3; index += 1) {
    try {
      const next = decodeURIComponent(decoded);
      if (next === decoded) break;
      decoded = next;
    } catch {
      break;
    }
  }
  return decoded;
}
