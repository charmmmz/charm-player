import type { HueAmbienceToneControl } from './hueTypes.js';

export const DEFAULT_TONE_CONTROL: HueAmbienceToneControl = {
  brightness: 1,
  saturation: 1,
};

export const TONE_CONTROL_LIMITS = {
  brightness: { min: 0.55, max: 1.2 },
  saturation: { min: 0.55, max: 1.12 },
} as const;

export function normalizeToneControl(value: Partial<HueAmbienceToneControl> | null | undefined): HueAmbienceToneControl {
  return {
    brightness: clampFinite(
      value?.brightness,
      TONE_CONTROL_LIMITS.brightness.min,
      TONE_CONTROL_LIMITS.brightness.max,
      DEFAULT_TONE_CONTROL.brightness,
    ),
    saturation: clampFinite(
      value?.saturation,
      TONE_CONTROL_LIMITS.saturation.min,
      TONE_CONTROL_LIMITS.saturation.max,
      DEFAULT_TONE_CONTROL.saturation,
    ),
  };
}

function clampFinite(value: unknown, min: number, max: number, fallback: number): number {
  const numeric = typeof value === 'number' && Number.isFinite(value) ? value : fallback;
  return Math.min(Math.max(numeric, min), max);
}
