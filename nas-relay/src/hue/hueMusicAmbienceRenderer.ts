import { ClipHueAmbienceRenderer, type HueAmbienceRenderer } from './hueFrameRenderer.js';
import type { HueAmbienceRuntimeConfig, HueLightClient } from './hueTypes.js';

export function createHueMusicAmbienceRenderer(
  _config: HueAmbienceRuntimeConfig,
  lightClient: HueLightClient,
): HueAmbienceRenderer {
  return new ClipHueAmbienceRenderer(lightClient);
}
