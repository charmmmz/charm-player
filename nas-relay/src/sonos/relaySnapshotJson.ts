import type { SonosGroupSnapshot } from '../types.js';

export function snapshotJson(snap: SonosGroupSnapshot): Record<string, unknown> {
  return {
    groupId: snap.groupId,
    speakerName: snap.speakerName,
    trackTitle: snap.trackTitle,
    artist: snap.artist,
    album: snap.album,
    albumArtUri: snap.albumArtUri,
    albumArtFallbackUri: snap.albumArtFallbackUri ?? null,
    isPlaying: snap.isPlaying,
    groupVolume: snap.groupVolume ?? null,
    playbackSourceRaw: snap.playbackSourceRaw ?? null,
    audioQualityLabel: snap.audioQualityLabel ?? null,
    soundbarNightMode: snap.soundbarNightMode ?? null,
    soundbarSpeechEnhancementRawLevel: snap.soundbarSpeechEnhancementRawLevel ?? null,
    positionSeconds: snap.positionSeconds,
    durationSeconds: snap.durationSeconds,
    groupMemberCount: snap.groupMemberCount,
    sampledAt: snap.sampledAt.toISOString(),
  };
}
