import { samplePalette } from './huePalette.js';
import type {
  HueAmbienceMotionStyle,
  HueEntertainmentChannelResource,
  HueLightResource,
  HueRGBColor,
} from './hueTypes.js';

export type HueSpatialLightRole = 'base' | 'accent' | 'fill' | 'functional';

export interface HueSpatialLightColorsInput {
  light: HueLightResource;
  palette: HueRGBColor[];
  phase: number;
  offset: number;
  motionStyle: HueAmbienceMotionStyle;
  position?: HueSpatialPosition | null;
  segmentPositions?: HueSpatialPosition[];
}

export interface HueSpatialPosition {
  x: number;
  y: number;
  z: number;
}

interface ToneProfile {
  minLightness: number;
  maxLightness: number;
  maxBrightness: number;
  minSaturation: number;
  maxSaturation: number;
  saturationScale: number;
  darkMix: number;
}

const GRADIENT_POINT_LIMIT = 5;
const DARK_NEUTRAL: HueRGBColor = { r: 0.012, g: 0.014, b: 0.018 };

const TONE_PROFILES: Record<HueSpatialLightRole, ToneProfile> = {
  base: {
    minLightness: 0.12,
    maxLightness: 0.27,
    maxBrightness: 0.38,
    minSaturation: 0.08,
    maxSaturation: 0.3,
    saturationScale: 0.45,
    darkMix: 0.34,
  },
  accent: {
    minLightness: 0.13,
    maxLightness: 0.33,
    maxBrightness: 0.44,
    minSaturation: 0.14,
    maxSaturation: 0.48,
    saturationScale: 0.66,
    darkMix: 0.18,
  },
  fill: {
    minLightness: 0.08,
    maxLightness: 0.18,
    maxBrightness: 0.22,
    minSaturation: 0,
    maxSaturation: 0.14,
    saturationScale: 0.25,
    darkMix: 0.56,
  },
  functional: {
    minLightness: 0.06,
    maxLightness: 0.12,
    maxBrightness: 0.14,
    minSaturation: 0,
    maxSaturation: 0.08,
    saturationScale: 0.2,
    darkMix: 0.5,
  },
};

export function buildSpatialLightColors(input: HueSpatialLightColorsInput): HueRGBColor[] {
  if (input.palette.length === 0) return [];

  const role = classifySpatialLightRole(input.light);
  const positions = spatialSamplePositions(input);

  return positions.map((position, index) => {
    const sampled = input.motionStyle === 'still'
      ? constellationColor(input.palette, role, input.offset, position, index)
      : driftColor(input.palette, role, input.phase, input.offset, position, index);
    return toneForRole(sampled, role);
  });
}

export function classifySpatialLightRole(light: HueLightResource): HueSpatialLightRole {
  if (light.function === 'functional') return 'functional';

  const name = light.name.trim().toLowerCase();
  if (/(主灯|餐桌|吊灯|顶灯|ceiling|main|dining|overhead)/i.test(name)) {
    return 'fill';
  }
  if (/(落地|支架|桌边|边灯|角灯|floor|stand|side|corner|table)/i.test(name)) {
    return 'accent';
  }
  if (/(洗墙|电视墙|屏幕|电视灯|墙|wall|screen|strip|gradient|play)/i.test(name)) {
    return 'base';
  }

  return light.supportsGradient ? 'base' : 'accent';
}

export function positionedChannelsForLight(
  channels: HueEntertainmentChannelResource[] | undefined,
  lightID: string,
): HueSpatialPosition[] {
  return (channels ?? [])
    .filter(channel => channel.lightID === lightID)
    .map(channel => channel.position)
    .filter((position): position is HueSpatialPosition => isSpatialPosition(position))
    .sort(compareSpatialPositions);
}

export function averagePosition(positions: HueSpatialPosition[]): HueSpatialPosition | null {
  if (positions.length === 0) return null;
  const total = positions.reduce(
    (sum, position) => ({
      x: sum.x + position.x,
      y: sum.y + position.y,
      z: sum.z + position.z,
    }),
    { x: 0, y: 0, z: 0 },
  );
  return {
    x: total.x / positions.length,
    y: total.y / positions.length,
    z: total.z / positions.length,
  };
}

export function isSpatialPosition(value: unknown): value is HueSpatialPosition {
  if (!value || typeof value !== 'object') return false;
  const candidate = value as Partial<HueSpatialPosition>;
  return Number.isFinite(candidate.x)
    && Number.isFinite(candidate.y)
    && Number.isFinite(candidate.z);
}

