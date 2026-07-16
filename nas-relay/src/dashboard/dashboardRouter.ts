import { randomUUID, timingSafeEqual } from 'node:crypto';
import { Router, type NextFunction, type Request, type Response } from 'express';
import type { Logger } from 'pino';

import { fetchAlbumArt } from '../artwork/albumArtFetchCache.js';
import type { DeviceLogService } from '../diagnostics/deviceLogs.js';
import type { RelayLogBuffer } from '../diagnostics/relayLogs.js';
import type {
  HueAmbienceCapability,
  HueAmbienceMappingConfiguration,
  HueAmbienceServiceStatus,
  HueAmbienceTarget,
  HueEntertainmentStatus,
  HueSonosMapping,
} from '../hue/hueTypes.js';
import type { ApnsStatus } from '../live-activity/apns.js';
import { resolveMcpTarget, type SonosMcpController, type SonosMcpOptions } from '../mcp/sonosMcpRouter.js';
import { snapshotJson } from '../sonos/relaySnapshotJson.js';
import type { SonosDiscoveryState } from '../sonos/sonos.js';
import { themeColorFromAlbumArtBuffer } from './dashboardArtworkTheme.js';

const COOKIE_NAME = 'charm_dashboard_session';
const DEFAULT_SESSION_TTL_MS = 12 * 60 * 60 * 1_000;

interface CountAndSummaries {
  count(): number;
  summaries(): unknown[];
}

interface DismissalSummaries {
  count(): number;
  activeSummaries(): unknown[];
}

export interface DashboardDependencies {
  sonos: SonosMcpController & {
    discovery: SonosDiscoveryState;
    mergeGroups(sourceGroupId: string, intoGroupId: string): Promise<void>;
    separateGroup(groupId: string): Promise<void>;
    setMemberVolume(groupId: string, memberId: string, volume: number): Promise<void>;
  };
  hue: {
    status(): HueAmbienceServiceStatus;
    entertainmentStatus(): Promise<HueEntertainmentStatus>;
    mappingConfiguration(): HueAmbienceMappingConfiguration | null;
    saveMappings(mappings: HueSonosMapping[]): Promise<void>;
    start(): Promise<void>;
    stop(): Promise<void>;
  };
  apns: { status(): ApnsStatus };
  updateTokens: CountAndSummaries;
  startTokens: CountAndSummaries;
  dismissals: DismissalSummaries;
  deviceLogs: DeviceLogService;
  relayLogs: RelayLogBuffer;
  mcp: SonosMcpOptions;
  version: string;
  artworkTheme?: (url: string) => Promise<string>;
}

export interface DashboardOptions {
  token: string;
  sessionTtlMs: number;
  secureCookie: boolean;
}

export function dashboardOptionsFromEnv(
  env: NodeJS.ProcessEnv = process.env,
  mcpToken = env.MCP_API_TOKEN?.trim() ?? '',
): DashboardOptions {
  const requestedTtlHours = Number(env.DASHBOARD_SESSION_HOURS ?? 12);
  const ttlHours = Number.isFinite(requestedTtlHours)
    ? Math.min(168, Math.max(1, requestedTtlHours))
    : 12;
  return {
    token: env.DASHBOARD_TOKEN?.trim() || mcpToken,
    sessionTtlMs: ttlHours * 60 * 60 * 1_000,
    secureCookie: env.DASHBOARD_SECURE_COOKIE === 'true',
  };
}

