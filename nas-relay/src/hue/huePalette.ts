import crypto from 'node:crypto';
import type { HueRGBColor, HueXYColor } from './hueTypes.js';

export function stablePaletteForTrack(title = '', artist = '', album = '', fallbackKey = ''): HueRGBColor[] {
  const seed = [title, artist, album, fallbackKey]
    .map(value => value.trim())
    .filter(value => value.length > 0)
    .join('|') || 'Charm Hue Ambience';
  const digest = crypto.createHash('sha256').update(seed).digest();
  const colors: HueRGBColor[] = [];

  for (let i = 0; i < 5; i += 1) {
    const hue = ((digest[i * 3]! / 255) + i * 0.173) % 1;
    const saturation = 0.52 + (digest[i * 3 + 1]! / 255) * 0.34;
    const lightness = 0.36 + (digest[i * 3 + 2]! / 255) * 0.26;
    colors.push(hslToRgb(hue, saturation, lightness));
  }

  return colors;
}

export function rgbToXy(color: HueRGBColor): HueXYColor {
  const red = gammaCorrect(color.r);
  const green = gammaCorrect(color.g);
  const blue = gammaCorrect(color.b);

  const x = red * 0.664511 + green * 0.154324 + blue * 0.162028;
  const y = red * 0.283881 + green * 0.668433 + blue * 0.047685;
  const z = red * 0.000088 + green * 0.072310 + blue * 0.986039;
  const total = x + y + z;

  if (total <= 0) {
    return { x: 0.3127, y: 0.3290 };
  }

  return {
    x: clamp(x / total),
    y: clamp(y / total),
  };
}

export function brightness(color: HueRGBColor): number {
  return Math.max(clamp(color.r), clamp(color.g), clamp(color.b));
}

export function rotatePalette(palette: HueRGBColor[], offset: number): HueRGBColor[] {
  if (palette.length === 0) return [];
  return palette.map((_, index) => samplePalette(palette, offset + index));
}

export function samplePalette(palette: HueRGBColor[], offset: number): HueRGBColor {
  if (palette.length === 0) return { r: 0, g: 0, b: 0 };
  if (palette.length === 1) return palette[0]!;

  const normalized = positiveModulo(offset, palette.length);
  const lowerIndex = Math.floor(normalized);
  const upperIndex = (lowerIndex + 1) % palette.length;
  const amount = normalized - lowerIndex;
  return mixRgb(palette[lowerIndex]!, palette[upperIndex]!, amount);
}

export function expandPaletteForMotion(palette: HueRGBColor[]): HueRGBColor[] {
  if (palette.length !== 1) return palette;

  const base = palette[0]!;
  const hsl = rgbToHsl(base);
  if (hsl.s < 0.12) {
    return [
      base,
      hslToRgb(hsl.h, 0, clamp(hsl.l + 0.16)),
      hslToRgb(hsl.h, 0, clamp(hsl.l - 0.12)),
    ];
  }

  return [
    base,
    hslToRgb(hsl.h - 0.025, clamp(hsl.s * 0.92), clamp(hsl.l + 0.08)),
    hslToRgb(hsl.h + 0.025, clamp(hsl.s * 0.9), clamp(hsl.l - 0.07)),
    hslToRgb(hsl.h + 0.05, clamp(hsl.s * 0.82), clamp(hsl.l + 0.03)),
  ];
}

function positiveModulo(value: number, length: number): number {
  return ((value % length) + length) % length;
}

function mixRgb(a: HueRGBColor, b: HueRGBColor, amount: number): HueRGBColor {
  const t = clamp(amount);
  return {
    r: clamp(a.r + (b.r - a.r) * t),
    g: clamp(a.g + (b.g - a.g) * t),
    b: clamp(a.b + (b.b - a.b) * t),
  };
}

function hslToRgb(h: number, s: number, l: number): HueRGBColor {
  const normalizedHue = positiveModulo(h, 1);
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  return {
    r: hueToRgb(p, q, normalizedHue + 1 / 3),
    g: hueToRgb(p, q, normalizedHue),
    b: hueToRgb(p, q, normalizedHue - 1 / 3),
  };
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

function hueToRgb(p: number, q: number, t: number): number {
  let value = t;
  if (value < 0) value += 1;
  if (value > 1) value -= 1;
  if (value < 1 / 6) return p + (q - p) * 6 * value;
  if (value < 1 / 2) return q;
  if (value < 2 / 3) return p + (q - p) * (2 / 3 - value) * 6;
  return p;
}

function gammaCorrect(value: number): number {
  const clamped = clamp(value);
  if (clamped > 0.04045) {
    return ((clamped + 0.055) / 1.055) ** 2.4;
  }
  return clamped / 12.92;
}

function clamp(value: number): number {
  return Math.min(Math.max(value, 0), 1);
}
