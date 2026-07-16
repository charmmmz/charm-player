import type { Logger } from 'pino';

import { HueClipClient } from './hueClient.js';
import { buildHueAmbienceFrame, type HueAmbienceFrame } from './hueAmbienceFrames.js';
import type { HueAmbienceConfigStore } from './hueConfigStore.js';
import { paletteForSnapshot } from './hueAlbumArtPalette.js';
import { expandPaletteForMotion } from './huePalette.js';
import type { HueAmbienceRenderer, HueAmbienceRenderResult } from './hueFrameRenderer.js';
import { createHueEntertainmentStreamingRenderer, type HueEntertainmentControlClient } from './hueEntertainmentStream.js';
import { resolveHueTargets } from './hueRenderer.js';
import type {
  HueAmbienceActiveGroupStatus,
  HueAmbienceMappingConfiguration,
  HueAmbienceRenderMode,
  HueAmbienceRuntimeConfig,
  HueAmbienceServiceStatus,
  HueEntertainmentClient,
  HueEntertainmentStatus,
  HueLightClient,
  HueRGBColor,
  HueResolvedAmbienceTarget,
  HueSnapshot,
} from './hueTypes.js';

type HuePaletteProvider = (snapshot: HueSnapshot) => Promise<HueRGBColor[]> | HueRGBColor[];

export const DEFAULT_STOP_GRACE_MS = 4_000;
const ENTERTAINMENT_STATUS_TIMEOUT_MS = 1_500;
const ENTERTAINMENT_FLOW_MIN_FRAME_MS = 120;
const ENTERTAINMENT_FLOW_MAX_FRAME_MS = 250;

interface HueAmbienceGroupSession {
  groupId: string;
  speakerName?: string | null;
  activeTimer: NodeJS.Timeout | null;
  stopTimer: NodeJS.Timeout | null;
  activeTargets: HueResolvedAmbienceTarget[];
  activeTrackKey: string | null;
  runID: number;
  activeFrame: HueAmbienceFrame | null;
  pendingStopFrame: HueAmbienceFrame | null;
  lastFrameAt: string | null;
  activeRenderMode: HueAmbienceRenderMode | null;
  entertainmentTargetActive: boolean;
  activeEntertainmentMetadataComplete: boolean;
  activeRenderer: HueAmbienceRenderer | null;
}

interface HueEntertainmentConfigurationEnvelope {
  data?: HueEntertainmentConfigurationStatusDTO[];
}

interface HueEntertainmentConfigurationStatusDTO {
  id?: string;
  status?: string | null;
  active_streamer?: {
    rid?: string | null;
    rtype?: string | null;
  } | null;
}

export class HueAmbienceService {
  private config: HueAmbienceRuntimeConfig | null = null;
  private readonly sessions = new Map<string, HueAmbienceGroupSession>();
  private readonly latestSnapshots = new Map<string, HueSnapshot>();
  private lastError: string | null = null;
  private runtimePaused = false;

  constructor(
    private readonly store: HueAmbienceConfigStore,
    private readonly log: Logger,
    private readonly clientFactory: (config: HueAmbienceRuntimeConfig) => HueLightClient = config =>
      new HueClipClient(config.bridge, config.applicationKey),
    private readonly paletteProvider: HuePaletteProvider = paletteForSnapshot,
    private readonly stopGraceMs = DEFAULT_STOP_GRACE_MS,
    private readonly rendererFactory: (
      config: HueAmbienceRuntimeConfig,
      client: HueLightClient,
    ) => HueAmbienceRenderer = (config, client) =>
      createHueEntertainmentStreamingRenderer(
        config,
        client as HueLightClient & HueEntertainmentControlClient,
      ),
    private readonly entertainmentClientFactory: (
      config: HueAmbienceRuntimeConfig,
    ) => HueEntertainmentClient = config =>
      new HueClipClient(config.bridge, config.applicationKey, ENTERTAINMENT_STATUS_TIMEOUT_MS),
  ) {}

  async load(): Promise<void> {
    this.config = await this.store.load();
    this.runtimePaused = this.config?.enabled === false;
  }

