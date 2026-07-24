import type { SonosGroupSnapshot } from '../types.js';

export function snapshotJson(snap: SonosGroupSnapshot): Record<string, unknown> {
  return {
    groupId: snap.groupId,
    speakerName: snap.speakerName,
    trackTitle: snap.trackTitle,
    artist: snap.artist,
    album: snap.album,
    trackUri: snap.trackUri ?? null,
    albumArtUri: snap.albumArtUri,
    albumArtFallbackUri: snap.albumArtFallbackUri ?? null,
    isPlaying: snap.isPlaying,
    transportStateRaw: snap.transportStateRaw ?? null,
    groupVolume: snap.groupVolume ?? null,
    playbackSourceRaw: snap.playbackSourceRaw ?? null,
    tvAudioFormatRawCode: snap.tvAudioFormatRawCode ?? null,
    tvAudioFormatLabel: snap.tvAudioFormatLabel ?? null,
    tvHasSignal: snap.tvHasSignal ?? null,
    audioQualityLabel: snap.audioQualityLabel ?? null,
    soundbarNightMode: snap.soundbarNightMode ?? null,
    soundbarSpeechEnhancementRawLevel: snap.soundbarSpeechEnhancementRawLevel ?? null,
    positionSeconds: snap.positionSeconds,
    durationSeconds: snap.durationSeconds,
    groupMemberCount: snap.groupMemberCount,
    groupMembers: snap.groupMembers ?? [],
    sampledAt: snap.sampledAt.toISOString(),
  };
}
