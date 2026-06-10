import type { SonosGroupSnapshot } from './types.js';

export interface LiveActivityHintRequest {
  groupId: string;
  trackTitle?: string | null;
  artist?: string | null;
  album?: string | null;
  playbackSourceRaw?: string | null;
  audioQualityLabel?: string | null;
  liveActivityStyleRaw?: string | null;
}

interface StoredLiveActivityHint extends LiveActivityHintRequest {
  updatedAt: number;
}

export interface LiveActivityHintApplyDiagnostic {
  hadHint: boolean;
  reason: 'no-hint' | 'expired' | 'mismatch' | 'applied';
  ageMs?: number;
  mismatches?: string[];
  snapshotTrackTitle?: string | null;
  snapshotArtist?: string | null;
  snapshotAlbum?: string | null;
  snapshotPlaybackSourceRaw?: string | null;
  snapshotAudioQualityLabel?: string | null;
  hintTrackTitle?: string | null;
  hintArtist?: string | null;
  hintAlbum?: string | null;
  hintPlaybackSourceRaw?: string | null;
  hintAudioQualityLabel?: string | null;
  appliedAudioQualityLabel?: string | null;
  appliedLiveActivityStyleRaw?: string | null;
}

export interface LiveActivityHintApplyResult {
  snapshot: SonosGroupSnapshot;
  diagnostic: LiveActivityHintApplyDiagnostic;
}

const DEFAULT_TTL_MS = 30 * 60 * 1000;

export class LiveActivityHintStore {
  private readonly hints = new Map<string, StoredLiveActivityHint>();

  constructor(
    private readonly now: () => number = () => Date.now(),
    private readonly ttlMs: number = DEFAULT_TTL_MS,
  ) {}

  update(request: LiveActivityHintRequest): void {
    const hint: StoredLiveActivityHint = {
      groupId: request.groupId,
      trackTitle: clean(request.trackTitle),
      artist: clean(request.artist),
      album: clean(request.album),
      playbackSourceRaw: clean(request.playbackSourceRaw),
      audioQualityLabel: clean(request.audioQualityLabel),
      liveActivityStyleRaw: clean(request.liveActivityStyleRaw),
      updatedAt: this.now(),
    };
    this.hints.set(request.groupId, hint);
  }

  apply(snapshot: SonosGroupSnapshot): SonosGroupSnapshot {
    return this.applyWithDiagnostics(snapshot).snapshot;
  }

  applyWithDiagnostics(snapshot: SonosGroupSnapshot): LiveActivityHintApplyResult {
    const hint = this.hints.get(snapshot.groupId);
    if (!hint) {
      return {
        snapshot,
        diagnostic: {
          hadHint: false,
          reason: 'no-hint',
          ...snapshotDiagnostic(snapshot),
        },
      };
    }

    const ageMs = this.now() - hint.updatedAt;
    if (ageMs > this.ttlMs) {
      this.hints.delete(snapshot.groupId);
      return {
        snapshot,
        diagnostic: {
          hadHint: true,
          reason: 'expired',
          ageMs,
          ...snapshotDiagnostic(snapshot),
          ...hintDiagnostic(hint),
        },
      };
    }

    const mismatches = mismatchedFields(hint, snapshot);
    if (mismatches.length > 0) {
      return {
        snapshot,
        diagnostic: {
          hadHint: true,
          reason: 'mismatch',
          ageMs,
          mismatches,
          ...snapshotDiagnostic(snapshot),
          ...hintDiagnostic(hint),
        },
      };
    }

    const appliedAudioQualityLabel = clean(snapshot.audioQualityLabel) ?? hint.audioQualityLabel ?? null;
    const appliedLiveActivityStyleRaw = clean(snapshot.liveActivityStyleRaw) ?? hint.liveActivityStyleRaw ?? null;
    const enrichedSnapshot = {
      ...snapshot,
      audioQualityLabel: appliedAudioQualityLabel,
      liveActivityStyleRaw: appliedLiveActivityStyleRaw,
    };

    return {
      snapshot: enrichedSnapshot,
      diagnostic: {
        hadHint: true,
        reason: 'applied',
        ageMs,
        ...snapshotDiagnostic(snapshot),
        ...hintDiagnostic(hint),
        appliedAudioQualityLabel,
        appliedLiveActivityStyleRaw,
      },
    };
  }
}

function mismatchedFields(hint: StoredLiveActivityHint, snapshot: SonosGroupSnapshot): string[] {
  const mismatches: string[] = [];
  if (!matchesField(hint.trackTitle, snapshot.trackTitle)) mismatches.push('trackTitle');
  if (!matchesField(hint.artist, snapshot.artist)) mismatches.push('artist');
  if (!matchesField(hint.album, snapshot.album)) mismatches.push('album');
  if (!matchesField(hint.playbackSourceRaw, snapshot.playbackSourceRaw)) mismatches.push('playbackSourceRaw');
  return mismatches;
}

function matchesField(expected: string | null | undefined, actual: string | null | undefined): boolean {
  if (!expected) return true;
  return normalize(expected) === normalize(actual);
}

function clean(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

function normalize(value: string | null | undefined): string {
  return clean(value)?.toLocaleLowerCase('en-US') ?? '';
}

function snapshotDiagnostic(snapshot: SonosGroupSnapshot) {
  return {
    snapshotTrackTitle: clean(snapshot.trackTitle),
    snapshotArtist: clean(snapshot.artist),
    snapshotAlbum: clean(snapshot.album),
    snapshotPlaybackSourceRaw: clean(snapshot.playbackSourceRaw),
    snapshotAudioQualityLabel: clean(snapshot.audioQualityLabel),
  };
}

function hintDiagnostic(hint: StoredLiveActivityHint) {
  return {
    hintTrackTitle: hint.trackTitle ?? null,
    hintArtist: hint.artist ?? null,
    hintAlbum: hint.album ?? null,
    hintPlaybackSourceRaw: hint.playbackSourceRaw ?? null,
    hintAudioQualityLabel: hint.audioQualityLabel ?? null,
  };
}