export function createDashboardRouter(
  dependencies: DashboardDependencies,
  log: Logger,
  options: DashboardOptions = dashboardOptionsFromEnv(process.env, dependencies.mcp.token),
): Router {
  const router = Router();
  const sessions = new Map<string, number>();
  const artworkThemes = new Map<string, string>();
  const dashboardLog = log.child({ module: 'dashboard' });

  router.use((_req, res, next) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    next();
  });

  router.post('/session', sameOriginOnly, (req, res) => {
    if (!options.token) {
      res.status(503).json({ ok: false, error: 'dashboard_not_configured' });
      return;
    }
    const submitted = typeof req.body?.token === 'string' ? req.body.token.trim() : '';
    if (!safeEqual(submitted, options.token)) {
      dashboardLog.warn({ remoteAddress: req.ip }, 'dashboard login rejected');
      res.status(401).json({ ok: false, error: 'invalid_token' });
      return;
    }

    pruneSessions(sessions);
    const sessionId = randomUUID();
    sessions.set(sessionId, Date.now() + options.sessionTtlMs);
    res.setHeader('Set-Cookie', sessionCookie(sessionId, options));
    res.json({ ok: true, expiresInSeconds: Math.round(options.sessionTtlMs / 1_000) });
  });

  router.get('/session', authenticate(options, sessions), (_req, res) => {
    res.json({ ok: true });
  });

  router.delete('/session', sameOriginOnly, (req, res) => {
    const sessionId = cookieValue(req, COOKIE_NAME);
    if (sessionId) sessions.delete(sessionId);
    res.setHeader('Set-Cookie', expiredSessionCookie(options));
    res.json({ ok: true });
  });

  router.use(authenticate(options, sessions));

  router.get('/artwork-theme', async (req, res) => {
    const url = dashboardArtworkURL(req.query.url);
    if (!url) {
      res.status(400).json({ ok: false, error: 'valid http artwork url required' });
      return;
    }
    const allowed = dependencies.sonos.allSnapshots().some(snapshot => (
      [snapshot.albumArtUri, snapshot.albumArtFallbackUri]
        .some(candidate => dashboardArtworkURL(candidate) === url)
    ));
    if (!allowed) {
      res.status(403).json({ ok: false, error: 'artwork_url_not_in_snapshot' });
      return;
    }

    const cached = artworkThemes.get(url);
    if (cached) {
      res.json({ ok: true, color: cached });
      return;
    }

    try {
      const color = dependencies.artworkTheme
        ? await dependencies.artworkTheme(url)
        : themeColorFromAlbumArtBuffer(await fetchAlbumArt(url));
      if (!/^#[0-9a-f]{6}$/i.test(color)) throw new Error('invalid dashboard artwork theme color');
      rememberArtworkTheme(artworkThemes, url, color);
      res.json({ ok: true, color });
    } catch (error) {
      dashboardLog.warn({ err: error, url }, 'dashboard artwork theme extraction failed');
      res.status(502).json({ ok: false, error: 'artwork_theme_unavailable' });
    }
  });

  router.get('/state', async (_req, res) => {
    try {
      const sonosSnapshots = dependencies.sonos.allSnapshots();
      const [hueEntertainment] = await Promise.all([
        dependencies.hue.entertainmentStatus(),
      ]);
      res.json({
        ok: true,
        generatedAt: new Date().toISOString(),
        relay: {
          version: dependencies.version,
          uptimeSeconds: Math.floor(process.uptime()),
          dashboardConfigured: Boolean(options.token),
        },
        sonos: {
          discovery: dependencies.sonos.discovery,
          groups: sonosSnapshots.map(snapshotJson),
        },
        liveActivity: {
          updateTokenCount: dependencies.updateTokens.count(),
          startTokenCount: dependencies.startTokens.count(),
          dismissedSuppressionCount: dependencies.dismissals.count(),
          sessions: dependencies.updateTokens.summaries(),
          startTokens: dependencies.startTokens.summaries(),
          dismissals: dependencies.dismissals.activeSummaries(),
          apns: dependencies.apns.status(),
        },
        hue: {
          ambience: dependencies.hue.status(),
          entertainment: hueEntertainment,
          mappingSetup: dashboardHueMappingSetup(dependencies.hue.mappingConfiguration()),
        },
        mcp: {
          enabled: Boolean(dependencies.mcp.token),
          path: '/mcp',
          transport: 'streamable-http',
          scope: 'lan',
          auth: 'bearer',
          maxVolume: dependencies.mcp.maxVolume,
          allowedOriginCount: dependencies.mcp.allowedOrigins.length,
        },
      });
    } catch (error) {
      dashboardLog.warn({ err: error }, 'dashboard state aggregation failed');
      res.status(500).json({ ok: false, error: 'state_unavailable' });
    }
  });

  router.get('/logs', (req, res) => {
    const limit = boundedInteger(req.query.limit, 200, 1, 500);
    const source = req.query.source === 'relay' || req.query.source === 'device'
      ? req.query.source
      : 'all';
    const relayEntries = source === 'device' ? [] : dependencies.relayLogs.recent(limit).map(entry => ({
      ...entry,
      source: 'relay' as const,
    }));
    const deviceEntries = source === 'relay' ? [] : dependencies.deviceLogs.recent(limit).map(entry => ({
      id: entry.id,
      timestamp: entry.timestamp ?? entry.receivedAt,
      level: entry.level,
      message: entry.message,
      source: 'device' as const,
      context: {
        category: entry.category,
        clientId: entry.clientId,
        processName: entry.processName,
        sourceIp: entry.sourceIp,
      },
    }));
    const entries = [...relayEntries, ...deviceEntries]
      .sort((left, right) => Date.parse(left.timestamp) - Date.parse(right.timestamp))
      .slice(-limit);
    res.json({ ok: true, entries });
  });

  router.post('/sonos/:action', sameOriginOnly, async (req, res) => {
    const action = req.params.action;
    const target = typeof req.body?.target === 'string' ? req.body.target : '';
    try {
      if (action === 'group') {
        const sourceTarget = typeof req.body?.source === 'string' ? req.body.source : '';
        const intoTarget = typeof req.body?.into === 'string' ? req.body.into : '';
        const snapshots = dependencies.sonos.allSnapshots();
        const source = resolveMcpTarget(sourceTarget, snapshots);
        const into = resolveMcpTarget(intoTarget, snapshots);
        if (source.groupId === into.groupId) {
          res.status(400).json({ ok: false, error: 'source and destination groups must be different' });
          return;
        }
        await dependencies.sonos.mergeGroups(source.groupId, into.groupId);
        dashboardLog.info(
          { action, sourceGroupId: source.groupId, intoGroupId: into.groupId },
          'dashboard Sonos grouping control',
        );
        res.json({ ok: true, groups: dependencies.sonos.allSnapshots().map(snapshotJson) });
        return;
      }

      const resolved = resolveMcpTarget(target, dependencies.sonos.allSnapshots());
      switch (action) {
      case 'play':
        await dependencies.sonos.play(resolved.groupId);
        break;
      case 'pause':
        await dependencies.sonos.pause(resolved.groupId);
        break;
      case 'next':
        await dependencies.sonos.next(resolved.groupId);
        break;
      case 'previous':
        await dependencies.sonos.previous(resolved.groupId);
        break;
      case 'volume': {
        const volume = Number(req.body?.volume);
        if (!Number.isInteger(volume) || volume < 0 || volume > dependencies.mcp.maxVolume) {
          res.status(400).json({ ok: false, error: `volume must be an integer from 0 to ${dependencies.mcp.maxVolume}` });
          return;
        }
        await dependencies.sonos.setGroupVolume(resolved.groupId, volume);
        break;
      }
      case 'member-volume': {
        const memberId = typeof req.body?.memberId === 'string' ? req.body.memberId.trim() : '';
        const volume = Number(req.body?.volume);
        if (!memberId) {
          res.status(400).json({ ok: false, error: 'memberId is required' });
          return;
        }
        if (!Number.isInteger(volume) || volume < 0 || volume > dependencies.mcp.maxVolume) {
          res.status(400).json({ ok: false, error: `volume must be an integer from 0 to ${dependencies.mcp.maxVolume}` });
          return;
        }
        await dependencies.sonos.setMemberVolume(resolved.groupId, memberId, volume);
        break;
      }
      case 'night-mode': {
        if (typeof req.body?.enabled !== 'boolean') {
          res.status(400).json({ ok: false, error: 'enabled must be a boolean' });
          return;
        }
        await dependencies.sonos.setSoundbarNightMode(resolved.groupId, req.body.enabled);
        break;
      }
      case 'speech-enhancement': {
        const level = Number(req.body?.level);
        if (!Number.isInteger(level) || level < 0 || level > 4) {
          res.status(400).json({ ok: false, error: 'level must be an integer from 0 to 4' });
          return;
        }
        await dependencies.sonos.setSoundbarSpeechEnhancementRawLevel(resolved.groupId, level);
        break;
      }
      case 'ungroup':
        await dependencies.sonos.separateGroup(resolved.groupId);
        break;
      default:
        res.status(404).json({ ok: false, error: 'unsupported_action' });
        return;
      }

      dashboardLog.info({ action, groupId: resolved.groupId }, 'dashboard Sonos control');
      const state = dependencies.sonos.current(resolved.groupId);
      res.json({ ok: true, state: state ? snapshotJson(state) : null });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      dashboardLog.warn({ err: error, action, target }, 'dashboard Sonos control failed');
      res.status(message.includes('Unknown Sonos target') || message.includes('unknown_group') ? 404 : 500)
        .json({ ok: false, error: message });
    }
  });

  router.post('/hue/:action', sameOriginOnly, async (req, res) => {
    const action = req.params.action;
    if (action !== 'start' && action !== 'stop') {
      res.status(404).json({ ok: false, error: 'unsupported_action' });
      return;
    }
    try {
      await dependencies.hue[action]();
      dashboardLog.info({ action }, 'dashboard Hue ambience control');
      res.json({ ok: true, state: dependencies.hue.status() });
    } catch (error) {
      dashboardLog.warn({ err: error, action }, 'dashboard Hue ambience control failed');
      res.status(500).json({ ok: false, error: `hue_${action}_failed` });
    }
  });

  router.put('/hue/mapping', sameOriginOnly, async (req, res) => {
    const groupId = typeof req.body?.groupId === 'string' ? req.body.groupId.trim() : '';
    const group = dependencies.sonos.allSnapshots().find(snapshot => snapshot.groupId === groupId);
    if (!group) {
      res.status(404).json({ ok: false, error: 'unknown_sonos_group' });
      return;
    }

    const config = dependencies.hue.mappingConfiguration();
    if (!config) {
      res.status(409).json({ ok: false, error: 'hue_not_configured' });
      return;
    }

    const targetResult = dashboardHueTarget(req.body?.target, config);
    if (!targetResult.ok) {
      res.status(400).json({ ok: false, error: targetResult.error });
      return;
    }

    try {
      const mappings = updateDashboardHueMapping(config, group, targetResult.target);
      await dependencies.hue.saveMappings(mappings);
      dashboardLog.info(
        { groupId, target: targetResult.target },
        'dashboard Hue mapping updated',
      );
      res.json({
        ok: true,
        mappingSetup: dashboardHueMappingSetup(dependencies.hue.mappingConfiguration()),
      });
    } catch (error) {
      dashboardLog.warn({ err: error, groupId }, 'dashboard Hue mapping update failed');
      res.status(500).json({ ok: false, error: 'hue_mapping_save_failed' });
    }
  });

  return router;
}

