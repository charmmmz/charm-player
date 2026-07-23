import { createHash, randomUUID } from 'node:crypto';

import type {
  NowPlayingAttributes,
  NowPlayingTokenKind,
  NowPlayingTokenEntry,
  SonosGroupSnapshot,
} from '../types.js';

export function shouldSendNowPlayingStart(
  kind: NowPlayingTokenKind,
  _alreadyRegistered: boolean,
  requestStart: boolean,
): boolean {
  return kind === 'start' && requestStart;
}

export function isNowPlayingActive(snap: SonosGroupSnapshot): boolean {
  if (!snap.trackTitle.trim()) return false;
  const state = snap.transportStateRaw?.trim().toUpperCase() ?? '';
  return snap.isPlaying || state === 'PAUSED_PLAYBACK' || state === 'TRANSITIONING';
}

export function buildNowPlayingAttributes(
  snap: SonosGroupSnapshot,
  target: NowPlayingTokenEntry,
  animatedArtworkURLString: string | null = null,
  sessionGeneration: string | null = null,
): NowPlayingAttributes {
  const duration = Math.max(0, finite(snap.durationSeconds));
  const elapsedTime = Math.min(
    Math.max(0, finite(snap.positionSeconds)),
    duration > 0 ? duration : Number.MAX_SAFE_INTEGER,
  );
  const artwork = nowPlayingArtworkURLs(snap, target.relayURLString);

  return {
    id: target.sessionId || `sonos:${snap.groupId}`,
    ...(sessionGeneration ? { sessionGeneration } : {}),
    groupID: snap.groupId,
    speakerName: snap.speakerName || target.speakerName,
    devices: nowPlayingDevices(snap),
    trackID: snap.trackUri?.trim()
      || [snap.trackTitle, snap.artist, snap.album].join('|'),
    title: snap.trackTitle,
    artist: snap.artist,
    album: snap.album,
    ...(artwork.primary ? { artworkURLString: artwork.primary } : {}),
    ...(artwork.fallback ? { artworkFallbackURLString: artwork.fallback } : {}),
    ...(animatedArtworkURLString ? { animatedArtworkURLString } : {}),
    isLiveStream: isLiveStream(snap),
    isPlaying: snap.isPlaying,
    elapsedTime,
    duration,
    timestamp: snap.sampledAt.getTime() / 1000,
    volume: Math.min(Math.max(finite(snap.groupVolume ?? 0) / 100, 0), 1),
    clientID: target.clientId,
    relayURLString: target.relayURLString,
    relayCommandToken: target.token,
  };
}

export class NowPlayingSessionGenerationRegistry {
  private readonly generations = new Map<string, string>();
  private readonly makeGeneration: () => string;

  constructor(makeGeneration: () => string = randomUUID) {
    this.makeGeneration = makeGeneration;
  }

  active(groupId: string, persistedEntries: NowPlayingTokenEntry[] = []): string {
    const current = this.current(groupId, persistedEntries);
    if (current) return current;
    const generation = this.makeGeneration();
    this.generations.set(groupId, generation);
    return generation;
  }

  current(groupId: string, persistedEntries: NowPlayingTokenEntry[] = []): string | null {
    const memory = this.generations.get(groupId);
    if (memory) return memory;
    // The start token describes the app's intended active system session.
    // Prefer it when recovering persisted state so a stale update token from a
    // pre-reboot representation cannot become authoritative.
    const persisted = persistedEntries.find(
      entry => entry.kind === 'start' && entry.sessionGeneration,
    )?.sessionGeneration
      ?? persistedEntries.find(entry => entry.sessionGeneration)?.sessionGeneration;
    if (!persisted) return null;
    this.generations.set(groupId, persisted);
    return persisted;
  }

  adopt(groupId: string, generation: string): void {
    this.generations.set(groupId, generation);
  }

  rotate(groupId: string): string {
    const generation = this.makeGeneration();
    this.generations.set(groupId, generation);
    return generation;
  }

  end(groupId: string): void {
    this.generations.delete(groupId);
  }
}

