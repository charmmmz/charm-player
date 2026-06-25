import type { SonosGroupSnapshot } from './types.js';

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
  updatedAt: number;
}

export class LiveActivityPreferenceStore {
  private readonly preferences = new Map<string, StoredLiveActivityPreferences>();

  constructor(private readonly now: () => number = () => Date.now()) {}

  update(request: LiveActivityPreferencesRequest): void {
    const existing = this.preferences.get(request.groupId);
    const updatedAt = this.now();
    const liveActivityStyleRaw = request.liveActivityStyleRaw === undefined
      ? existing?.liveActivityStyleRaw ?? null
      : clean(request.liveActivityStyleRaw);

    this.preferences.set(request.groupId, {
      groupId: request.groupId,
      liveActivityStyleRaw,
      updatedAt,
    });
  }

  apply(snapshot: SonosGroupSnapshot): SonosGroupSnapshot {
    const preference = this.preferences.get(snapshot.groupId);
    const liveActivityStyleRaw = clean(snapshot.liveActivityStyleRaw)
      ?? preference?.liveActivityStyleRaw
      ?? null;

    const next: SonosGroupSnapshot = {
      ...snapshot,
      liveActivityStyleRaw,
    };

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
