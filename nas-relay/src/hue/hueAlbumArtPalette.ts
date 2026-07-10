import jpeg from 'jpeg-js';
import { PNG } from 'pngjs';

import { fetchAlbumArt as defaultFetchAlbumArt } from '../artwork/albumArtFetchCache.js';
import { stablePaletteForTrack } from './huePalette.js';
import type { HueRGBColor, HueSnapshot } from './hueTypes.js';
export { fetchAlbumArt } from '../artwork/albumArtFetchCache.js';

const SAMPLE_SIZE = 24;
const MAX_PALETTE_COLORS = 5;

export interface HueAlbumArtPaletteDependencies {
  fetchAlbumArt?: (uri: string) => Promise<Buffer>;
  extractPalette?: (data: Buffer) => Promise<HueRGBColor[]> | HueRGBColor[];
}

interface DecodedImage {
  width: number;
  height: number;
  data: Uint8Array;
}

interface AmbienceColorProfile {
  maxColors: number;
  minUsefulBrightness: number;
  minUsefulSaturation: number;
  minReadableBrightness: number;
  maxReadableBrightness: number;
  maxSaturation: number;
  minLightness: number;
  maxLightness: number;
  deduplicateDistance: number;
}

const STANDARD_AMBIENCE_PROFILE: AmbienceColorProfile = {
  maxColors: MAX_PALETTE_COLORS,
  minUsefulBrightness: 0.14,
  minUsefulSaturation: 0.22,
  minReadableBrightness: 0.3,
  maxReadableBrightness: 0.82,
  maxSaturation: 0.58,
  minLightness: 0.24,
  maxLightness: 0.68,
  deduplicateDistance: 0.28,
};

const DARK_COVER_AMBIENCE_PROFILE: AmbienceColorProfile = {
  maxColors: 4,
  minUsefulBrightness: 0.11,
  minUsefulSaturation: 0.25,
  minReadableBrightness: 0.22,
  maxReadableBrightness: 0.62,
  maxSaturation: 0.82,
  minLightness: 0.2,
  maxLightness: 0.42,
  deduplicateDistance: 0.31,
};

export async function paletteForSnapshot(
  snapshot: HueSnapshot,
  dependencies: HueAlbumArtPaletteDependencies = {},
): Promise<HueRGBColor[]> {
  const fallback = constrainAmbiencePalette(stablePaletteForTrack(
    snapshot.trackTitle,
    snapshot.artist,
    snapshot.album,
    snapshot.albumArtUri ?? '',
  ));

  if (!snapshot.albumArtUri) {
    return fallback;
  }

  try {
    const imageData = await (dependencies.fetchAlbumArt ?? defaultFetchAlbumArt)(snapshot.albumArtUri);
    const extractedPalette = await (dependencies.extractPalette ?? paletteFromAlbumArtBuffer)(imageData);
    const palette = dependencies.extractPalette
      ? constrainAmbiencePalette(extractedPalette)
      : extractedPalette;
    return palette.length > 0 ? palette : fallback;
  } catch {
    return fallback;
  }
}

export function paletteFromAlbumArtBuffer(data: Buffer): HueRGBColor[] {
  const colors = sampleImageColors(decodeImage(data));
  const palette = extractPaletteFromColors(colors);
  return palette.length > 0 ? palette : fallbackPaletteFromAlbumColors(colors);
}

export function extractPaletteFromColors(
  colors: HueRGBColor[],
  maxColors = MAX_PALETTE_COLORS,
): HueRGBColor[] {
  const profile = ambienceColorProfile(colors);
  const colorLimit = Math.max(0, Math.min(maxColors, profile.maxColors));
  if (colorLimit === 0) return [];

  const buckets = new Map<string, ColorBucket>();
  for (const color of colors) {
    if (!isUsefulAlbumColor(color, profile)) continue;
    const key = bucketKey(color);
    const bucket = buckets.get(key) ?? new ColorBucket();
    bucket.add(color);
    buckets.set(key, bucket);
  }

  const palette: HueRGBColor[] = [];
  for (const bucket of Array.from(buckets.values()).sort((a, b) => b.score - a.score)) {
    const color = constrainAmbienceColor(bucket.averageColor, profile);
    if (palette.some(existing => distance(existing, color) < profile.deduplicateDistance)) continue;
    palette.push(color);
    if (palette.length === colorLimit) return palette;
  }

  return palette;
}