export function compareSpatialPositions(a: HueSpatialPosition, b: HueSpatialPosition): number {
  return a.x - b.x || a.z - b.z || a.y - b.y;
}

function spatialSamplePositions(input: HueSpatialLightColorsInput): HueSpatialPosition[] {
  if (input.light.supportsGradient) {
    if (input.segmentPositions && input.segmentPositions.length > 0) {
      return input.segmentPositions.slice(0, GRADIENT_POINT_LIMIT);
    }
    return virtualGradientPositions(Math.min(Math.max(input.palette.length, 3), GRADIENT_POINT_LIMIT), input.position);
  }

  return [input.position ?? virtualPosition(input.offset)];
}

function driftColor(
  palette: HueRGBColor[],
  role: HueSpatialLightRole,
  phase: number,
  offset: number,
  position: HueSpatialPosition,
  segmentIndex: number,
): HueRGBColor {
  const base = samplePalette(palette, 0);
  const spatialOffset = (position.x * 0.52)
    + (position.z * 0.28)
    + (position.y * 0.08)
    + (segmentIndex * 0.18)
    + (offset * 0.12)
    + (phase * 0.55);
  const sampled = samplePalette(palette, spatialOffset);

  switch (role) {
    case 'fill':
    case 'functional':
      return mixRgb(base, sampled, 0.18);
    case 'base':
      return mixRgb(base, sampled, 0.38);
    case 'accent':
      return sampled;
  }
}

function constellationColor(
  palette: HueRGBColor[],
  role: HueSpatialLightRole,
  offset: number,
  position: HueSpatialPosition,
  segmentIndex: number,
): HueRGBColor {
  const base = samplePalette(palette, 0);
  if (role === 'fill' || role === 'functional') return base;

  const starOffset = Math.abs(position.x * 0.9 + position.z * 0.45 + offset * 0.27 + segmentIndex * 0.33);
  const accent = samplePalette(palette, starOffset);
  return role === 'accent'
    ? accent
    : mixRgb(base, accent, 0.24);
}

function toneForRole(color: HueRGBColor, role: HueSpatialLightRole): HueRGBColor {
  const profile = TONE_PROFILES[role];
  const hsl = rgbToHsl(color);
  const shaped = hslToRgb(
    hsl.h,
    clamp(hsl.s * profile.saturationScale, profile.minSaturation, profile.maxSaturation),
    clamp(hsl.l * 0.62, profile.minLightness, profile.maxLightness),
  );
  const darkened = mixRgb(shaped, DARK_NEUTRAL, profile.darkMix);
  return capBrightness(darkened, profile.maxBrightness);
}

function virtualGradientPositions(count: number, basePosition: HueSpatialPosition | null | undefined): HueSpatialPosition[] {
  const center = basePosition ?? { x: 0, y: 0, z: 0 };
  if (count <= 1) return [center];

  return Array.from({ length: count }, (_, index) => {
    const amount = index / (count - 1);
    return {
      x: center.x + (amount - 0.5) * 1.2,
      y: center.y,
      z: center.z + (amount - 0.5) * 0.24,
    };
  });
}

function virtualPosition(offset: number): HueSpatialPosition {
  const x = ((offset % 5) - 2) / 2;
  const z = (Math.floor(offset / 5) % 3) - 1;
  return { x, y: 0, z };
}

function capBrightness(color: HueRGBColor, maxBrightness: number): HueRGBColor {
  const current = Math.max(color.r, color.g, color.b);
  if (current <= 0 || current <= maxBrightness) return color;
  const scale = maxBrightness / current;
  return {
    r: clamp01(color.r * scale),
    g: clamp01(color.g * scale),
    b: clamp01(color.b * scale),
  };
}

function mixRgb(a: HueRGBColor, b: HueRGBColor, amount: number): HueRGBColor {
  const t = clamp01(amount);
  return {
    r: clamp01(a.r + (b.r - a.r) * t),
    g: clamp01(a.g + (b.g - a.g) * t),
    b: clamp01(a.b + (b.b - a.b) * t),
  };
}

function rgbToHsl(color: HueRGBColor): { h: number; s: number; l: number } {
  const r = clamp01(color.r);
  const g = clamp01(color.g);
  const b = clamp01(color.b);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;

  if (max === min) return { h: 0, s: 0, l };

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

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

function clamp01(value: number): number {
  return clamp(value, 0, 1);
}

function positiveModulo(value: number, divisor: number): number {
  const remainder = value % divisor;
  return remainder >= 0 ? remainder : remainder + divisor;
}
