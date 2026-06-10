import crypto from 'node:crypto';
import jpeg from 'jpeg-js';
import { PNG } from 'pngjs';

import { fetchAlbumArt as defaultFetchAlbumArt } from './hueAlbumArtPalette.js';
import type { LiveActivityContentState, SonosGroupSnapshot } from './types.js';

const THUMBNAIL_SIZE = 60;
const THUMBNAIL_JPEG_QUALITY = 65;
const MAX_THUMBNAIL_BYTES = 15 * 1024;
const MAX_THUMBNAIL_CACHE_ENTRIES = 50;
const albumArtCache = new Map<string, AlbumArtPresentation>();

export interface LiveActivityContentStateDependencies {
  fetchAlbumArt?: (uri: string) => Promise<Buffer>;
}

interface DecodedImage {
  width: number;
  height: number;
  data: Uint8Array;
}

interface AlbumArtPresentation {
  thumbnailBase64: string | null;
  dominantColorHex: string | null;
}

export async function buildLiveActivityContentState(
  snap: SonosGroupSnapshot,
  dependencies: LiveActivityContentStateDependencies = {},
): Promise<LiveActivityContentState> {
  const sampledUnix = snap.sampledAt.getTime() / 1000;
  const startedAtUnix = snap.isPlaying && snap.durationSeconds > 0
    ? sampledUnix - snap.positionSeconds
    : null;
  const endsAtUnix = snap.isPlaying && snap.durationSeconds > 0
    ? sampledUnix + (snap.durationSeconds - snap.positionSeconds)
    : null;
  const albumArt = await albumArtPresentation(snap.albumArtUri, dependencies);

  return {
    trackTitle: snap.trackTitle || 'Not Playing',
    artist: snap.artist || '-',
    album: snap.album,
    isPlaying: snap.isPlaying,
    positionSeconds: snap.positionSeconds,
    durationSeconds: snap.durationSeconds,
    dominantColorHex: albumArt.dominantColorHex,
    startedAt: startedAtUnix !== null ? toSwiftDate(startedAtUnix) : null,
    endsAt: endsAtUnix !== null ? toSwiftDate(endsAtUnix) : null,
    albumArtThumbnail: albumArt.thumbnailBase64,
    groupMemberCount: snap.groupMemberCount,
    playbackSourceRaw: snap.playbackSourceRaw ?? null,
    soundbarNightMode: snap.soundbarNightMode ?? null,
    soundbarSpeechEnhancementRawLevel: snap.soundbarSpeechEnhancementRawLevel ?? null,
    liveActivityStyleRaw: snap.liveActivityStyleRaw ?? null,
    audioQualityLabel: snap.audioQualityLabel ?? null,
  };
}

export function hashLiveActivityContentState(state: LiveActivityContentState): string {
  // Hash only the user-visible fields; ignore startedAt/endsAt drift since
  // those move on every poll even when playback is unchanged.
  const projection = {
    t: state.trackTitle,
    a: state.artist,
    al: state.album,
    p: state.isPlaying,
    d: state.durationSeconds,
    s: state.playbackSourceRaw,
    art: state.albumArtThumbnail,
    c: state.dominantColorHex,
    n: state.soundbarNightMode,
    se: state.soundbarSpeechEnhancementRawLevel,
    sty: state.liveActivityStyleRaw,
    q: state.audioQualityLabel,
  };
  return crypto
    .createHash('sha256')
    .update(JSON.stringify(projection))
    .digest('hex')
    .slice(0, 16);
}

async function albumArtPresentation(
  albumArtUri: string | null | undefined,
  dependencies: LiveActivityContentStateDependencies,
): Promise<AlbumArtPresentation> {
  if (!albumArtUri) return { thumbnailBase64: null, dominantColorHex: null };

  const useCache = dependencies.fetchAlbumArt === undefined;
  if (useCache && albumArtCache.has(albumArtUri)) {
    return albumArtCache.get(albumArtUri)!;
  }

  try {
    const imageData = await (dependencies.fetchAlbumArt ?? defaultFetchAlbumArt)(albumArtUri);
    const image = decodeImage(imageData);
    const presentation = {
      thumbnailBase64: makeJpegThumbnailBase64(image),
      dominantColorHex: dominantColorHex(image),
    };
    if (useCache) rememberAlbumArt(albumArtUri, presentation);
    return presentation;
  } catch {
    return { thumbnailBase64: null, dominantColorHex: null };
  }
}

function rememberAlbumArt(albumArtUri: string, presentation: AlbumArtPresentation): void {
  albumArtCache.set(albumArtUri, presentation);
  while (albumArtCache.size > MAX_THUMBNAIL_CACHE_ENTRIES) {
    const oldest = albumArtCache.keys().next().value;
    if (oldest === undefined) return;
    albumArtCache.delete(oldest);
  }
}

