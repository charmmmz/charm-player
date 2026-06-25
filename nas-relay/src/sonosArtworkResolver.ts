import type { Logger } from 'pino';

import { ITunesArtworkClient, type ITunesArtworkSearchInput } from './itunesArtwork.js';

export type SonosArtworkResolutionSource =
  | 'getaa'
  | 'itunes-lookup'
  | 'itunes-search'
  | 'none';

export interface SonosArtworkResolution {
  source: SonosArtworkResolutionSource;
  url: string | null;
  catalogID?: string | null;
  fallbackSource?: SonosArtworkResolutionSource | null;
  fallbackUrl?: string | null;
  fallbackCatalogID?: string | null;
}

export interface SonosArtworkResolveInput {
  groupId?: string | null;
  trigger?: string | null;
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
  logger?: Pick<Logger, 'info' | 'warn'> | null;
  itunes?: ITunesArtworkLookupClient | null;
  countryCode?: string | null;
}

export interface ResolveSonosArtworkInput extends SonosArtworkResolveInput {
  artworkHints?: unknown;
  itunes?: unknown;
}

export interface ITunesArtworkLookupClient {
  lookupArtworkURLString(catalogID: string, countryCode?: string | null): Promise<string | null>;
  searchArtworkURLString(input: ITunesArtworkSearchInput): Promise<string | null>;
}

export type ITunesArtworkProbeStatus = 'hit' | 'miss' | 'error' | 'skipped';
export type ITunesArtworkProbeMethod = 'lookup' | 'search' | null;
export type ITunesArtworkProbeStepStatus = 'hit' | 'miss' | 'error' | 'skipped';

export interface ITunesArtworkProbeInput extends SonosArtworkResolveInput {
  itunes: ITunesArtworkLookupClient;
}

export interface ITunesArtworkProbeResult {
  status: ITunesArtworkProbeStatus;
  method: ITunesArtworkProbeMethod;
  lookupStatus: ITunesArtworkProbeStepStatus;
  searchStatus: ITunesArtworkProbeStepStatus;
  url: string | null;
  catalogID: string | null;
  ms: number;
  error?: unknown;
}

const sharedITunesArtworkClient = new ITunesArtworkClient();

export function createSonosArtworkResolver(options: SonosArtworkResolverOptions = {}): SonosArtworkResolver {
  const logger = options.logger ?? null;
  const itunes = options.itunes === undefined ? sharedITunesArtworkClient : options.itunes;
  const countryCode = options.countryCode ?? null;
  return {
    async resolve(input) {
      const resolution = await resolveSonosArtwork(input);
      if (itunes) {
        const probeInput = {
          ...input,
          countryCode: input.countryCode ?? countryCode,
          itunes,
        };
        if (shouldUseITunesArtworkForLiveRadio(input)) {
          const result = await probeITunesArtwork(probeInput);
          logITunesArtworkProbe(logger, probeInput, result, 'iTunes artwork probe');
          if (result.status === 'hit' && result.url) {
            return {
              source: result.method === 'lookup' ? 'itunes-lookup' : 'itunes-search',
              url: result.url,
              catalogID: result.catalogID,
            };
          }
          return resolution;
        }

        try {
          const result = await probeITunesArtwork(probeInput);
          logITunesArtworkProbe(logger, probeInput, result, 'iTunes artwork shadow probe');
          if (result.status === 'hit' && result.url && result.url !== resolution.url) {
            return {
              ...resolution,
              fallbackSource: result.method === 'lookup' ? 'itunes-lookup' : 'itunes-search',
              fallbackUrl: result.url,
              fallbackCatalogID: result.catalogID,
            };
          }
        } catch (error) {
          logITunesArtworkProbe(logger, probeInput, {
            status: 'error',
            method: null,
            lookupStatus: 'skipped',
            searchStatus: 'skipped',
            url: null,
            catalogID: null,
            ms: 0,
            error,
          }, 'iTunes artwork shadow probe');
        }
      }
      return resolution;
    },
  };
}

export function resolveSonosArtwork(input: ResolveSonosArtworkInput): Promise<SonosArtworkResolution> {
  const currentArtwork = trimmedOrNull(input.albumArtUri);
  if (isSonosGetAAArtworkURI(currentArtwork)) {
    return Promise.resolve({ source: 'getaa', url: currentArtwork });
  }

  return Promise.resolve({ source: 'none', url: null });
}