function nowPlayingDevices(snap: SonosGroupSnapshot): NonNullable<NowPlayingAttributes['devices']> {
  const members = snap.groupMembers ?? [];
  if (members.length === 0) {
    return [{
      id: snap.groupId,
      name: snap.speakerName,
      host: snap.groupId,
      volume: normalizedVolume(snap.groupVolume),
    }];
  }

  return members.map(member => ({
    id: member.id || member.host,
    name: member.name,
    ...(member.host ? { host: member.host } : {}),
    ...(member.volume == null ? {} : { volume: normalizedVolume(member.volume) }),
  }));
}

function normalizedVolume(volume: number | null | undefined): number {
  return Math.min(Math.max(finite(volume ?? 0) / 100, 0), 1);
}

export function hashNowPlayingAttributes(attributes: NowPlayingAttributes): string {
  const significant = {
    ...attributes,
    elapsedTime: 0,
    timestamp: 0,
  };
  return createHash('sha256').update(JSON.stringify(significant)).digest('hex');
}

export function nowPlayingArtworkURLs(
  snap: Pick<SonosGroupSnapshot, 'albumArtUri' | 'albumArtFallbackUri'>,
  relayURLString: string,
): { primary: string | null; fallback: string | null } {
  const raw = uniqueURLs([snap.albumArtFallbackUri, snap.albumArtUri]);
  const publicArtwork = raw.find(isPublicHTTPSArtwork) ?? null;
  const highResolutionPublicArtwork = publicArtwork
    ? highResolutionArtworkURL(publicArtwork)
    : null;
  const sonosArtwork = raw.find(value => !isPublicHTTPSArtwork(value)) ?? null;
  const proxiedSonosArtwork = sonosArtwork
    ? artworkProxyURL(relayURLString, sonosArtwork)
    : null;

  if (publicArtwork) {
    return { primary: highResolutionPublicArtwork, fallback: proxiedSonosArtwork };
  }
  if (proxiedSonosArtwork) {
    return { primary: proxiedSonosArtwork, fallback: sonosArtwork };
  }
  return { primary: raw[0] ?? null, fallback: raw[1] ?? null };
}

function highResolutionArtworkURL(value: string): string {
  try {
    const url = new URL(value);
    if (!url.hostname.toLowerCase().endsWith('mzstatic.com')) return value;
    url.pathname = url.pathname.replace(/\/\d+x\d+bb(?=\.[a-z0-9]+$)/i, '/1200x1200bb');
    return url.toString();
  } catch {
    return value;
  }
}

function artworkProxyURL(relayURLString: string, sourceURLString: string): string | null {
  try {
    const base = new URL(relayURLString);
    const endpoint = new URL('/api/artwork', base);
    endpoint.searchParams.set('url', sourceURLString);
    return endpoint.toString();
  } catch {
    return null;
  }
}

function uniqueURLs(values: Array<string | null | undefined>): string[] {
  const result: string[] = [];
  for (const value of values) {
    const clean = value?.trim();
    if (!clean || result.includes(clean)) continue;
    try {
      const url = new URL(clean);
      if (url.protocol !== 'http:' && url.protocol !== 'https:') continue;
      result.push(url.toString());
    } catch {
      // Ignore malformed Sonos metadata instead of poisoning the media session.
    }
  }
  return result;
}

function isPublicHTTPSArtwork(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !isPrivateHost(url.hostname);
  } catch {
    return false;
  }
}

function isPrivateHost(hostname: string): boolean {
  const host = hostname.toLowerCase();
  if (host === 'localhost' || host.endsWith('.local')) return true;
  if (/^10\./.test(host) || /^192\.168\./.test(host)) return true;
  const match = host.match(/^172\.(\d+)\./);
  return match ? Number(match[1]) >= 16 && Number(match[1]) <= 31 : false;
}

function isLiveStream(snap: SonosGroupSnapshot): boolean {
  if (snap.durationSeconds <= 0) return true;
  const uri = snap.trackUri?.toLowerCase() ?? '';
  return uri.startsWith('x-sonosapi-stream:') || uri.startsWith('x-sonosapi-hls:');
}

function finite(value: number): number {
  return Number.isFinite(value) ? value : 0;
}
