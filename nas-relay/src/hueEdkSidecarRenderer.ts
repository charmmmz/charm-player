import type { HueAmbienceFrame, HueAmbienceTargetFrame } from './hueAmbienceFrames.js';
import {
  createHueEntertainmentStreamingOnlyRenderer,
  type HueEntertainmentControlClient,
} from './hueEntertainmentStream.js';
import { ClipHueAmbienceRenderer, type HueAmbienceRenderResult, type HueAmbienceRenderer } from './hueFrameRenderer.js';
import type { HueAmbienceRuntimeConfig, HueLightClient, HueRGBColor } from './hueTypes.js';

export type HueEdkSidecarFetch = (
  url: string,
  init?: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
  },
) => Promise<{
  ok: boolean;
  status: number;
  text(): Promise<string>;
}>;

export interface HueEdkSidecarRendererOptions {
  baseUrl: string;
  token?: string | null;
  fetch?: HueEdkSidecarFetch;
  targetFps?: number;
  sessionPolicy?: 'reuse' | 'takeover';
}

export interface HueMusicAmbienceRendererOptions {
  sidecarFetch?: HueEdkSidecarFetch;
}

export function createHueEdkSidecarRenderer(
  config: HueAmbienceRuntimeConfig,
  options: HueEdkSidecarRendererOptions,
): HueAmbienceRenderer {
  return new HueEdkSidecarRenderer(config, options);
}

export function createHueMusicAmbienceRenderer(
  config: HueAmbienceRuntimeConfig,
  lightClient: HueLightClient & HueEntertainmentControlClient,
  env: Record<string, string | undefined> = process.env,
  options: HueMusicAmbienceRendererOptions = {},
): HueAmbienceRenderer {
  const clipFallback = new ClipHueAmbienceRenderer(lightClient);
  const rendererName = (env.HUE_MUSIC_RENDERER ?? env.HUE_RENDERER ?? '').toLowerCase();
  if (rendererName === 'clip' || rendererName === 'clip-v2' || rendererName === 'clipv2') {
    return clipFallback;
  }

  const syncRenderer = rendererName === 'edk-sidecar'
    ? new HueEdkSidecarRenderer(config, {
      baseUrl: env.HUE_EDK_SIDECAR_URL ?? 'http://127.0.0.1:8787',
      token: env.HUE_EDK_SIDECAR_TOKEN,
      fetch: options.sidecarFetch,
      targetFps: numericEnv(env.HUE_EDK_SIDECAR_TARGET_FPS) ?? 60,
      sessionPolicy: env.HUE_EDK_SIDECAR_SESSION_POLICY === 'takeover' ? 'takeover' : 'reuse',
    })
    : createHueEntertainmentStreamingOnlyRenderer(config, lightClient);

  return new MusicSyncFallbackRenderer(syncRenderer, clipFallback);
}

class MusicSyncFallbackRenderer implements HueAmbienceRenderer {
  private activeRenderer: 'sync' | 'clip' | null = null;

  constructor(
    private readonly sync: HueAmbienceRenderer,
    private readonly clipFallback: HueAmbienceRenderer,
  ) {}

  async render(frame: HueAmbienceFrame): Promise<HueAmbienceRenderResult> {
    if (!canUseMusicSync(frame)) {
      await this.releaseSyncIfNeeded();
      this.activeRenderer = 'clip';
      return await this.clipFallback.render(frame);
    }

    try {
      const result = await this.sync.render(frame);
      this.activeRenderer = 'sync';
      return result;
    } catch {
      await this.sync.release?.().catch(() => {});
      this.activeRenderer = 'clip';
      return await this.clipFallback.render(frame);
    }
  }

  async stop(frame: HueAmbienceFrame): Promise<void> {
    if (this.activeRenderer === 'sync') {
      await this.sync.stop(frame);
    } else if (this.activeRenderer === 'clip') {
      await this.clipFallback.stop(frame);
    }
    this.activeRenderer = null;
  }

