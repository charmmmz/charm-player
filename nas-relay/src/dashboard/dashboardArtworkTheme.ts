import { sampleAlbumArtColors } from '../hue/hueAlbumArtPalette.js';
import type { HueRGBColor } from '../hue/hueTypes.js';

export function themeColorFromAlbumArtBuffer(data: Buffer): string {
  return colorHex(themeColorFromSamples(sampleAlbumArtColors(data)));
}

export function themeColorFromSamples(colors: HueRGBColor[]): HueRGBColor {
  let bestColor: HueRGBColor = { r: 0.6, g: 0.6, b: 0.6 };
  let bestScore = -1;
  let sampled = { r: 0, g: 0, b: 0, count: 0, saturation: 0, colorful: 0 };

  for (const color of colors) {
    const hsl = rgbToHsl(color);
    if (hsl.l >= 0.08 && hsl.l <= 0.94) {
      sampled.r += color.r;
      sampled.g += color.g;
      sampled.b += color.b;
      sampled.count += 1;
      sampled.saturation += hsl.s;
      if (hsl.s >= 0.18) sampled.colorful += 1;
    }

    const score = hsl.s * 3
      + (1 - Math.abs(hsl.l - 0.6)) * 0.8
      - (hsl.l < 0.15 ? 3 : 0)
      - (hsl.l > 0.92 ? 2 : 0);
    if (score > bestScore) {
      bestScore = score;
      bestColor = color;
    }
  }

  if (sampled.count > 0
    && sampled.saturation / sampled.count < 0.1
    && sampled.colorful / sampled.count < 0.05) {
    return neutralForDarkBackground({
      r: sampled.r / sampled.count,
      g: sampled.g / sampled.count,
      b: sampled.b / sampled.count,
    });
  }

  const hsl = rgbToHsl(bestColor);
  if (hsl.s < 0.12) return neutralForDarkBackground(bestColor);
  return hslToRgb({
    h: hsl.h,
    s: Math.min(1, Math.max(0.55, hsl.s)),
    l: Math.min(0.88, Math.max(0.6, hsl.l)),
  });
}

function neutralForDarkBackground(color: HueRGBColor): HueRGBColor {
  const component = Math.min(0.74, Math.max(0.48, rgbToHsl(color).l));
  return { r: component, g: component, b: component };
}

function rgbToHsl(color: HueRGBColor): { h: number; s: number; l: number } {
  const max = Math.max(color.r, color.g, color.b);
  const min = Math.min(color.r, color.g, color.b);
  const delta = max - min;
  const l = (max + min) / 2;
  if (delta <= 0.001) return { h: 0, s: 0, l };

  const s = delta / (1 - Math.abs(2 * l - 1));
  let h: number;
  if (max === color.r) h = ((color.g - color.b) / delta) % 6;
  else if (max === color.g) h = (color.b - color.r) / delta + 2;
  else h = (color.r - color.g) / delta + 4;
  h = ((h / 6) % 1 + 1) % 1;
  return { h, s, l };
}

function hslToRgb(hsl: { h: number; s: number; l: number }): HueRGBColor {
  const c = (1 - Math.abs(2 * hsl.l - 1)) * hsl.s;
  const x = c * (1 - Math.abs((hsl.h * 6) % 2 - 1));
  const m = hsl.l - c / 2;
  const sector = Math.floor(hsl.h * 6) % 6;
  const values: [number, number, number][] = [
    [c, x, 0], [x, c, 0], [0, c, x],
    [0, x, c], [x, 0, c], [c, 0, x],
  ];
  const [r, g, b] = values[sector] ?? values[0]!;
  return { r: r + m, g: g + m, b: b + m };
}

function colorHex(color: HueRGBColor): string {
  const component = (value: number) => Math.round(Math.min(1, Math.max(0, value)) * 255)
    .toString(16)
    .padStart(2, '0')
    .toUpperCase();
  return `#${component(color.r)}${component(color.g)}${component(color.b)}`;
}
