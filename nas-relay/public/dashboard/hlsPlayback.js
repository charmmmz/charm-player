export function selectAnimatedArtworkPlayback(hlsJsSupported, nativeHlsSupported) {
  if (hlsJsSupported) return 'hls-js';
  if (nativeHlsSupported) return 'native';
  return 'unsupported';
}
