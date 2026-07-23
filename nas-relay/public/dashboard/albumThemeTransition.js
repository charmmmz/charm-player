export const ALBUM_THEME_TRANSITION_MS = 1400;

export function albumTransitionIdentity(group = {}) {
  const source = normalized(group.playbackSourceRaw) || 'unknown';
  const album = normalized(group.album);
  if (album) return `album:${source}:${album}`;
  const artwork = String(group.albumArtFallbackUri || group.albumArtUri || '').trim();
  if (artwork) return `artwork:${artwork}`;
  return `track:${source}:${normalized(group.trackTitle) || 'unknown'}`;
}

export function shouldAnimateAlbumThemeTransition(previousKey, nextKey, reducedMotion = false) {
  return !reducedMotion
    && typeof previousKey === 'string'
    && previousKey.length > 0
    && typeof nextKey === 'string'
    && nextKey.length > 0
    && previousKey !== nextKey;
}

function normalized(value) {
  return String(value ?? '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}
