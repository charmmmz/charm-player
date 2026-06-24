import type { SonosGroupSnapshot } from './types.js';

const NOW_PLAYING_HINT_TTL_MS = 30_000;

export interface LiveActivityNowPlayingHint {
  trackTitle?: string | null;
  artist?: string | null;
  album?: string | null;
  albumArtUri?: string | null;
  isPlaying?: boolean | null;
  positionSeconds?: number | null;
  durationSeconds?: number | null;
  playbackSourceRaw?: string | null;
  audioQualityLabel?: string | null;
}

export interface LiveActivityPreferencesRequest {
  groupId: string;
  liveActivityStyleRaw?: string | null;
  nowPlaying?: LiveActivityNowPlayingHint | null;
}

interface StoredLiveActivityPreferences {
  groupId: string;
  liveActivityStyleRaw: string | null;
  nowPlaying: StoredLiveActivityNowPlayingHint | null;
  updatedAt: number;
}

interface StoredLiveActivityNowPlayingHint {
  trackTitle: string;
  artist: string | null;
  album: string | null;
  albumArtUri: string | null;
  isPlaying: boolean | null;
  positionSeconds: number | null;
  durationSeconds: number | null;
  playbackSourceRaw: string | null;
  audioQualityLabel: string | null;
  updatedAt: number;
}

export class LiveActivityPreferenceStore {
  private readonly preferences = new Map<string, StoredLiveActivityPreferences>();

  constructor(private readonly now: () => number = () => Date.now()) {}

  update(request: LiveActivityPreferencesRequest): void {
    const existing = this.preferences.get(request.groupId);
    const updatedAt = this.now();
    const nowPlaying = request.nowPlaying === undefined
      ? existing?.nowPlaying ?? null
      : cleanNowPlayingHint(request.nowPlaying, updatedAt);

    this.preferences.set(request.groupId, {
      groupId: request.groupId,
      liveActivityStyleRaw: clean(request.liveActivityStyleRaw),
      nowPlaying,
      updatedAt,
    });
  }

  apply(snapshot: SonosGroupSnapshot): SonosGroupSnapshot {
    const preference = this.preferences.get(snapshot.groupId);
    const liveActivityStyleRaw = clean(snapshot.liveActivityStyleRaw)
      ?? preference?.liveActivityStyleRaw
      ?? null;
    const nowPlaying = usableNowPlayingHint(preference?.nowPlaying ?? null, snapshot, this.now());

    const next: SonosGroupSnapshot = {
      ...snapshot,
      liveActivityStyleRaw,
    };
    if (nowPlaying) {
      next.trackTitle = nowPlaying.trackTitle;
      if (nowPlaying.artist !== null) next.artist = nowPlaying.artist;
      if (nowPlaying.album !== null) next.album = nowPlaying.album;
      if (nowPlaying.albumArtUri !== null) next.albumArtUri = nowPlaying.albumArtUri;
      if (nowPlaying.isPlaying !== null) next.isPlaying = nowPlaying.isPlaying;
      if (nowPlaying.positionSeconds !== null) next.positionSeconds = nowPlaying.positionSeconds;
      if (nowPlaying.durationSeconds !== null) next.durationSeconds = nowPlaying.durationSeconds;
      if (nowPlaying.playbackSourceRaw !== null) next.playbackSourceRaw = nowPlaying.playbackSourceRaw;
      if (nowPlaying.audioQualityLabel !== null) next.audioQualityLabel = nowPlaying.audioQualityLabel;
    }

    if (sameSnapshot(snapshot, next)) {
      return snapshot;
    }

    return next;
  }
}

function clean(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

function cleanNowPlayingHint(
  hint: LiveActivityNowPlayingHint | null | undefined,
  updatedAt: number,
): StoredLiveActivityNowPlayingHint | null {
  const trackTitle = clean(hint?.trackTitle);
  if (!trackTitle) {
    return null;
  }

  return {
    trackTitle,
    artist: clean(hint?.artist),
    album: clean(hint?.album),
    albumArtUri: clean(hint?.albumArtUri),
    isPlaying: typeof hint?.isPlaying === 'boolean' ? hint.isPlaying : null,
    positionSeconds: cleanSeconds(hint?.positionSeconds),
    durationSeconds: cleanSeconds(hint?.durationSeconds),
    playbackSourceRaw: clean(hint?.playbackSourceRaw),
    audioQualityLabel: clean(hint?.audioQualityLabel),
    updatedAt,
  };
}

function usableNowPlayingHint(
  hint: StoredLiveActivityNowPlayingHint | null,
  snapshot: SonosGroupSnapshot,
  now: number,
): StoredLiveActivityNowPlayingHint | null {
  if (!hint) {
    return null;
  }
  if (now - hint.updatedAt > NOW_PLAYING_HINT_TTL_MS) {
    return null;
  }
  if (!isLiveSnapshot(snapshot)) {
    return null;
  }
  return hint;
}

function isLiveSnapshot(snapshot: SonosGroupSnapshot): boolean {
  return cleanSeconds(snapshot.durationSeconds) === 0;
}

function cleanSeconds(value: number | null | undefined): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return null;
  }
  return Math.max(0, value);
}

function sameSnapshot(lhs: SonosGroupSnapshot, rhs: SonosGroupSnapshot): boolean {
  return lhs.trackTitle === rhs.trackTitle
    && lhs.artist === rhs.artist
    && lhs.album === rhs.album
    && (lhs.albumArtUri ?? null) === (rhs.albumArtUri ?? null)
    && lhs.isPlaying === rhs.isPlaying
    && lhs.positionSeconds === rhs.positionSeconds
    && lhs.durationSeconds === rhs.durationSeconds
    && (lhs.playbackSourceRaw ?? null) === (rhs.playbackSourceRaw ?? null)
    && (lhs.audioQualityLabel ?? null) === (rhs.audioQualityLabel ?? null)
    && (lhs.liveActivityStyleRaw ?? null) === (rhs.liveActivityStyleRaw ?? null);
}