function authenticate(options: DashboardOptions, sessions: Map<string, number>) {
  return (req: Request, res: Response, next: NextFunction): void => {
    if (!options.token) {
      res.status(503).json({ ok: false, error: 'dashboard_not_configured' });
      return;
    }
    const sessionId = cookieValue(req, COOKIE_NAME);
    const expiresAt = sessionId ? sessions.get(sessionId) : undefined;
    if (!sessionId || !expiresAt || expiresAt <= Date.now()) {
      if (sessionId) sessions.delete(sessionId);
      res.status(401).json({ ok: false, error: 'dashboard_auth_required' });
      return;
    }
    next();
  };
}

function sameOriginOnly(req: Request, res: Response, next: NextFunction): void {
  const origin = req.get('origin');
  if (!origin) {
    next();
    return;
  }
  try {
    if (new URL(origin).host !== req.get('host')) {
      res.status(403).json({ ok: false, error: 'origin_not_allowed' });
      return;
    }
  } catch {
    res.status(403).json({ ok: false, error: 'origin_not_allowed' });
    return;
  }
  next();
}

function safeEqual(left: string, right: string): boolean {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}

function cookieValue(req: Request, name: string): string | undefined {
  const encodedName = `${name}=`;
  for (const part of (req.get('cookie') ?? '').split(';')) {
    const trimmed = part.trim();
    if (trimmed.startsWith(encodedName)) return decodeURIComponent(trimmed.slice(encodedName.length));
  }
  return undefined;
}