function makeJpegThumbnailBase64(image: DecodedImage): string {
  const sourceSide = Math.max(1, Math.min(image.width, image.height));
  const sourceX = Math.floor((image.width - sourceSide) / 2);
  const sourceY = Math.floor((image.height - sourceSide) / 2);
  const target = Buffer.alloc(THUMBNAIL_SIZE * THUMBNAIL_SIZE * 4);

  for (let y = 0; y < THUMBNAIL_SIZE; y += 1) {
    const sy = sourceY + Math.min(sourceSide - 1, Math.floor(((y + 0.5) / THUMBNAIL_SIZE) * sourceSide));
    for (let x = 0; x < THUMBNAIL_SIZE; x += 1) {
      const sx = sourceX + Math.min(sourceSide - 1, Math.floor(((x + 0.5) / THUMBNAIL_SIZE) * sourceSide));
      const sourceIndex = (sy * image.width + sx) * 4;
      const targetIndex = (y * THUMBNAIL_SIZE + x) * 4;
      const alpha = image.data[sourceIndex + 3]! / 255;
      target[targetIndex] = compositeOverBlack(image.data[sourceIndex]!, alpha);
      target[targetIndex + 1] = compositeOverBlack(image.data[sourceIndex + 1]!, alpha);
      target[targetIndex + 2] = compositeOverBlack(image.data[sourceIndex + 2]!, alpha);
      target[targetIndex + 3] = 255;
    }
  }

  const encoded = jpeg.encode(
    { width: THUMBNAIL_SIZE, height: THUMBNAIL_SIZE, data: target },
    THUMBNAIL_JPEG_QUALITY,
  );
  if (encoded.data.length > MAX_THUMBNAIL_BYTES) {
    throw new Error('Live Activity album art thumbnail is too large');
  }
  return encoded.data.toString('base64');
}

function dominantColorHex(image: DecodedImage): string | null {
  let bestColor: RGBColor | null = null;
  let bestScore = -1;
  const size = 16;

  for (let y = 0; y < size; y += 1) {
    const sy = Math.min(image.height - 1, Math.floor(((y + 0.5) / size) * image.height));
    for (let x = 0; x < size; x += 1) {
      const sx = Math.min(image.width - 1, Math.floor(((x + 0.5) / size) * image.width));
      const index = (sy * image.width + sx) * 4;
      const alpha = image.data[index + 3]! / 255;
      if (alpha <= 0.1) continue;

      const color = {
        r: (image.data[index]! / 255) * alpha,
        g: (image.data[index + 1]! / 255) * alpha,
        b: (image.data[index + 2]! / 255) * alpha,
      };
      const score = darkBackgroundScore(color);
      if (score > bestScore) {
        bestScore = score;
        bestColor = color;
      }
    }
  }

  return bestColor ? rgbToHex(boostForDarkBackground(bestColor)) : null;
}

function decodeImage(data: Buffer): DecodedImage {
  if (isPng(data)) {
    const png = PNG.sync.read(data);
    return { width: png.width, height: png.height, data: png.data };
  }
  if (isJpeg(data)) {
    const decoded = jpeg.decode(data, { useTArray: true });
    return { width: decoded.width, height: decoded.height, data: decoded.data };
  }
  throw new Error('Unsupported album art image format');
}

function compositeOverBlack(channel: number, alpha: number): number {
  return Math.round(channel * alpha);
}

interface RGBColor {
  r: number;
  g: number;
  b: number;
}

function darkBackgroundScore(color: RGBColor): number {
  const maxC = Math.max(color.r, color.g, color.b);
  const minC = Math.min(color.r, color.g, color.b);
  const delta = maxC - minC;
  const lightness = (maxC + minC) / 2;
  const saturation = delta < 0.001 ? 0 : delta / (1 - Math.abs(2 * lightness - 1));

  return saturation * 3
    + (1 - Math.abs(lightness - 0.60)) * 0.8
    - (lightness < 0.15 ? 3 : 0)
    - (lightness > 0.92 ? 2 : 0);
}

function boostForDarkBackground(color: RGBColor): RGBColor {
  const maxC = Math.max(color.r, color.g, color.b);
  const minC = Math.min(color.r, color.g, color.b);
  const delta = maxC - minC;
  let h = 0;
  let s = 0;
  const l = (maxC + minC) / 2;

  if (delta > 0.001) {
    s = delta / (1 - Math.abs(2 * l - 1));
    switch (maxC) {
      case color.r:
        h = ((color.g - color.b) / delta) % 6;
        break;
      case color.g:
        h = (color.b - color.r) / delta + 2;
        break;
      default:
        h = (color.r - color.g) / delta + 4;
        break;
    }
    h = (h / 6) % 1;
    if (h < 0) h += 1;
  }

  const clampedLightness = Math.min(Math.max(l, 0.60), 0.88);
  const boostedSaturation = Math.min(Math.max(s, 0.55), 1);
  return hslToRgb(h, boostedSaturation, clampedLightness);
}

function hslToRgb(h: number, s: number, l: number): RGBColor {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h * 6) % 2) - 1));
  const m = l - c / 2;
  let r1 = 0;
  let g1 = 0;
  let b1 = 0;

  switch (Math.floor(h * 6) % 6) {
    case 0:
      r1 = c; g1 = x;
      break;
    case 1:
      r1 = x; g1 = c;
      break;
    case 2:
      g1 = c; b1 = x;
      break;
    case 3:
      g1 = x; b1 = c;
      break;
    case 4:
      r1 = x; b1 = c;
      break;
    default:
      r1 = c; b1 = x;
      break;
  }

  return { r: r1 + m, g: g1 + m, b: b1 + m };
}

function rgbToHex(color: RGBColor): string {
  return `#${hexByte(color.r)}${hexByte(color.g)}${hexByte(color.b)}`;
}

function hexByte(value: number): string {
  const byte = Math.floor(Math.min(Math.max(value, 0), 1) * 255);
  return byte.toString(16).padStart(2, '0').toUpperCase();
}

function isPng(data: Buffer): boolean {
  return data.length >= 8
    && data[0] === 0x89
    && data[1] === 0x50
    && data[2] === 0x4e
    && data[3] === 0x47;
}

function isJpeg(data: Buffer): boolean {
  return data.length >= 3 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff;
}

function toSwiftDate(unixSeconds: number): number {
  return unixSeconds - 978307200;
}