function decodeImage(data: Buffer): DecodedImage {
  if (isPng(data)) {
    const png = PNG.sync.read(data);
    return { width: png.width, height: png.height, data: png.data };
  }
  if (isJpeg(data)) {
    const jpegImage = jpeg.decode(data, { useTArray: true });
    return { width: jpegImage.width, height: jpegImage.height, data: jpegImage.data };
  }
  throw new Error('Unsupported album art image format');
}

function sampleImageColors(image: DecodedImage): HueRGBColor[] {
  const width = Math.max(image.width, 1);
  const height = Math.max(image.height, 1);
  const colors: HueRGBColor[] = [];

  for (let y = 0; y < SAMPLE_SIZE; y += 1) {
    const sourceY = Math.min(height - 1, Math.floor(((y + 0.5) / SAMPLE_SIZE) * height));
    for (let x = 0; x < SAMPLE_SIZE; x += 1) {
      const sourceX = Math.min(width - 1, Math.floor(((x + 0.5) / SAMPLE_SIZE) * width));
      const index = (sourceY * width + sourceX) * 4;
      const alpha = image.data[index + 3]! / 255;
      if (alpha <= 0.1) continue;
      colors.push({
        r: image.data[index]! / 255,
        g: image.data[index + 1]! / 255,
        b: image.data[index + 2]! / 255,
      });
    }
  }

  return colors;
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

function bucketKey(color: HueRGBColor): string {
  return [
    Math.round(color.r * 5),
    Math.round(color.g * 5),
    Math.round(color.b * 5),
  ].join(':');
}

class ColorBucket {
  private rTotal = 0;
  private gTotal = 0;
  private bTotal = 0;
  private saturationTotal = 0;
  private count = 0;

  add(color: HueRGBColor): void {
    this.rTotal += color.r;
    this.gTotal += color.g;
    this.bTotal += color.b;
    this.saturationTotal += saturation(color);
    this.count += 1;
  }

  get averageColor(): HueRGBColor {
    if (this.count === 0) return { r: 0, g: 0, b: 0 };
    return {
      r: this.rTotal / this.count,
      g: this.gTotal / this.count,
      b: this.bTotal / this.count,
    };
  }

  get score(): number {
    return this.count
      * Math.max(this.saturationTotal / Math.max(this.count, 1), 0.1)
      * Math.max(brightness(this.averageColor), 0.1);
  }
}

function ambienceColorProfile(colors: HueRGBColor[]): AmbienceColorProfile {
  if (colors.length === 0) return STANDARD_AMBIENCE_PROFILE;

  const darkRatio = colors.filter(color => brightness(color) < 0.16).length / colors.length;
  const vividRatio = colors.filter(color =>
    brightness(color) >= 0.3 && saturation(color) >= 0.45
  ).length / colors.length;

  return darkRatio >= 0.45 && vividRatio >= 0.05
    ? DARK_COVER_AMBIENCE_PROFILE
    : STANDARD_AMBIENCE_PROFILE;
}

function isUsefulAlbumColor(color: HueRGBColor, profile: AmbienceColorProfile): boolean {
  return brightness(color) >= profile.minUsefulBrightness
    && saturation(color) >= profile.minUsefulSaturation;
}

function saturation(color: HueRGBColor): number {
  const maxComponent = brightness(color);
  const minComponent = Math.min(color.r, color.g, color.b);
  if (maxComponent <= 0) return 0;
  return (maxComponent - minComponent) / maxComponent;
}

function brightness(color: HueRGBColor): number {
  return Math.max(color.r, color.g, color.b);
}

function distance(a: HueRGBColor, b: HueRGBColor): number {
  const rDelta = a.r - b.r;
  const gDelta = a.g - b.g;
  const bDelta = a.b - b.b;
  return Math.sqrt(rDelta * rDelta + gDelta * gDelta + bDelta * bDelta);
}

function fallbackPaletteFromAlbumColors(colors: HueRGBColor[]): HueRGBColor[] {
  if (colors.length === 0) return [];
  const profile = ambienceColorProfile(colors);

  const total = colors.reduce(
    (sum, color) => ({
      r: sum.r + color.r,
      g: sum.g + color.g,
      b: sum.b + color.b,
    }),
    { r: 0, g: 0, b: 0 },
  );
  return [constrainAmbienceColor({
    r: total.r / colors.length,
    g: total.g / colors.length,
    b: total.b / colors.length,
  }, profile)];
}

function constrainAmbiencePalette(
  colors: HueRGBColor[],
  profile: AmbienceColorProfile = STANDARD_AMBIENCE_PROFILE,
): HueRGBColor[] {
  return colors.map(color => constrainAmbienceColor(color, profile));
}

function constrainAmbienceColor(
  color: HueRGBColor,
  profile: AmbienceColorProfile = STANDARD_AMBIENCE_PROFILE,
): HueRGBColor {
  const readable = readableLightColor(color, profile);
  const hsl = rgbToHsl(readable);
  return hslToRgb(
    hsl.h,
    Math.min(hsl.s, profile.maxSaturation),
    Math.min(Math.max(hsl.l, profile.minLightness), profile.maxLightness),
  );
}

function readableLightColor(color: HueRGBColor, profile: AmbienceColorProfile): HueRGBColor {
  const maxComponent = brightness(color);
  if (maxComponent <= 0) {
    return {
      r: profile.minReadableBrightness,
      g: profile.minReadableBrightness,
      b: profile.minReadableBrightness,
    };
  }

  const targetMax = Math.min(
    Math.max(maxComponent, profile.minReadableBrightness),
    profile.maxReadableBrightness,
  );
  const scale = targetMax / maxComponent;
  return {
    r: clamp(color.r * scale),
    g: clamp(color.g * scale),
    b: clamp(color.b * scale),
  };
}

function clamp(value: number): number {
  return Math.min(Math.max(value, 0), 1);
}

function rgbToHsl(color: HueRGBColor): { h: number; s: number; l: number } {
  const r = clamp(color.r);
  const g = clamp(color.g);
  const b = clamp(color.b);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;

  if (max === min) {
    return { h: 0, s: 0, l };
  }

  const delta = max - min;
  const s = l > 0.5 ? delta / (2 - max - min) : delta / (max + min);
  let h = 0;
  if (max === r) {
    h = (g - b) / delta + (g < b ? 6 : 0);
  } else if (max === g) {
    h = (b - r) / delta + 2;
  } else {
    h = (r - g) / delta + 4;
  }

  return { h: h / 6, s, l };
}

function hslToRgb(h: number, s: number, l: number): HueRGBColor {
  const hue = positiveModulo(h, 1);
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  return {
    r: hueToRgb(p, q, hue + 1 / 3),
    g: hueToRgb(p, q, hue),
    b: hueToRgb(p, q, hue - 1 / 3),
  };
}

function hueToRgb(p: number, q: number, t: number): number {
  let value = t;
  if (value < 0) value += 1;
  if (value > 1) value -= 1;
  if (value < 1 / 6) return p + (q - p) * 6 * value;
  if (value < 1 / 2) return q;
  if (value < 2 / 3) return p + (q - p) * (2 / 3 - value) * 6;
  return p;
}

function positiveModulo(value: number, divisor: number): number {
  const remainder = value % divisor;
  return remainder >= 0 ? remainder : remainder + divisor;
}