  async saveConfig(config: HueAmbienceRuntimeConfig): Promise<void> {
    const snapshotsToReplay = [...this.latestSnapshots.values()];
    this.cancelAllScheduledStops();
    this.cancelAllPendingWork();
    await this.stopAllActive();
    await this.store.save(config);
    this.config = this.store.current;
    this.runtimePaused = this.config?.enabled === false;
    this.lastError = null;
    this.replaySnapshots(snapshotsToReplay);
  }

  mappingConfiguration(): HueAmbienceMappingConfiguration | null {
    if (!this.config) return null;
    return {
      resources: this.config.resources,
      mappings: this.config.mappings,
    };
  }

  async saveMappings(mappings: HueAmbienceRuntimeConfig['mappings']): Promise<void> {
    if (!this.config) throw new Error('hue_not_configured');
    await this.saveConfig({
      ...this.config,
      mappings,
    });
  }

  async clearConfig(): Promise<void> {
    this.cancelAllScheduledStops();
    this.cancelAllPendingWork();
    await this.stopAllActive();
    await this.store.clear();
    this.config = null;
    this.runtimePaused = false;
    this.lastError = null;
  }

  async start(): Promise<void> {
    const config = this.config;
    if (!config) {
      this.runtimePaused = false;
      this.lastError = null;
      return;
    }
    await this.saveConfig({ ...config, enabled: true });
  }

  async stop(): Promise<void> {
    const config = this.config;
    if (!config) {
      this.runtimePaused = true;
      return;
    }
    await this.saveConfig({ ...config, enabled: false });
  }

  async pauseForExternalRenderer(): Promise<void> {
    this.cancelAllScheduledStops();
    this.cancelAllPendingWork();
    await this.stopAllActive(false);
  }

  status(): HueAmbienceServiceStatus {
    const activeGroups = this.activeGroupStatuses();
    const primaryGroup = activeGroups[0];
    const renderMode = aggregateRenderMode(activeGroups);
    const entertainmentTargetActive = activeGroups.some(group => group.entertainmentTargetActive === true);
    const entertainmentMetadataComplete = entertainmentTargetActive
      ? activeGroups
        .filter(group => group.entertainmentTargetActive === true)
        .every(group => group.entertainmentMetadataComplete === true)
      : false;

    return {
      ...this.store.status(),
      runtimeActive: activeGroups.length > 0,
      runtimePaused: this.runtimePaused,
      activeGroupId: primaryGroup?.groupId ?? null,
      lastTrackKey: primaryGroup?.lastTrackKey ?? null,
      lastError: this.lastError,
      activeTargetIds: uniqueActiveTargetIds(activeGroups),
      activeGroups,
      renderMode,
      entertainmentTargetActive,
      entertainmentMetadataComplete,
      lastFrameAt: latestFrameAt(activeGroups),
    };
  }

  async entertainmentStatus(): Promise<HueEntertainmentStatus> {
    const config = this.config;
    if (!config) {
      return {
        configured: false,
        bridgeReachable: false,
        streaming: 'unknown',
        activeStreamer: null,
        activeAreaId: null,
        lastError: null,
      };
    }

    try {
      const envelope = await this.entertainmentClientFactory(config)
        .get<HueEntertainmentConfigurationEnvelope>('/clip/v2/resource/entertainment_configuration');
      const activeArea = (envelope.data ?? []).find(area =>
        area.status === 'active' || Boolean(area.active_streamer?.rid),
      );
      const activeStreamer = activeArea?.active_streamer?.rid ?? null;
      const relayStreamerId = config.streamingApplicationId ?? config.applicationKey;
      const streaming = activeArea
        ? activeStreamer === relayStreamerId ? 'activeByRelay' : 'occupied'
        : 'free';

      return {
        configured: true,
        bridgeReachable: true,
        streaming,
        activeStreamer,
        activeAreaId: activeArea?.id ?? null,
        lastError: null,
      };
    } catch (err) {
      return {
        configured: true,
        bridgeReachable: false,
        streaming: 'unknown',
        activeStreamer: null,
        activeAreaId: null,
        lastError: err instanceof Error ? err.message : String(err),
      };
    }
  }