function sessionCookie(sessionId: string, options: DashboardOptions): string {
  const secure = options.secureCookie ? '; Secure' : '';
  return `${COOKIE_NAME}=${encodeURIComponent(sessionId)}; HttpOnly; SameSite=Strict; Path=/api/dashboard; Max-Age=${Math.round(options.sessionTtlMs / 1_000)}${secure}`;
}

function expiredSessionCookie(options: DashboardOptions): string {
  const secure = options.secureCookie ? '; Secure' : '';
  return `${COOKIE_NAME}=; HttpOnly; SameSite=Strict; Path=/api/dashboard; Max-Age=0${secure}`;
}

function pruneSessions(sessions: Map<string, number>, now = Date.now()): void {
  for (const [sessionId, expiresAt] of sessions) {
    if (expiresAt <= now) sessions.delete(sessionId);
  }
}

function boundedInteger(value: unknown, fallback: number, min: number, max: number): number {
  const parsed = typeof value === 'string' ? Number.parseInt(value, 10) : Number.NaN;
  return Number.isFinite(parsed) ? Math.min(max, Math.max(min, parsed)) : fallback;
}

function dashboardArtworkURL(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 2_048) return null;
  try {
    const url = new URL(value.trim());
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.toString() : null;
  } catch {
    return null;
  }
}

function rememberArtworkTheme(cache: Map<string, string>, url: string, color: string): void {
  cache.set(url, color);
  while (cache.size > 200) {
    const oldest = cache.keys().next().value;
    if (!oldest) return;
    cache.delete(oldest);
  }
}

