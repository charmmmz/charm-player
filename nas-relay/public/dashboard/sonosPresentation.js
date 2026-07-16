function normalizedSource(group) {
  return String(group?.playbackSourceRaw ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');
}

function displayableText(value) {
  const text = String(value ?? '').trim();
  if (!text || ['unknown', 'not playing', 'idle', 'not_implemented', 'not implemented', '—', '-'].includes(text.toLowerCase())) return '';
  return text;
}

export function isTVGroup(group) {
  return normalizedSource(group) === 'tv';
}

export function isActivePlaybackGroup(group) {
  return isTVGroup(group) ? tvAudioPresentation(group).hasSignal : isGroupPlaying(group);
}

export function tvAudioPresentation(group) {
  const fullLabel = displayableText(group?.tvAudioFormatLabel);
  const compactLabel = displayableText(group?.audioQualityLabel);
  const label = compactLabel || fullLabel;
  const explicitSignal = typeof group?.tvHasSignal === 'boolean'
    ? group.tvHasSignal
    : null;
  const noSignalLabel = /\b(no input|no audio|no signal)\b/i.test(fullLabel || label);
  const hasSignal = explicitSignal ?? (label ? !noSignalLabel : group?.isPlaying === true);
  const isAtmos = /dolby atmos/i.test(label);
  const atmosVariant = isAtmos
    ? (/truehd/i.test(label) ? 'TrueHD' : (/dd\+/i.test(label) ? 'DD+' : (/mat(?:\s*2\.0)?/i.test(label) ? 'MAT' : '')))
    : '';
  const channelLayout = isAtmos ? '' : label.match(/\b(?:7\.1|5\.1|2\.0)\b/)?.[0] ?? '';
  let codec = label;
  if (channelLayout) {
    codec = codec
      .replace(new RegExp(`\\s*[·(]?\\s*${channelLayout.replace('.', '\\.')}\\)?\\s*$`), '')
      .trim();
  }
  if (!hasSignal) codec = '';

  return {
    hasSignal,
    isAtmos,
    atmosVariant,
    codec,
    channelLayout,
    label: hasSignal ? (label || 'Live audio') : 'No signal',
  };
}

export function isLiveStreamGroup(group) {
  if (isTVGroup(group) || Number(group?.durationSeconds ?? 0) > 0) return false;
  const source = normalizedSource(group);
  const title = displayableText(group?.trackTitle);
  return isGroupPlaying(group)
    || (source !== '' && source !== 'unknown')
    || (title !== '' && title.toLowerCase() !== 'idle');
}

export function transportState(group) {
  const raw = String(group?.transportStateRaw ?? '').trim().toUpperCase();
  if (raw) return raw;
  return group?.isPlaying ? 'PLAYING' : 'STOPPED';
}

export function isGroupPlaying(group) {
  return transportState(group) === 'PLAYING';
}

export function groupDisplayName(group) {
  const coordinator = displayableText(group?.speakerName) || 'Unknown room';
  const memberCount = Math.max(1, Number(group?.groupMemberCount ?? 1));
  return memberCount > 1 ? `${coordinator} + ${memberCount - 1}` : coordinator;
}

export function groupPlaybackTitle(group) {
  if (isTVGroup(group)) {
    const title = displayableText(group?.trackTitle);
    return !title || title.toLowerCase() === 'tv' ? 'TV' : title;
  }
  return displayableText(group?.trackTitle) || 'Not playing';
}

export function groupPlaybackSubtitle(group, options = {}) {
  if (isTVGroup(group)) {
    const presentation = tvAudioPresentation(group);
    return presentation.hasSignal
      ? (presentation.label || displayableText(group?.artist) || 'Live audio')
      : 'No signal';
  }

  const artist = displayableText(group?.artist);
  const album = displayableText(group?.album);
  const separator = options.compact ? ' — ' : ' · ';
  return [artist, album].filter(Boolean).join(separator)
    || (isGroupPlaying(group) ? 'Live audio' : 'Idle');
}

export function groupSourceState(group) {
  if (isTVGroup(group)) return tvAudioPresentation(group).hasSignal ? 'LIVE' : 'IDLE';
  const state = transportState(group);
  if (state === 'TRANSITIONING') return 'TRANSITIONING';
  if (isLiveStreamGroup(group)) return state === 'PLAYING' ? 'LIVE' : 'STOPPED';
  if (groupPlaybackTitle(group) === 'Not playing') return 'IDLE';
  if (state === 'PLAYING') return 'PLAYING';
  if (state === 'PAUSED_PLAYBACK' || state === 'PAUSED') return 'PAUSED';
  if (state === 'NO_MEDIA_PRESENT' || state === 'NO_MEDIA' || state === 'STOPPED') return 'STOPPED';
  return state || 'IDLE';
}