export async function probeITunesArtwork(input: ITunesArtworkProbeInput): Promise<ITunesArtworkProbeResult> {
  const startedAt = Date.now();
  const catalogID = appleMusicCatalogIDFromSonosValues(input.trackUri, input.albumArtUri);
  if (!isAppleMusicCandidate(input, catalogID)) {
    return {
      status: 'skipped',
      method: null,
      lookupStatus: 'skipped',
      searchStatus: 'skipped',
      url: null,
      catalogID,
      ms: Date.now() - startedAt,
    };
  }

  let lookupStatus: ITunesArtworkProbeStepStatus = catalogID ? 'miss' : 'skipped';
  let searchStatus: ITunesArtworkProbeStepStatus = shouldSearchITunes(input) ? 'miss' : 'skipped';
  let firstError: unknown;

  if (catalogID) {
    try {
      const lookupURL = await input.itunes.lookupArtworkURLString(catalogID, input.countryCode);
      if (isPublicArtworkURL(lookupURL)) {
        return {
          status: 'hit',
          method: 'lookup',
          lookupStatus: 'hit',
          searchStatus: 'skipped',
          url: lookupURL,
          catalogID,
          ms: Date.now() - startedAt,
        };
      }
      lookupStatus = 'miss';
    } catch (error) {
      lookupStatus = 'error';
      firstError = error;
    }
  }

  if (shouldSearchITunes(input)) {
    try {
      const searchURL = await input.itunes.searchArtworkURLString({
        kind: 'song',
        title: input.title?.trim() ?? '',
        artist: input.artist,
        album: input.album,
        countryCode: input.countryCode,
      });
      if (isPublicArtworkURL(searchURL)) {
        return {
          status: 'hit',
          method: 'search',
          lookupStatus,
          searchStatus: 'hit',
          url: searchURL,
          catalogID,
          ms: Date.now() - startedAt,
        };
      }
      searchStatus = 'miss';
    } catch (error) {
      searchStatus = 'error';
      firstError ??= error;
    }
  }

  const status: ITunesArtworkProbeStatus = lookupStatus === 'error' || searchStatus === 'error'
    ? 'error'
    : 'miss';
  return {
    status,
    method: null,
    lookupStatus,
    searchStatus,
    url: null,
    catalogID,
    ms: Date.now() - startedAt,
    ...(firstError ? { error: firstError } : {}),
  };
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

function logITunesArtworkProbe(
  logger: Pick<Logger, 'info' | 'warn'> | null,
  input: SonosArtworkResolveInput,
  result: ITunesArtworkProbeResult,
  message: string,
): void {
  if (!logger || result.status === 'skipped') return;

  const level = result.status === 'error' ? 'warn' : 'info';
  logger[level]({
    source: 'relay',
    action: 'itunes-artwork-shadow-probe',
    status: result.status,
    method: result.method,
    lookupStatus: result.lookupStatus,
    searchStatus: result.searchStatus,
    groupId: input.groupId ?? null,
    trigger: input.trigger ?? null,
    title: input.title ?? null,
    artist: input.artist ?? null,
    album: input.album ?? null,
    playbackSourceRaw: input.playbackSourceRaw ?? null,
    catalogID: result.catalogID,
    trackUri: summarizeArtworkLogValue(input.trackUri),
    getaaAlbumArtUri: summarizeArtworkLogValue(input.albumArtUri),
    resolvedAlbumArtUri: summarizeArtworkLogValue(result.url),
    ms: result.ms,
    ...(result.error ? { err: result.error } : {}),
  }, message);
}

function shouldUseITunesArtworkForLiveRadio(input: SonosArtworkResolveInput): boolean {
  if ((input.playbackSourceRaw ?? '').trim().toLowerCase() !== 'applemusic') return false;
  return isAppleMusicLiveRadioUri(input.trackUri) || isAppleMusicLiveRadioUri(input.albumArtUri);
}

function isAppleMusicLiveRadioUri(value: string | null | undefined): boolean {
  return sonosObjectCandidates(value)
    .map(candidate => decodeRepeated(candidate).toLowerCase())
    .some(candidate =>
      candidate.startsWith('x-sonosapi-hls:hls:ra.')
      || candidate.includes('u=x-sonosapi-hls:hls:ra.')
    );
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
    // Raw Sonos URIs are still candidates.
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

function isPublicArtworkURL(value: string | null | undefined): value is string {
  const trimmed = trimmedOrNull(value);
  if (!trimmed) return false;

  try {
    const url = new URL(trimmed);
    return url.protocol === 'http:' || url.protocol === 'https:';
  } catch {
    return false;
  }
}

function trimmedOrNull(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? '';
  return trimmed.length > 0 ? trimmed : null;
}

function isSonosGetAAArtworkURI(value: string | null | undefined): value is string {
  const trimmed = trimmedOrNull(value);
  if (!trimmed) return false;
  if (trimmed.startsWith('/getaa')) return true;

  try {
    const url = new URL(trimmed);
    return (url.protocol === 'http:' || url.protocol === 'https:')
      && url.pathname.toLowerCase().includes('/getaa');
  } catch {
    return false;
  }
}

function summarizeArtworkLogValue(value: string | null | undefined): string | null {
  if (!value) return null;
  if (value.length <= 140) return value;
  return `${value.slice(0, 110)}…${value.slice(-24)}`;
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