function dashboardHueMappingSetup(config: HueAmbienceMappingConfiguration | null) {
  if (!config) return { targets: [], assignments: [] };
  const targets = config.resources.areas
    .filter(area => area.kind !== 'light')
    .map(area => ({
      id: area.id,
      name: area.name,
      kind: area.kind,
      lightCount: area.childLightIDs.length,
      capability: capabilityForHueArea(area, config),
    }))
    .sort((left, right) => {
      const kindOrder = { entertainmentArea: 0, room: 1, zone: 2 } as const;
      const rank = kindOrder[left.kind as keyof typeof kindOrder] - kindOrder[right.kind as keyof typeof kindOrder];
      return rank || left.name.localeCompare(right.name);
    });
  const assignments = config.mappings.flatMap(mapping => {
    const target = effectiveHueMappingTarget(mapping);
    if (!target || target.kind === 'light') return [];
    return [{
      sonosID: mapping.sonosID,
      sonosName: mapping.sonosName,
      relayGroupID: mapping.relayGroupID ?? null,
      target,
      capability: mapping.capability,
    }];
  });
  return { targets, assignments };
}

function dashboardHueTarget(
  value: unknown,
  config: HueAmbienceMappingConfiguration,
): { ok: true; target: HueAmbienceTarget | null } | { ok: false; error: string } {
  if (value === null) return { ok: true, target: null };
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return { ok: false, error: 'target must be a Hue group or null' };
  }
  const record = value as Record<string, unknown>;
  if (typeof record.kind !== 'string' || typeof record.id !== 'string') {
    return { ok: false, error: 'target kind and id are required' };
  }
  const area = config.resources.areas.find(candidate => (
    candidate.kind !== 'light'
    && candidate.kind === record.kind
    && candidate.id === record.id
  ));
  if (!area) return { ok: false, error: 'unknown_hue_group' };
  return { ok: true, target: { kind: area.kind, id: area.id } };
}

function updateDashboardHueMapping(
  config: HueAmbienceMappingConfiguration,
  group: ReturnType<DashboardDependencies['sonos']['allSnapshots']>[number],
  target: HueAmbienceTarget | null,
): HueSonosMapping[] {
  const matchingIndex = config.mappings.findIndex(mapping => mappingMatchesSonosGroup(mapping, group));
  if (!target) {
    return config.mappings.filter((_mapping, index) => index !== matchingIndex);
  }

  const area = config.resources.areas.find(candidate => candidate.kind === target.kind && candidate.id === target.id)!;
  const current = matchingIndex >= 0 ? config.mappings[matchingIndex] : null;
  const currentTarget = current ? effectiveHueMappingTarget(current) : null;
  const targetUnchanged = currentTarget?.kind === target.kind && currentTarget.id === target.id;
  const mapping: HueSonosMapping = {
    sonosID: current?.sonosID ?? group.groupId,
    sonosName: group.speakerName,
    relayGroupID: group.groupId,
    preferredTarget: target,
    fallbackTarget: null,
    includedLightIDs: target.kind === 'entertainmentArea' || !targetUnchanged
      ? []
      : current?.includedLightIDs ?? [],
    excludedLightIDs: target.kind === 'entertainmentArea' || !targetUnchanged
      ? []
      : current?.excludedLightIDs ?? [],
    capability: capabilityForHueArea(area, config),
  };
  if (matchingIndex < 0) return [...config.mappings, mapping];
  return config.mappings.map((existing, index) => index === matchingIndex ? mapping : existing);
}

function mappingMatchesSonosGroup(
  mapping: HueSonosMapping,
  group: ReturnType<DashboardDependencies['sonos']['allSnapshots']>[number],
): boolean {
  return mapping.relayGroupID === group.groupId
    || mapping.sonosID === group.groupId
    || mapping.sonosName === group.speakerName;
}

function effectiveHueMappingTarget(mapping: HueSonosMapping): HueAmbienceTarget | null {
  const preferred = mapping.preferredTarget?.kind === 'light' ? null : mapping.preferredTarget;
  const fallback = mapping.fallbackTarget?.kind === 'light' ? null : mapping.fallbackTarget;
  return preferred ?? fallback ?? null;
}

function capabilityForHueArea(
  area: HueAmbienceMappingConfiguration['resources']['areas'][number],
  config: HueAmbienceMappingConfiguration,
): HueAmbienceCapability {
  if (area.kind === 'entertainmentArea') return 'liveEntertainment';
  const childLightIDs = new Set(area.childLightIDs);
  return config.resources.lights.some(light => childLightIDs.has(light.id) && light.supportsGradient)
    ? 'gradientReady'
    : 'basic';
}

export const dashboardDefaults = {
  sessionTtlMs: DEFAULT_SESSION_TTL_MS,
};