  receiveSnapshot(snapshot: HueSnapshot): void {
    this.latestSnapshots.set(snapshot.groupId, snapshot);

    const config = this.config;
    if (!config || !config.enabled) {
      this.cancelAllScheduledStops();
      this.cancelAllPendingWork();
      void this.stopAllActive();
      return;
    }

    if (this.runtimePaused) {
      return;
    }

    if (!snapshot.isPlaying) {
      const session = this.sessions.get(snapshot.groupId);
      if (!session) return;
      this.scheduleStopActive(session);
      return;
    }

    if (snapshot.musicAmbienceEligible === false) {
      const session = this.sessions.get(snapshot.groupId);
      if (session) this.scheduleStopActive(session);
      this.lastError = null;
      return;
    }

    const targets = resolveHueTargets(config, snapshot, {
      preferFallbackForEntertainment: isGroupedPlayback(snapshot),
    });
    if (targets.length === 0) {
      const session = this.sessions.get(snapshot.groupId);
      if (session) this.scheduleStopActive(session);
      this.lastError = null;
      return;
    }

    const session = this.sessionForSnapshot(snapshot);
    this.cancelScheduledStop(session);

    const trackKey = [
      snapshot.groupId,
      snapshot.trackTitle,
      snapshot.artist,
      snapshot.album,
      snapshot.albumArtUri,
      snapshot.groupMemberCount,
    ].join('|');
    if (trackKey === session.activeTrackKey && session.activeTargets.length > 0 && session.activeFrame) {
      return;
    }

    const runID = this.cancelPendingWork(session);
    void this.startForSnapshot(config, session, snapshot, targets, trackKey, runID);
  }

  private replaySnapshots(snapshots: HueSnapshot[]): void {
    for (const snapshot of snapshots) {
      this.receiveSnapshot(snapshot);
    }
  }

  private async startForSnapshot(
    config: HueAmbienceRuntimeConfig,
    session: HueAmbienceGroupSession,
    snapshot: HueSnapshot,
    targets: HueResolvedAmbienceTarget[],
    trackKey: string,
    runID: number,
  ): Promise<void> {
    const renderer = await this.rendererForTargets(session, config, targets);
    if (!this.isCurrentRun(session, runID)) return;

    session.activeTargets = targets;
    session.activeTrackKey = trackKey;
    session.speakerName = snapshot.speakerName;
    this.lastError = null;
    session.activeRenderer = renderer;
    const intervalSeconds = Math.max(config.flowIntervalSeconds, 1);
    const transitionSeconds = config.motionStyle === 'flowing' ? intervalSeconds : 4;
    session.pendingStopFrame = this.buildStopFrame(targets, snapshot, transitionSeconds);

    const sourcePalette = await this.paletteProvider(snapshot);
    if (!this.isCurrentRun(session, runID)) return;
    const palette = config.motionStyle === 'flowing'
      ? expandPaletteForMotion(sourcePalette)
      : sourcePalette;

    let step = 0;
    const cycleStartedAt = Date.now();
    const apply = async (phase = step): Promise<HueAmbienceRenderResult | null> => {
      if (!this.isCurrentRun(session, runID)) return null;
      try {
        const frame = buildHueAmbienceFrame({
          targets,
          palette,
          snapshot,
          phase: config.motionStyle === 'flowing' ? phase : 0,
          transitionSeconds,
          reason: step === 0 ? 'trackChange' : 'steady',
          motionStyle: config.motionStyle,
          toneControl: config.toneControl,
        });
        const result = await renderer.render(frame);
        session.activeFrame = frame;
        session.activeRenderMode = result.transport === 'entertainmentStreaming'
          ? 'entertainmentStreaming'
          : frame.mode;
        session.entertainmentTargetActive = frame.targets.some(target => target.area.kind === 'entertainmentArea');
        session.activeEntertainmentMetadataComplete = frame.metadataComplete;
        session.lastFrameAt = frame.createdAt.toISOString();
        step = phase + 1;
        return result;
      } catch (err) {
        this.lastError = err instanceof Error ? err.message : String(err);
        this.log.warn({ err, groupId: snapshot.groupId }, 'Hue ambience update failed');
        return null;
      }
    };

    const initialRenderResult = await apply();
    if (!this.isCurrentRun(session, runID)) return;
    if (!initialRenderResult) {
      await this.stopActive(session);
      return;
    }

    if (config.motionStyle === 'flowing' && palette.length > 1 && !initialRenderResult.nativeEffectActive) {
      const timerIntervalMs = flowTimerIntervalMs(initialRenderResult, intervalSeconds);
      session.activeTimer = setInterval(() => {
        const phase = initialRenderResult.transport === 'entertainmentStreaming'
          ? ((Date.now() - cycleStartedAt) / (intervalSeconds * 1000)) * palette.length
          : step;
        void apply(phase);
      }, timerIntervalMs);
    }
  }

