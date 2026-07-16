import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  groupDisplayName,
  groupPlaybackSubtitle,
  groupPlaybackTitle,
  groupSourceState,
  isActivePlaybackGroup,
  isLiveStreamGroup,
  isTVGroup,
  transportState,
  tvAudioPresentation,
} from '../../public/dashboard/sonosPresentation.js';

test('dashboard compacts grouped room names using the coordinator and additional member count', () => {
  assert.equal(groupDisplayName({ speakerName: 'Playroom', groupMemberCount: 1 }), 'Playroom');
  assert.equal(groupDisplayName({ speakerName: 'Playroom', groupMemberCount: 2 }), 'Playroom + 1');
  assert.equal(groupDisplayName({ speakerName: 'Playroom', groupMemberCount: 4 }), 'Playroom + 3');
});

test('dashboard gives TV playback dedicated title, format, and live state presentation', () => {
  const group = {
    playbackSourceRaw: 'tv',
    trackTitle: 'TV',
    artist: 'Multichannel PCM · 5.1',
    audioQualityLabel: 'Dolby Atmos · MAT',
    tvAudioFormatLabel: 'Dolby Atmos (MAT 2.0)',
    tvHasSignal: true,
    durationSeconds: 0,
    isPlaying: true,
  };

  assert.equal(isTVGroup(group), true);
  assert.equal(isLiveStreamGroup(group), false);
  assert.equal(groupPlaybackTitle(group), 'TV');
  assert.equal(groupPlaybackSubtitle(group), 'Dolby Atmos · MAT');
  assert.equal(groupSourceState(group), 'LIVE');
  assert.equal(isActivePlaybackGroup(group), true);
  assert.deepEqual(tvAudioPresentation(group), {
    hasSignal: true,
    isAtmos: true,
    atmosVariant: 'MAT',
    codec: 'Dolby Atmos · MAT',
    channelLayout: '',
    label: 'Dolby Atmos · MAT',
  });
});

test('dashboard keeps a playing TV transport idle when HTAudioIn reports no audio', () => {
  const group = {
    playbackSourceRaw: 'tv',
    trackTitle: 'NOT_IMPLEMENTED',
    artist: 'Unknown',
    audioQualityLabel: 'PCM · 2.0',
    tvAudioFormatLabel: 'PCM 2.0 no audio',
    tvHasSignal: false,
    durationSeconds: 0,
    isPlaying: true,
  };

  assert.equal(groupPlaybackTitle(group), 'TV');
  assert.equal(groupPlaybackSubtitle(group), 'No signal');
  assert.equal(groupSourceState(group), 'IDLE');
  assert.equal(isActivePlaybackGroup(group), false);
  assert.equal(tvAudioPresentation(group).hasSignal, false);
});

test('dashboard splits non-Atmos TV codec and channel layout for the format chip', () => {
  const presentation = tvAudioPresentation({
    playbackSourceRaw: 'tv',
    audioQualityLabel: 'Multichannel PCM · 5.1',
    tvHasSignal: true,
    isPlaying: true,
  });

  assert.equal(presentation.codec, 'Multichannel PCM');
  assert.equal(presentation.channelLayout, '5.1');
  assert.equal(presentation.isAtmos, false);
});

test('dashboard trusts explicit TV signal state when the format label is ambiguous', () => {
  const group = {
    playbackSourceRaw: 'tv',
    audioQualityLabel: 'PCM · 2.0',
    tvAudioFormatLabel: 'PCM 2.0',
    tvHasSignal: false,
    isPlaying: true,
  };

  assert.equal(tvAudioPresentation(group).hasSignal, false);
  assert.equal(isActivePlaybackGroup(group), false);
  assert.equal(groupSourceState(group), 'IDLE');
});

test('dashboard treats durationless non-TV playback as a live stream', () => {
  const group = {
    playbackSourceRaw: 'radio',
    trackTitle: 'Apple Music 1',
    artist: 'Live Radio',
    durationSeconds: 0,
    isPlaying: true,
  };

  assert.equal(isTVGroup(group), false);
  assert.equal(isLiveStreamGroup(group), true);
  assert.equal(groupPlaybackTitle(group), 'Apple Music 1');
  assert.equal(groupPlaybackSubtitle(group, { compact: true }), 'Live Radio');
  assert.equal(groupSourceState(group), 'LIVE');
});

test('dashboard does not present an empty idle room as a live stream', () => {
  const group = {
    playbackSourceRaw: 'unknown',
    trackTitle: 'Unknown',
    artist: '',
    durationSeconds: 0,
    isPlaying: false,
  };

  assert.equal(isLiveStreamGroup(group), false);
  assert.equal(groupPlaybackTitle(group), 'Not playing');
  assert.equal(groupPlaybackSubtitle(group), 'Idle');
  assert.equal(groupSourceState(group), 'IDLE');
});

test('dashboard preserves paused, stopped, and transitioning transport states', () => {
  const base = {
    playbackSourceRaw: 'appleMusic',
    trackTitle: 'Heartless',
    durationSeconds: 198,
    isPlaying: false,
  };
  assert.equal(groupSourceState({ ...base, transportStateRaw: 'PAUSED_PLAYBACK' }), 'PAUSED');
  assert.equal(groupSourceState({ ...base, transportStateRaw: 'STOPPED' }), 'STOPPED');
  assert.equal(groupSourceState({ ...base, transportStateRaw: 'TRANSITIONING' }), 'TRANSITIONING');
  assert.equal(transportState({ ...base, isPlaying: true, transportStateRaw: null }), 'PLAYING');
});