  async release(): Promise<void> {
    await Promise.allSettled([
      this.sync.release?.(),
      this.clipFallback.release?.(),
    ]);
    this.activeRenderer = null;
  }

  private async releaseSyncIfNeeded(): Promise<void> {
    if (this.activeRenderer !== 'sync') return;
    await this.sync.release?.();
  }
}

class HueEdkSidecarRenderer implements HueAmbienceRenderer {
  private configuredAreaId: string | null = null;
  private sessionStarted = false;
  private readonly playedEffectKeys = new Map<string, number>();

  constructor(
    private readonly config: HueAmbienceRuntimeConfig,
    private readonly options: HueEdkSidecarRendererOptions,
  ) {}

  async render(frame: HueAmbienceFrame): Promise<HueAmbienceRenderResult> {
    const target = entertainmentTargetForSidecar(frame);
    await this.ensureConfigured(target.area.id);
    await this.ensureStarted();

    const effect = frame.effect;
    if (effect?.source === 'cs2' && effect.reason === 'flash') {
      const effectPhase = flashEffectPhase(effect.effectPhase);
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt, effectPhase)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      await this.post('/effect/sphere', {
        kind: 'flash',
        phase: effectPhase,
        r: 1,
        g: 1,
        b: 1,
        intensity: Math.max(frameIntensity(frame), 0.94),
        attackMs: secondsToMs(effect.attackSeconds, 90),
        holdMs: secondsToMs(effect.holdSeconds, 90),
        fadeMs: secondsToMs(effect.fadeSeconds, 700),
        x: 0,
        y: 0,
        z: 1,
        radius: 3.1,
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2' && effect.reason === 'kill') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      const color = framePalette(frame)[0] ?? { r: 1, g: 0.04, b: 0.02 };
      await this.post('/effect/kill-multiflash', {
        r: color.r,
        g: color.g,
        b: color.b,
        intensity: Math.max(frameIntensity(frame), 0.86),
        count: killFlashCount(effect.strength),
        attackMs: secondsToMs(effect.attackSeconds, 35),
        holdMs: secondsToMs(effect.holdSeconds, 45),
        fadeMs: 55,
        gapMs: 35,
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2' && effect.reason === 'bombPlanted') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      await this.post('/ambient/team', {
        team: 'neutral',
        brightness: 1,
        transitionMs: secondsToMs(frame.transitionSeconds, 180),
        palette: framePalette(frame),
      });
      await this.post('/effect/c4', {
        remainingMs: effect.remainingMs ?? 40_000,
        intensity: frameIntensity(frame),
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2' && effect.reason === 'roundFreeze') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      const color = framePalette(frame)[0] ?? { r: 0.05, g: 0.18, b: 0.44 };
      await this.post('/ambient/team', {
        team: 'neutral',
        brightness: 1,
        transitionMs: secondsToMs(frame.transitionSeconds, 400),
        palette: framePalette(frame),
      });
      await this.post('/effect/iterator', {
        kind: 'freeze',
        r: color.r,
        g: color.g,
        b: color.b,
        intensity: Math.min(0.65, Math.max(0.34, frameIntensity(frame))),
        pulseMs: 680,
        offsetMs: 180,
        order: 'clockwise',
        mode: 'cycle',
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2' && effect.reason === 'bombExploded') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      const color = framePalette(frame)[0] ?? { r: 1, g: 0.55, b: 0.04 };
      await this.post('/effect/explosion', {
        r: color.r,
        g: color.g,
        b: color.b,
        intensity: frameIntensity(frame),
        durationMs: secondsToMs(
          (effect.attackSeconds ?? 0) + (effect.holdSeconds ?? 0) + (effect.fadeSeconds ?? 0),
          1_100,
        ),
        radius: 2.2,
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2') {
      await this.post('/ambient/team', {
        team: teamForEffect(effect.reason),
        brightness: 1,
        transitionMs: secondsToMs(frame.transitionSeconds, 240),
        palette: framePalette(frame),
      });
      return { transport: 'entertainmentStreaming' };
    }

    await this.post('/ambient/music', musicAmbientBody(frame, target));
    return { transport: 'entertainmentStreaming' };
  }

  async stop(_frame: HueAmbienceFrame): Promise<void> {
    await this.post('/session/stop', {});
    this.sessionStarted = false;
  }

  async release(): Promise<void> {
    await this.post('/session/stop', {});
    this.sessionStarted = false;
  }

  private async ensureConfigured(areaId: string): Promise<void> {
    if (this.configuredAreaId === areaId) return;

    if (!this.config.streamingClientKey) {
      throw new Error('missing Hue Entertainment streaming credentials');
    }

    await this.post('/configure', {
      bridgeIp: this.config.bridge.ipAddress,
      bridgeName: this.config.bridge.name,
      applicationKey: this.config.applicationKey,
      streamingClientKey: this.config.streamingClientKey,
      streamingApplicationId: this.config.streamingApplicationId,
      entertainmentAreaId: areaId,
      targetFps: this.options.targetFps ?? 60,
      sessionPolicy: this.options.sessionPolicy ?? 'reuse',
    });
    this.configuredAreaId = areaId;
    this.sessionStarted = false;
  }

  private async ensureStarted(): Promise<void> {
    if (this.sessionStarted) return;
    await this.post('/session/start', {});
    this.sessionStarted = true;
  }

  private async post(path: string, body: unknown): Promise<void> {
    const response = await this.fetchFn()(sidecarUrl(this.options.baseUrl, path), {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(this.options.token ? { authorization: `Bearer ${this.options.token}` } : {}),
      },
      body: JSON.stringify(body),
    });

    if (response.ok) return;

    const text = await response.text().catch(() => '');
    throw new Error(`Hue EDK sidecar ${path} failed (${response.status})${text ? `: ${text}` : ''}`);
  }

  private fetchFn(): HueEdkSidecarFetch {
    const fetchFn = this.options.fetch ?? globalThis.fetch;
    if (!fetchFn) {
      throw new Error('Hue EDK sidecar renderer requires fetch');
    }
    return fetchFn as HueEdkSidecarFetch;
  }

  private markEffectForPlayback(effectKey: string | undefined, createdAt: Date, phase?: string): boolean {
    if (!effectKey) return true;
    const playbackKey = phase ? `${effectKey}:${phase}` : effectKey;
    if (this.playedEffectKeys.has(playbackKey)) return false;

    this.playedEffectKeys.set(playbackKey, createdAt.getTime());
    if (this.playedEffectKeys.size > 128) {
      const oldest = [...this.playedEffectKeys.entries()]
        .sort((a, b) => a[1] - b[1])
        .slice(0, this.playedEffectKeys.size - 128);
      for (const [key] of oldest) {
        this.playedEffectKeys.delete(key);
      }
    }
    return true;
  }
}

function entertainmentTargetForSidecar(frame: HueAmbienceFrame): HueAmbienceTargetFrame {
  const targets = frame.targets.filter(target => target.area.kind === 'entertainmentArea');
  if (targets.length !== 1 || !targets[0]) {
    throw new Error('Hue EDK sidecar rendering requires exactly one entertainment area target');
  }
  return targets[0];
}

function canUseMusicSync(frame: HueAmbienceFrame): boolean {
  if (frame.effect?.source === 'cs2') return false;
  if ((frame.groupMemberCount ?? 1) > 1) return false;
  if (!frame.metadataComplete) return false;
  try {
    entertainmentTargetForSidecar(frame);
    return true;
  } catch {
    return false;
  }
}

function sidecarUrl(baseUrl: string, path: string): string {
  const normalized = baseUrl.endsWith('/') ? baseUrl.slice(0, -1) : baseUrl;
  return `${normalized}${path}`;
}

function musicAmbientBody(frame: HueAmbienceFrame, target: HueAmbienceTargetFrame): {
  brightness: number;
  transitionMs: number;
  palette: HueRGBColor[];
  lights: Array<{
    channelId: string;
    lightId: string;
    position: { x: number; y: number; z: number };
    colors: HueRGBColor[];
  }>;
} {
  return {
    brightness: 1,
    transitionMs: secondsToMs(frame.transitionSeconds, 1200),
    palette: frameMusicPalette(frame),
    lights: target.lights.map((lightFrame, index) => ({
      channelId: lightFrame.channelID ?? lightFrame.light.id,
      lightId: lightFrame.light.id,
      position: entertainmentChannelPosition(target, lightFrame.channelID, lightFrame.light.id, index),
      colors: lightFrame.colors.map(clampColor),
    })),
  };
}

function entertainmentChannelPosition(
  target: HueAmbienceTargetFrame,
  channelID: string | null | undefined,
  lightID: string,
  index: number,
): { x: number; y: number; z: number } {
  const channel = target.area.entertainmentChannels?.find(candidate =>
    (channelID && candidate.id === channelID) || candidate.lightID === lightID,
  );
  const position = channel?.position;
  if (position && Number.isFinite(position.x) && Number.isFinite(position.y) && Number.isFinite(position.z)) {
    return {
      x: position.x,
      y: position.y,
      z: position.z,
    };
  }

  const angle = (index % Math.max(target.lights.length, 1)) / Math.max(target.lights.length, 1) * Math.PI * 2;
  return {
    x: Math.cos(angle),
    y: 0,
    z: Math.sin(angle),
  };
}

function frameMusicPalette(frame: HueAmbienceFrame): HueRGBColor[] {
  const colors: HueRGBColor[] = [];
  for (const target of frame.targets) {
    for (const light of target.lights) {
      for (const color of light.colors) {
        if (colors.some(existing => sameColor(existing, color))) continue;
        colors.push(clampColor(color));
        if (colors.length >= 8) return colors;
      }
    }
  }
  return colors.length > 0 ? colors : [{ r: 0, g: 0, b: 0 }];
}

function secondsToMs(seconds: number | undefined, fallbackMs: number): number {
  if (!Number.isFinite(seconds)) return fallbackMs;
  return Math.max(0, Math.round((seconds as number) * 1000));
}

function teamForEffect(reason: string | undefined): 'CT' | 'T' | 'observer' | 'neutral' {
  if (reason === 'observerAmbient') return 'observer';
  return 'neutral';
}

function framePalette(frame: HueAmbienceFrame): HueRGBColor[] {
  const colors: HueRGBColor[] = [];
  for (const target of frame.targets) {
    for (const light of target.lights) {
      const color = light.colors[0];
      if (!color) continue;
      if (colors.some(existing => sameColor(existing, color))) continue;
      colors.push(clampColor(color));
      if (colors.length >= 8) return colors;
    }
  }
  return colors.length > 0 ? colors : [{ r: 0, g: 0, b: 0 }];
}

function flashEffectPhase(value: string | undefined): 'sustain' | 'release' {
  return value === 'release' ? 'release' : 'sustain';
}

function killFlashCount(strength: number | undefined): number {
  return Math.min(5, Math.max(1, Math.round(strength ?? 1)));
}

function frameIntensity(frame: HueAmbienceFrame): number {
  return Math.max(...framePalette(frame).map(color => Math.max(color.r, color.g, color.b)), 0);
}

function sameColor(a: HueRGBColor, b: HueRGBColor): boolean {
  return Math.abs(a.r - b.r) < 0.0001
    && Math.abs(a.g - b.g) < 0.0001
    && Math.abs(a.b - b.b) < 0.0001;
}

function clampColor(color: HueRGBColor): HueRGBColor {
  return {
    r: clamp01(color.r),
    g: clamp01(color.g),
    b: clamp01(color.b),
  };
}

function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(1, value));
}

function numericEnv(value: string | undefined): number | null {
  if (value === undefined) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}