  private async rendererForTargets(
    session: HueAmbienceGroupSession,
    config: HueAmbienceRuntimeConfig,
    targets: HueResolvedAmbienceTarget[],
  ): Promise<HueAmbienceRenderer> {
    if (this.canReuseActiveRenderer(session, targets) && session.activeRenderer) {
      this.clearActiveTimer(session);
      return session.activeRenderer;
    }

    await this.stopActive(session, false, false);
    const client = this.clientFactory(config);
    return this.rendererFactory(config, client);
  }

  private async stopAllActive(applyStopBehavior = true): Promise<void> {
    const sessions = [...this.sessions.values()];
    await Promise.all(sessions.map(session => this.stopActive(session, applyStopBehavior)));
  }

  private async stopActive(
    session: HueAmbienceGroupSession,
    applyStopBehavior = true,
    removeSession = true,
  ): Promise<void> {
    this.clearActiveTimer(session);
    this.cancelScheduledStop(session);

    const config = this.config;
    const frame = session.activeFrame ?? session.pendingStopFrame;
    const renderer = session.activeRenderer;
    this.clearActiveState(session);
    if (removeSession) {
      this.sessions.delete(session.groupId);
    }

    if (!frame || !renderer) {
      return;
    }

    if (!applyStopBehavior || !config || config.stopBehavior !== 'turnOff') {
      await renderer.release?.().catch(err => {
        this.lastError = err instanceof Error ? err.message : String(err);
        this.log.warn({ err }, 'Hue ambience release failed');
      });
      return;
    }

    try {
      await renderer.stop({ ...frame, reason: 'stop' });
    } catch (err) {
      this.lastError = err instanceof Error ? err.message : String(err);
      this.log.warn({ err }, 'Hue ambience stop failed');
    }
  }

  private clearActiveState(session: HueAmbienceGroupSession): void {
    session.activeTargets = [];
    session.activeTrackKey = null;
    session.activeFrame = null;
    session.pendingStopFrame = null;
    session.activeRenderMode = null;
    session.entertainmentTargetActive = false;
    session.activeEntertainmentMetadataComplete = false;
    session.activeRenderer = null;
  }

  private clearActiveTimer(session: HueAmbienceGroupSession): void {
    if (!session.activeTimer) return;
    clearInterval(session.activeTimer);
    session.activeTimer = null;
  }

  private buildStopFrame(
    targets: HueResolvedAmbienceTarget[],
    snapshot: HueSnapshot,
    transitionSeconds: number,
  ): HueAmbienceFrame {
    return buildHueAmbienceFrame({
      targets,
      palette: [],
      snapshot,
      phase: 0,
      transitionSeconds,
      reason: 'stop',
    });
  }

  private scheduleStopActive(session: HueAmbienceGroupSession): void {
    this.cancelPendingWork(session);
    this.cancelScheduledStop(session);

    if (this.stopGraceMs <= 0) {
      void this.stopActive(session);
      return;
    }

    session.stopTimer = setTimeout(() => {
      session.stopTimer = null;
      void this.stopActive(session);
    }, this.stopGraceMs);
  }

  private cancelPendingWork(session: HueAmbienceGroupSession): number {
    session.runID += 1;
    return session.runID;
  }

  private cancelAllPendingWork(): void {
    for (const session of this.sessions.values()) {
      this.cancelPendingWork(session);
    }
  }

  private isCurrentRun(session: HueAmbienceGroupSession, runID: number): boolean {
    return this.sessions.get(session.groupId) === session && runID === session.runID;
  }

  private cancelScheduledStop(session: HueAmbienceGroupSession): void {
    if (!session.stopTimer) return;
    clearTimeout(session.stopTimer);
    session.stopTimer = null;
  }

  private cancelAllScheduledStops(): void {
    for (const session of this.sessions.values()) {
      this.cancelScheduledStop(session);
    }
  }

  private canReuseActiveRenderer(
    session: HueAmbienceGroupSession,
    targets: HueResolvedAmbienceTarget[],
  ): boolean {
    return session.activeRenderer !== null
      && session.activeTargets.length > 0
      && targetSignature(session.activeTargets) === targetSignature(targets);
  }

  private sessionForSnapshot(snapshot: HueSnapshot): HueAmbienceGroupSession {
    const existing = this.sessions.get(snapshot.groupId);
    if (existing) {
      existing.speakerName = snapshot.speakerName;
      return existing;
    }

    const session: HueAmbienceGroupSession = {
      groupId: snapshot.groupId,
      speakerName: snapshot.speakerName,
      activeTimer: null,
      stopTimer: null,
      activeTargets: [],
      activeTrackKey: null,
      runID: 0,
      activeFrame: null,
      pendingStopFrame: null,
      lastFrameAt: null,
      activeRenderMode: null,
      entertainmentTargetActive: false,
      activeEntertainmentMetadataComplete: false,
      activeRenderer: null,
    };
    this.sessions.set(snapshot.groupId, session);
    return session;
  }

  private activeGroupStatuses(): HueAmbienceActiveGroupStatus[] {
    return [...this.sessions.values()]
      .filter(session => session.activeTargets.length > 0 || session.activeTimer !== null)
      .map(session => ({
        groupId: session.groupId,
        speakerName: session.speakerName,
        activeTargetIds: session.activeTargets.map(target => target.area.id),
        renderMode: session.activeRenderMode,
        entertainmentTargetActive: session.entertainmentTargetActive,
        entertainmentMetadataComplete: session.activeEntertainmentMetadataComplete,
        lastFrameAt: session.lastFrameAt,
        lastTrackKey: session.activeTrackKey,
      }));
  }
}

function aggregateRenderMode(groups: HueAmbienceActiveGroupStatus[]): HueAmbienceRenderMode | null {
  if (groups.some(group => group.renderMode === 'entertainmentStreaming')) return 'entertainmentStreaming';
  if (groups.some(group => group.renderMode === 'streamingReady')) return 'streamingReady';
  if (groups.some(group => group.renderMode === 'clipFallback')) return 'clipFallback';
  return null;
}

function latestFrameAt(groups: HueAmbienceActiveGroupStatus[]): string | null {
  return groups
    .map(group => group.lastFrameAt)
    .filter((value): value is string => Boolean(value))
    .sort()
    .at(-1) ?? null;
}

function uniqueActiveTargetIds(groups: HueAmbienceActiveGroupStatus[]): string[] {
  const ids: string[] = [];
  const seen = new Set<string>();
  for (const group of groups) {
    for (const id of group.activeTargetIds) {
      if (seen.has(id)) continue;
      seen.add(id);
      ids.push(id);
    }
  }
  return ids;
}

function targetSignature(targets: HueResolvedAmbienceTarget[]): string {
  return targets
    .map(target => `${target.area.kind}:${target.area.id}`)
    .join('|');
}

function isGroupedPlayback(snapshot: HueSnapshot): boolean {
  return snapshot.groupMemberCount > 1;
}

function flowTimerIntervalMs(result: HueAmbienceRenderResult, cycleSeconds: number): number {
  if (result.transport !== 'entertainmentStreaming') {
    return Math.max(cycleSeconds, 1) * 1000;
  }

  const cycleMs = Math.max(cycleSeconds, 1) * 1000;
  return Math.min(
    ENTERTAINMENT_FLOW_MAX_FRAME_MS,
    Math.max(ENTERTAINMENT_FLOW_MIN_FRAME_MS, Math.round(cycleMs / 24)),
  );
}
