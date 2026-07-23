import express from 'express';
import pino from 'pino';
import pinoHttp from 'pino-http';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SonosBridge, type SonosSnapshotChangeContext } from './sonos/sonos.js';
import { createInternalSonosRouter, internalAuthMiddleware } from './sonos/internalSonosRoutes.js';
import { ApnsClient } from './live-activity/apns.js';
import { TokenStore } from './live-activity/tokenStore.js';
import { HueAmbienceConfigStore } from './hue/hueConfigStore.js';
import { HueAmbienceService } from './hue/hueAmbienceService.js';
import { createHueAmbienceRouter } from './hue/hueRoutes.js';
import { createHueMusicAmbienceRenderer } from './hue/hueMusicAmbienceRenderer.js';
import { AnimatedAppleMusicArtworkResolver } from './artwork/animatedAppleMusicArtwork.js';
import { createAnimatedArtworkRouter } from './artwork/animatedArtworkRoutes.js';
import { appleMusicCatalogIDFromSonosValues } from './artwork/sonosArtworkResolver.js';
import { createArtworkRouter } from './artwork/artworkRoutes.js';
import { createPlaybackStateRouter } from './sonos/playbackStateRoutes.js';
import { DeviceLogService } from './diagnostics/deviceLogs.js';
import { RelayLogBuffer } from './diagnostics/relayLogs.js';
import { createDeviceLogRouter } from './diagnostics/deviceLogRoutes.js';
import { shouldIgnoreHttpAutoLog } from './transport/httpLogging.js';
import {
  createSonosMcpRouter,
  sonosMcpOptionsFromEnv,
} from './mcp/sonosMcpRouter.js';
import {
  buildLiveActivityContentState,
  hashLiveActivityContentState,
} from './live-activity/liveActivityContentState.js';
import { maybeStartLiveActivityForSnapshot } from './live-activity/liveActivityStartCoordinator.js';
import {
  LiveActivityPreferenceStore,
  type LiveActivityPreferencesRequest,
} from './live-activity/liveActivityPreferences.js';
import {
  LiveActivityPushInFlightRegistry,
} from './live-activity/liveActivityPushPolicy.js';
import { snapshotJson } from './sonos/relaySnapshotJson.js';
import { publishRelayBonjour, type RelayBonjourAdvertisement } from './transport/bonjour.js';
import { StartTokenStore } from './live-activity/startTokenStore.js';
import { LiveActivityDismissalStore } from './live-activity/liveActivityDismissalStore.js';
import { NowPlayingTokenStore } from './now-playing/nowPlayingTokenStore.js';
import {
  buildNowPlayingAttributes,
  hashNowPlayingAttributes,
  isNowPlayingActive,
  NowPlayingSessionGenerationRegistry,
  shouldSendNowPlayingStart,
} from './now-playing/nowPlayingState.js';
import { createDashboardRouter, dashboardOptionsFromEnv } from './dashboard/dashboardRouter.js';
import type {
  LiveActivityContentState,
  LiveActivityDismissedRequest,
  NowPlayingRegisterRequest,
  NowPlayingTokenEntry,
  PushToStartRegisterRequest,
  PushToStartTokenEntry,
  RegisterRequest,
  SonosGroupSnapshot,
  TokenEntry,
} from './types.js';

const relayLogs = new RelayLogBuffer();
const log = pino({
  level: process.env.LOG_LEVEL ?? 'info',
  transport: process.env.NODE_ENV === 'production' ? undefined : { target: 'pino-pretty' },
  hooks: {
    logMethod(args, method, level) {
      relayLogs.capture(level, [this.bindings(), ...args]);
      method.apply(this, args);
    },
  },
});

const RELAY_PORT = Number(process.env.RELAY_PORT ?? 8787);
const SEED_IP = process.env.SONOS_SEED_IP?.trim() || undefined;
const DATA_DIR = process.env.DATA_DIR ?? '/app/data';
const DEFAULT_APNS_BUNDLE_ID = 'com.charm.SonosWidget';
const DEFAULT_APNS_TEAM_ID = '3MSS7DJGVR';
// iOS 27 beta currently issues RemoteMediaSession tokens for production APNs
// even to a development-signed build. Keep the project's existing production
// topic key as the debug-relay fallback while allowing every field to be
// overridden for other deployments.
const DEFAULT_NOW_PLAYING_APNS_KEY_ID = '4K6LLXCPPN';
const DEFAULT_LIVE_ACTIVITY_DISMISS_SUPPRESS_SECONDS = 30 * 60;
const DASHBOARD_PUBLIC_DIR = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../public/dashboard',
);
const HLS_JS_FILE = createRequire(import.meta.url).resolve('hls.js/dist/hls.min.js');

async function main(): Promise<void> {
  // ---- core wiring ------------------------------------------------------
  const tokens = new TokenStore(DATA_DIR, log);
  await tokens.load();
  const startTokens = new StartTokenStore(DATA_DIR, log);
  await startTokens.load();
  const liveActivityDismissals = new LiveActivityDismissalStore(DATA_DIR, log);
  await liveActivityDismissals.load();
  const nowPlayingTokens = new NowPlayingTokenStore(DATA_DIR, log);
  await nowPlayingTokens.load();
  const hueConfigStore = new HueAmbienceConfigStore(DATA_DIR);
  const hueAmbience = new HueAmbienceService(
    hueConfigStore,
    log.child({ module: 'hue-ambience' }),
    undefined,
    undefined,
    undefined,
    (config, client) => createHueMusicAmbienceRenderer(config, client),
  );
  await hueAmbience.load();
  const deviceLogs = new DeviceLogService();
  const animatedArtwork = new AnimatedAppleMusicArtworkResolver({
    dataDir: DATA_DIR,
    enabled: (process.env.ANIMATED_ARTWORK_ENABLED ?? 'true') !== 'false',
  });

  const apnsConfig = {
    bundleId: process.env.APNS_BUNDLE_ID ?? DEFAULT_APNS_BUNDLE_ID,
    keyPath: process.env.APNS_KEY_PATH ?? path.join(DATA_DIR, 'apns.p8'),
    keyId: process.env.APNS_KEY_ID ?? '',
    teamId: process.env.APNS_TEAM_ID ?? DEFAULT_APNS_TEAM_ID,
    production: (process.env.APNS_PRODUCTION ?? 'false') === 'true',
  };
  const apns = await ApnsClient.create(apnsConfig, log);

  const nowPlayingProduction = (process.env.NOW_PLAYING_APNS_PRODUCTION ?? 'true') === 'true';
  const nowPlayingAnimatedArtworkEnabled =
    (process.env.NOW_PLAYING_ANIMATED_ARTWORK_ENABLED ?? 'true') === 'true';
  const nowPlayingKeyId = process.env.NOW_PLAYING_APNS_KEY_ID?.trim()
    || (apnsConfig.production ? apnsConfig.keyId : DEFAULT_NOW_PLAYING_APNS_KEY_ID);
  const nowPlayingApns = await ApnsClient.create(
    {
      bundleId: process.env.NOW_PLAYING_APNS_BUNDLE_ID ?? apnsConfig.bundleId,
      keyPath: process.env.NOW_PLAYING_APNS_KEY_PATH
        ?? (apnsConfig.production
          ? apnsConfig.keyPath
          : path.join(DATA_DIR, `AuthKey_${nowPlayingKeyId}.p8`)),
      keyId: nowPlayingKeyId,
      teamId: process.env.NOW_PLAYING_APNS_TEAM_ID ?? apnsConfig.teamId,
      production: nowPlayingProduction,
    },
    log,
  );

  const sonos = new SonosBridge(log);
  await sonos.start(SEED_IP);
  const mcpOptions = sonosMcpOptionsFromEnv();
  const dashboardOptions = dashboardOptionsFromEnv(process.env, mcpOptions.token);
  const liveActivityPreferences = new LiveActivityPreferenceStore();
  const liveActivityPushesInFlight = new LiveActivityPushInFlightRegistry();
  const liveActivityArtworkLog = log.child({ module: 'live-activity-artwork' });
  const nowPlayingSessionGenerations = new NowPlayingSessionGenerationRegistry();

  // ---- snapshot → APNs pipeline ----------------------------------------
  type LiveActivityPushTrigger =
    | SonosSnapshotChangeContext['trigger']
    | 'register-initial'
    | 'app-preferences';

  async function pushLiveActivitySnapshot(
    snap: SonosGroupSnapshot,
    trigger: LiveActivityPushTrigger,
    options: { force?: boolean; logNoTokens?: boolean } = {},
  ): Promise<void> {
    const force = options.force === true;
    const matching = tokens.forGroup(snap.groupId);
    if (matching.length === 0) {
      if (options.logNoTokens !== false) {
        log.info(
          {
            source: 'relay',
            action: 'skip',
            trigger,
            reason: 'no-registered-tokens',
            groupId: snap.groupId,
            snapshot: summarizeSnapshot(snap),
          },
          'live_activity',
        );
      }
      return;
    }

    const enrichedSnap = liveActivityPreferences.apply(snap);
    const relevanceScore = liveActivityPreferences.relevanceScoreForGroup(enrichedSnap.groupId);
    const state = await buildLiveActivityContentState(enrichedSnap, {
      logger: liveActivityArtworkLog,
      logContext: { trigger, force },
    });
    const hash = hashLiveActivityContentState(state);
    log.debug(
      {
        source: 'relay',
        action: 'state-built',
        trigger,
        force,
        groupId: snap.groupId,
        registeredTokens: matching.length,
        relevanceScore,
        hash,
        state: summarizeLiveActivityState(state),
      },
      'live_activity',
    );

    // Skip no-op pushes for every Sonos refresh, including the one-minute
    // safety poll. Progress-only changes are intentionally absent from the
    // content hash, so APNs is used only for user-visible state changes.
    const targets = liveActivityPushesInFlight.acquire(matching, hash, { force });
    if (targets.length === 0) {
      log.debug(
        {
          source: 'relay',
          action: 'skip',
          trigger,
          force,
          reason: 'last-sent-hash-match-or-in-flight',
          groupId: snap.groupId,
          registeredTokens: matching.length,
          relevanceScore,
          hash,
          state: summarizeLiveActivityState(state),
        },
        'live_activity',
      );
      return;
    }

    try {
      const result = await apns.pushUpdate(
        targets.map(t => t.token),
        state,
        relevanceScore,
      );
      for (const t of targets) {
        tokens.recordSent(t.token, hash);
      }
      for (const dead of result.unregistered) tokens.unregister(dead);

      log.info(
        {
          source: 'relay',
          action: 'apns-update',
          trigger,
          force,
          groupId: snap.groupId,
          tokenCount: targets.length,
          relevanceScore,
          sent: result.sent,
          failed: result.failed,
          unregistered: result.unregistered.map(shortToken),
          hash,
          state: summarizeLiveActivityState(state),
        },
        'live_activity',
      );
    } finally {
      liveActivityPushesInFlight.release(targets, hash);
    }
  }

  async function tryStartLiveActivitySnapshot(
    snap: SonosGroupSnapshot,
    trigger: string,
    startTokenEntries: PushToStartTokenEntry[],
    activityTokenEntries: TokenEntry[],
    options: { bypassCooldown?: boolean } = {},
  ): Promise<void> {
    const now = new Date();
    const relevanceScore = liveActivityPreferences.relevanceScoreForGroup(snap.groupId);
    try {
      const result = await maybeStartLiveActivityForSnapshot({
        snap,
        startTokens: startTokenEntries,
        activityTokens: activityTokenEntries,
        startSuppressions: liveActivityDismissals.activeForGroup(snap.groupId, now),
        buildState: buildSnap => buildLiveActivityContentState(buildSnap, {
          logger: liveActivityArtworkLog,
          logContext: { trigger },
        }),
        pushStart: (targetTokens, attributes, state) => (
          apns.pushStart(targetTokens, attributes, state, relevanceScore)
        ),
        recordStart: (token, date, groupId) => startTokens.recordStart(token, date, groupId),
        unregisterStartToken: token => startTokens.unregister(token),
        now,
        bypassCooldown: options.bypassCooldown,
      });

      log[result.reason === 'start' ? 'info' : 'debug'](
        {
          source: 'relay',
          action: result.reason === 'start' ? 'apns-start' : 'skip',
          trigger,
          reason: result.reason,
          groupId: snap.groupId,
          startTokenCount: startTokenEntries.length,
          activityTokenCount: activityTokenEntries.length,
          suppressionCount: liveActivityDismissals.activeForGroup(snap.groupId, now).length,
          relevanceScore,
          sent: result.sent,
          failed: result.failed,
          bypassCooldown: options.bypassCooldown === true,
          snapshot: summarizeSnapshot(snap),
        },
        'live_activity',
      );
    } catch (err) {
      log.warn(
        {
          err,
          source: 'relay',
          action: 'apns-start',
          trigger,
          groupId: snap.groupId,
          startTokenCount: startTokenEntries.length,
          activityTokenCount: activityTokenEntries.length,
          bypassCooldown: options.bypassCooldown === true,
          snapshot: summarizeSnapshot(snap),
        },
        'live_activity',
      );
    }
  }

  async function pushNowPlayingSnapshot(
    snap: SonosGroupSnapshot,
    trigger: string,
    options: { forceUpdateToken?: string; forceStartToken?: string } = {},
  ): Promise<void> {
    const allUpdateEntries = nowPlayingTokens.forGroup(snap.groupId, 'update');
    if (!isNowPlayingActive(snap)) {
      for (const entry of allUpdateEntries) {
        const result = await nowPlayingApns.pushNowPlayingEnd([entry.token], entry.sessionId);
        for (const dead of result.unregistered) nowPlayingTokens.unregister('update', dead);
        if (result.sent > 0) nowPlayingTokens.unregister('update', entry.token);
        log.info({
          source: 'relay',
          action: 'apns-end',
          trigger,
          groupId: snap.groupId,
          sessionId: entry.sessionId,
          sent: result.sent,
          failed: result.failed,
        }, 'now_playing');
      }
      // A push-to-start token creates a session once. Arm it again only after
      // playback has actually ended so later playback can create a new one.
      nowPlayingTokens.resetStartSentForGroup(snap.groupId);
      nowPlayingSessionGenerations.end(snap.groupId);
      return;
    }

    const startEntries = nowPlayingTokens.forGroup(snap.groupId, 'start');
    const sessionGeneration = nowPlayingSessionGenerations.active(
      snap.groupId,
      [...allUpdateEntries, ...startEntries],
    );
    const updateEntries = allUpdateEntries.filter(
      entry => entry.sessionGeneration === sessionGeneration,
    );
    const targets: NowPlayingTokenEntry[] = options.forceStartToken
      ? startEntries.filter(entry => entry.token === options.forceStartToken)
      : updateEntries.length > 0
        ? updateEntries
        : startEntries;
    if (targets.length === 0) return;

    const animatedKey = nowPlayingAnimatedArtworkEnabled
      ? nowPlayingAnimatedArtworkKey(snap)
      : null;
    const animatedArtworkURLString = animatedKey
      && nowPlayingAnimatedArtworkURLs.has(animatedKey)
      ? nowPlayingAnimatedArtworkURLs.get(animatedKey) ?? null
      : null;
    for (const entry of targets) {
      const attributes = buildNowPlayingAttributes(
        snap,
        entry,
        animatedArtworkURLString,
        sessionGeneration,
      );
      const hash = hashNowPlayingAttributes(attributes);
      const force = (entry.kind === 'update' && options.forceUpdateToken === entry.token)
        || (entry.kind === 'start' && options.forceStartToken === entry.token);
      // Once APNs accepted a start, wait for the extension's per-session
      // update token. Reusing the start token for metadata changes attempts to
      // create the same session again and can discard its representation.
      if (!force && entry.kind === 'start' && entry.lastSentHash) {
        log.debug({
          source: 'relay',
          action: 'skip',
          trigger,
          reason: 'start-already-sent-awaiting-update-token',
          groupId: snap.groupId,
          sessionId: entry.sessionId,
        }, 'now_playing');
        continue;
      }
      if (!force && entry.lastSentHash === hash) {
        log.debug({
          source: 'relay',
          action: 'skip',
          trigger,
          reason: 'last-sent-hash-match',
          kind: entry.kind,
          groupId: snap.groupId,
          sessionId: entry.sessionId,
        }, 'now_playing');
        continue;
      }

      const result = entry.kind === 'update'
        ? await nowPlayingApns.pushNowPlayingUpdate([entry.token], attributes)
        : await nowPlayingApns.pushNowPlayingStart([entry.token], attributes);
      for (const dead of result.unregistered) nowPlayingTokens.unregister(entry.kind, dead);
      if (result.sent > 0) {
        nowPlayingTokens.recordSent(entry, hash, sessionGeneration);
      }
      log.info({
        source: 'relay',
        action: entry.kind === 'update' ? 'apns-update' : 'apns-start',
        trigger,
        groupId: snap.groupId,
        sessionId: entry.sessionId,
        sessionGeneration,
        sent: result.sent,
        failed: result.failed,
        title: attributes.title,
        artworkURLString: attributes.artworkURLString ?? null,
        artworkFallbackURLString: attributes.artworkFallbackURLString ?? null,
        animatedArtworkURLString: attributes.animatedArtworkURLString ?? null,
      }, 'now_playing');
    }
    if (nowPlayingAnimatedArtworkEnabled) {
      scheduleNowPlayingAnimatedArtworkResolution(snap);
    }
  }

  const nowPlayingAnimatedArtworkURLs = new Map<string, string | null>();
  const nowPlayingAnimatedArtworkInFlight = new Set<string>();

  function scheduleNowPlayingAnimatedArtworkResolution(snap: SonosGroupSnapshot): void {
    const key = nowPlayingAnimatedArtworkKey(snap);
    if (!key
      || nowPlayingAnimatedArtworkURLs.has(key)
      || nowPlayingAnimatedArtworkInFlight.has(key)) {
      return;
    }

    nowPlayingAnimatedArtworkInFlight.add(key);
    void (async () => {
      const resolution = await animatedArtwork.resolveByMetadata(
        snap.artist,
        snap.album,
        null,
        appleMusicCatalogIDFromSonosValues(snap.trackUri, snap.albumArtUri),
      );
      if (resolution.status === 'hit' || resolution.status === 'miss'
        || resolution.status === 'negative-cache' || resolution.status === 'disabled') {
        nowPlayingAnimatedArtworkURLs.set(
          key,
          resolution.status === 'hit' ? resolution.squareUrl : null,
        );
        if (nowPlayingAnimatedArtworkURLs.size > 128) {
          const oldest = nowPlayingAnimatedArtworkURLs.keys().next().value;
          if (oldest) nowPlayingAnimatedArtworkURLs.delete(oldest);
        }
      }

      const latest = sonos.current(snap.groupId);
      if (latest
        && nowPlayingAnimatedArtworkKey(latest) === key
        && resolution.status === 'hit'
        && resolution.squareUrl) {
        await pushNowPlayingSnapshot(latest, 'animated-artwork-ready');
      }
    })().catch(err => {
      log.warn({ err, groupId: snap.groupId }, 'now playing animated artwork resolution failed');
    }).finally(() => {
      nowPlayingAnimatedArtworkInFlight.delete(key);
    });
  }

  function nowPlayingAnimatedArtworkKey(snap: SonosGroupSnapshot): string | null {
    const artist = snap.artist.trim().toLocaleLowerCase();
    const album = snap.album.trim().toLocaleLowerCase();
    return artist && album ? `${artist}|${album}` : null;
  }

  sonos.on('change', async (
    snap: SonosGroupSnapshot,
    context?: SonosSnapshotChangeContext,
  ) => {
    hueAmbience.receiveSnapshot(snap);

    const trigger = context?.trigger ?? 'sonos-change';
    const enrichedSnap = liveActivityPreferences.apply(snap);
    await tryStartLiveActivitySnapshot(
      enrichedSnap,
      `${trigger}:start`,
      startTokens.forGroup(snap.groupId),
      tokens.forGroup(snap.groupId),
    );
    await pushLiveActivitySnapshot(snap, trigger, {
      logNoTokens: trigger !== 'periodic-refresh',
    });
    await pushNowPlayingSnapshot(snap, trigger);
  });

  // ---- HTTP -------------------------------------------------------------
  const app = express();
  app.use(express.json({ limit: '512kb' }));
  app.use(
    pinoHttp({
      logger: log,
      autoLogging: { ignore: shouldIgnoreHttpAutoLog },
      // Don't log the full body; tokens are sensitive-ish.
      serializers: { req: req => ({ method: req.method, url: req.url }) },
    }),
  );

  app.use('/internal', internalAuthMiddleware(log), createInternalSonosRouter(sonos, log));
  app.use('/mcp', createSonosMcpRouter(sonos, log, mcpOptions));
  app.use('/api/dashboard', createDashboardRouter({
    sonos,
    hue: hueAmbience,
    apns,
    updateTokens: tokens,
    startTokens,
    dismissals: liveActivityDismissals,
    deviceLogs,
    relayLogs,
    mcp: mcpOptions,
    version: process.env.APP_VERSION?.trim() || '0.1.0',
  }, log, dashboardOptions));
  app.use('/api', createPlaybackStateRouter(sonos));
  app.use('/api', createHueAmbienceRouter(hueAmbience, log));
  app.use('/api', createDeviceLogRouter(deviceLogs, log.child({ module: 'device-logs' })));
  app.use('/api', createArtworkRouter(log.child({ module: 'artwork' })));
  app.use('/api', createAnimatedArtworkRouter(
    log.child({ module: 'animated-artwork' }),
    animatedArtwork,
  ));
  app.get('/dashboard/vendor/hls.min.js', (_req, res) => {
    res.type('application/javascript');
    res.setHeader('Cache-Control', 'public, max-age=2592000, immutable');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.sendFile(HLS_JS_FILE);
  });
  app.use('/dashboard', express.static(DASHBOARD_PUBLIC_DIR, {
    index: 'index.html',
    maxAge: process.env.NODE_ENV === 'production' ? '1h' : 0,
    setHeaders: res => {
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.setHeader('Referrer-Policy', 'no-referrer');
      res.setHeader('X-Frame-Options', 'DENY');
      res.setHeader(
        'Content-Security-Policy',
        "default-src 'self'; img-src 'self' http: https: data:; media-src 'self' https: blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self' https:; worker-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
      );
    },
  }));
  app.get('/', (_req, res) => res.redirect('/dashboard/'));

  app.get('/api/health', async (_req, res) => {
    const hueAmbienceStatus = hueAmbience.status();
    const hueEntertainmentStatus = await hueAmbience.entertainmentStatus();
    res.json({
      ok: true,
      sonos: {
        discoveryMode: sonos.discovery.mode,
        discoveryStatus: sonos.discovery.status,
        discoveryError: sonos.discovery.error,
      },
      mcp: {
        enabled: Boolean(mcpOptions.token),
        path: '/mcp',
        transport: 'streamable-http',
        scope: 'lan',
        auth: 'bearer',
        maxVolume: mcpOptions.maxVolume,
      },
      dashboard: {
        enabled: Boolean(dashboardOptions.token),
        path: '/dashboard/',
      },
      apns: apns.status(),
      liveActivity: {
        startTokenCount: startTokens.count(),
        updateTokenCount: tokens.count(),
        dismissedSuppressionCount: liveActivityDismissals.count(),
      },
      nowPlaying: {
        apns: nowPlayingApns.status(),
        startTokenCount: nowPlayingTokens.count('start'),
        updateTokenCount: nowPlayingTokens.count('update'),
      },
      groups: sonos.allSnapshots().map(s => ({
        groupId: s.groupId,
        speakerName: s.speakerName,
        isPlaying: s.isPlaying,
        title: s.trackTitle,
        playbackSourceRaw: s.playbackSourceRaw,
        musicAmbienceEligible: s.musicAmbienceEligible,
      })),
      hueAmbience: hueAmbienceStatus,
      hueEntertainment: hueEntertainmentStatus,
    });
  });

  /// iOS posts here right after `Activity.request(pushType: .token)` resolves
  /// and on every `pushTokenUpdates` rotation. Body shape: `RegisterRequest`.
  /// Replies with the current ContentState so the iOS side can sanity-check
  /// what the server thinks is playing without waiting for the next event.
  app.post('/api/register-push-to-start', async (req, res) => {
    const body = req.body as Partial<PushToStartRegisterRequest>;
    if (!body.groupId || !body.token) {
      res.status(400).json({ error: 'groupId and token are required' });
      return;
    }

    const activeActivityIds = Array.isArray(body.activeActivityIds)
      ? body.activeActivityIds
        .filter((id): id is string => typeof id === 'string' && id.trim().length > 0)
        .map(id => id.trim())
      : undefined;

    log.info(
      {
        source: 'relay',
        action: 'register-push-to-start-request',
        groupId: body.groupId,
        token: shortToken(body.token),
        clientId: body.clientId ?? null,
        speakerName: body.speakerName ?? null,
        liveActivityStyleRaw: body.liveActivityStyleRaw ?? null,
        activeActivityCount: activeActivityIds?.length ?? null,
        clearDismissalSuppression: body.clearDismissalSuppression === true,
      },
      'live_activity',
    );
    const entry = startTokens.register({
      groupId: body.groupId,
      token: body.token,
      clientId: body.clientId,
      speakerName: body.speakerName,
      liveActivityStyleRaw: body.liveActivityStyleRaw,
    });
    if (body.clearDismissalSuppression === true) {
      const removed = liveActivityDismissals.clearForActivity(body.groupId, body.clientId);
      log.info(
        {
          source: 'relay',
          action: 'dismissal-suppression-clear',
          trigger: 'register-push-to-start',
          groupId: body.groupId,
          clientId: body.clientId ?? null,
          removed,
        },
        'live_activity',
      );
    }
    liveActivityPreferences.update({
      groupId: body.groupId,
      liveActivityStyleRaw: body.liveActivityStyleRaw,
    });
    if (activeActivityIds !== undefined) {
      const removed = tokens.pruneStaleClientActivities(
        body.groupId,
        body.clientId,
        activeActivityIds,
      );
      log.info(
        {
          source: 'relay',
          action: 'activity-token-prune',
          groupId: body.groupId,
          clientId: body.clientId ?? null,
          activeActivityCount: activeActivityIds.length,
          removed,
        },
        'live_activity',
      );
    }

    const snap = sonos.current(body.groupId);
    if (snap?.isPlaying) {
      await tryStartLiveActivitySnapshot(
        liveActivityPreferences.apply(snap),
        'register-push-to-start:start',
        [entry],
        tokens.forGroup(body.groupId),
      );
    } else {
      log.info(
        {
          source: 'relay',
          action: 'skip',
          trigger: 'register-push-to-start:start',
          reason: snap ? 'not-playing' : 'no-current-snapshot',
          groupId: body.groupId,
          token: shortToken(body.token),
          snapshot: snap ? summarizeSnapshot(snap) : null,
        },
        'live_activity',
      );
    }

    res.json({ ok: true });
  });

  app.post('/api/now-playing/register', async (req, res) => {
    const body = req.body as Partial<NowPlayingRegisterRequest>;
    if ((body.kind !== 'start' && body.kind !== 'update')
      || !body.groupId
      || !body.token
      || !body.sessionId
      || !body.clientId
      || !body.speakerName
      || !body.relayURLString) {
      res.status(400).json({
        ok: false,
        error: 'kind, groupId, token, sessionId, clientId, speakerName, and relayURLString are required',
      });
      return;
    }
    try {
      const relayURL = new URL(body.relayURLString);
      if (relayURL.protocol !== 'http:' && relayURL.protocol !== 'https:') throw new Error('protocol');
    } catch {
      res.status(400).json({ ok: false, error: 'relayURLString must be an http(s) URL' });
      return;
    }

    const persistedEntries = [
      ...nowPlayingTokens.forGroup(body.groupId, 'update'),
      ...nowPlayingTokens.forGroup(body.groupId, 'start'),
    ];
    if (body.kind === 'update') {
      if (!body.sessionGeneration) {
        res.status(409).json({ ok: false, error: 'missing_session_generation' });
        return;
      }
      const expectedGeneration = nowPlayingSessionGenerations.current(
        body.groupId,
        persistedEntries.filter(entry => entry.sessionId === body.sessionId),
      );
      if (expectedGeneration && expectedGeneration !== body.sessionGeneration) {
        res.status(409).json({ ok: false, error: 'stale_session_generation' });
        return;
      }
      if (!expectedGeneration) {
        nowPlayingTokens.removeUpdatesForGroup(body.groupId);
      }
      nowPlayingSessionGenerations.adopt(body.groupId, body.sessionGeneration);
    } else if (body.requestStart === true) {
      // The relay owns the generation of an APNs-created session. Persist it
      // on the start-token entry before sending so an update-token callback
      // racing the APNs response is validated against the same generation.
      body.sessionGeneration = nowPlayingSessionGenerations.rotate(body.groupId);
      nowPlayingTokens.removeUpdatesForGroup(body.groupId);
    } else if (body.sessionGeneration) {
      // A foreground app can bootstrap the session locally, then register its
      // push-to-start token only as a future fallback. If the system retained
      // the old session shell across a reboot, the app deliberately recreates
      // it with a new generation. Retire that client's pre-reboot update token
      // before adopting the replacement generation.
      const previousGeneration = nowPlayingSessionGenerations.current(
        body.groupId,
        persistedEntries.filter(entry => entry.sessionId === body.sessionId),
      );
      if (previousGeneration && previousGeneration !== body.sessionGeneration) {
        const removed = nowPlayingTokens.removeUpdatesForClientSession(
          body.groupId,
          body.clientId,
          body.sessionId,
        );
        log.info({
          source: 'relay',
          action: 'session-generation-replaced',
          groupId: body.groupId,
          sessionId: body.sessionId,
          previousGeneration,
          sessionGeneration: body.sessionGeneration,
          removedUpdateTokens: removed,
        }, 'now_playing');
      }
      nowPlayingSessionGenerations.adopt(body.groupId, body.sessionGeneration);
    }

    const registration = body as NowPlayingRegisterRequest;
    const alreadyRegistered = nowPlayingTokens.hasRegistration(registration);
    const entry = nowPlayingTokens.register(registration);
    if (entry.kind === 'start'
      && body.requestStart !== true
      && body.sessionGeneration) {
      nowPlayingTokens.recordSent(entry, 'local-session-active', body.sessionGeneration);
    }
    const registrationLog = {
      source: 'relay',
      action: 'register',
      kind: entry.kind,
      groupId: entry.groupId,
      sessionId: entry.sessionId,
      sessionGeneration: entry.sessionGeneration ?? null,
      clientId: entry.clientId,
      token: shortToken(entry.token),
      alreadyRegistered,
      requestStart: body.requestStart === true,
    };
    if (alreadyRegistered) {
      log.debug(registrationLog, 'now_playing');
    } else {
      log.info(registrationLog, 'now_playing');
    }

    // With a reachable relay, the app delegates session ownership to APNs.
    // Start immediately from the current Sonos snapshot so the first session
    // representation already contains authoritative public artwork.
    if (shouldSendNowPlayingStart(
      entry.kind,
      alreadyRegistered,
      body.requestStart === true,
    )) {
      const snap = sonos.current(entry.groupId);
      if (snap) {
        await pushNowPlayingSnapshot(snap, 'register-start-token', {
          forceStartToken: entry.token,
        });
      }
    } else if (entry.kind === 'update' && !alreadyRegistered) {
      const snap = sonos.current(entry.groupId);
      if (snap) {
        await pushNowPlayingSnapshot(snap, 'register-update-token', {
          forceUpdateToken: entry.token,
        });
      }
    }
    res.json({ ok: true });
  });

  app.post('/api/register-activity', async (req, res) => {
    const body = req.body as Partial<RegisterRequest>;
    if (!body.groupId || !body.token) {
      res.status(400).json({ error: 'groupId and token are required' });
      return;
    }
    log.info(
      {
        source: 'relay',
        action: 'register-request',
        groupId: body.groupId,
        token: shortToken(body.token),
        clientId: body.clientId ?? null,
        activityId: body.activityId ?? null,
        speakerName: body.attributes?.speakerName ?? null,
        liveActivityStyleRaw: body.liveActivityStyleRaw ?? null,
      },
      'live_activity',
    );
    liveActivityPreferences.update({
      groupId: body.groupId,
      liveActivityStyleRaw: body.liveActivityStyleRaw,
    });
    tokens.register({
      groupId: body.groupId,
      token: body.token,
      clientId: body.clientId,
      activityId: body.activityId,
      liveActivityStyleRaw: body.liveActivityStyleRaw,
      attributes: body.attributes,
    });
    startTokens.recordActivityRegistered(body.groupId, body.clientId);
    const clearedSuppressions = liveActivityDismissals.clearForActivity(
      body.groupId,
      body.clientId,
      body.activityId,
    );
    if (clearedSuppressions > 0) {
      log.info(
        {
          source: 'relay',
          action: 'dismissal-suppression-clear',
          trigger: 'register-activity',
          groupId: body.groupId,
          clientId: body.clientId ?? null,
          activityId: body.activityId ?? null,
          removed: clearedSuppressions,
        },
        'live_activity',
      );
    }

    // Push an initial state immediately so the Lock Screen reflects current
    // playback the moment the user starts the Live Activity, not after the
    // next track change.
    const snap = sonos.current(body.groupId);
    if (snap) {
      const enrichedSnap = liveActivityPreferences.apply(snap);
      const relevanceScore = liveActivityPreferences.relevanceScoreForGroup(enrichedSnap.groupId);
      const state = await buildLiveActivityContentState(enrichedSnap, {
        logger: liveActivityArtworkLog,
        logContext: { trigger: 'register-initial' },
      });
      const hash = hashLiveActivityContentState(state);
      log.info(
        {
          source: 'relay',
          action: 'state-built',
          trigger: 'register-initial',
          groupId: body.groupId,
          token: shortToken(body.token),
          relevanceScore,
          hash,
          state: summarizeLiveActivityState(state),
        },
        'live_activity',
      );
      const result = await apns.pushUpdate([body.token], state, relevanceScore);
      for (const dead of result.unregistered) tokens.unregister(dead);
      tokens.recordSent(body.token, hash);
      log.info(
        {
          source: 'relay',
          action: 'apns-update',
          trigger: 'register-initial',
          groupId: body.groupId,
          token: shortToken(body.token),
          relevanceScore,
          sent: result.sent,
          failed: result.failed,
          unregistered: result.unregistered.map(shortToken),
          hash,
          state: summarizeLiveActivityState(state),
        },
        'live_activity',
      );
      res.json({ ok: true, initialState: state });
      return;
    }
    log.info(
      {
        source: 'relay',
        action: 'skip',
        trigger: 'register-initial',
        reason: 'no-current-snapshot',
        groupId: body.groupId,
        token: shortToken(body.token),
      },
      'live_activity',
    );
    res.json({ ok: true, initialState: null });
  });

  app.post('/api/live-activity-preferences', async (req, res) => {
    const body = req.body as Partial<LiveActivityPreferencesRequest>;
    if (!body.groupId) {
      res.status(400).json({ error: 'groupId is required' });
      return;
    }

    liveActivityPreferences.update({
      groupId: body.groupId,
      liveActivityStyleRaw: body.liveActivityStyleRaw,
      selectedGroupId: body.selectedGroupId,
    });

    log.info(
      {
        source: 'relay',
        action: 'preferences-update',
        groupId: body.groupId,
        liveActivityStyleRaw: body.liveActivityStyleRaw ?? null,
        selectedGroupId: body.selectedGroupId ?? null,
        clientId: body.clientId ?? null,
        resumeLiveActivity: body.resumeLiveActivity === true,
      },
      'live_activity',
    );

    if (body.resumeLiveActivity === true) {
      const resumeClientId = body.clientId ?? undefined;
      const removed = liveActivityDismissals.clearForActivity(body.groupId, resumeClientId);
      log.info(
        {
          source: 'relay',
          action: 'dismissal-suppression-clear',
          trigger: 'app-preferences-resume',
          groupId: body.groupId,
          clientId: resumeClientId ?? null,
          removed,
        },
        'live_activity',
      );
      const snap = sonos.current(body.groupId);
      if (snap?.isPlaying) {
        const groupStartTokens = startTokens.forGroup(body.groupId);
        const resumeStartTokens = resumeClientId
          ? groupStartTokens.filter(entry => entry.clientId === resumeClientId)
          : groupStartTokens;
        await tryStartLiveActivitySnapshot(
          liveActivityPreferences.apply(snap),
          'app-preferences-resume:start',
          resumeStartTokens,
          tokens.forGroup(body.groupId),
          { bypassCooldown: true },
        );
      } else {
        log.info(
          {
            source: 'relay',
            action: 'skip',
            trigger: 'app-preferences-resume:start',
            reason: snap ? 'not-playing' : 'no-current-snapshot',
            groupId: body.groupId,
            clientId: body.clientId ?? null,
            snapshot: snap ? summarizeSnapshot(snap) : null,
          },
          'live_activity',
        );
      }
    }

    const refreshAllRelevanceScores = body.selectedGroupId !== undefined;
    const snapshots = refreshAllRelevanceScores
      ? sonos.allSnapshots()
      : [sonos.current(body.groupId)].filter((snap): snap is SonosGroupSnapshot => snap !== undefined);

    if (snapshots.length > 0) {
      for (const snap of snapshots) {
        await pushLiveActivitySnapshot(snap, 'app-preferences', {
          force: true,
          logNoTokens: false,
        });
      }
    } else {
      log.info(
        {
          source: 'relay',
          action: 'skip',
          trigger: 'app-preferences',
          reason: refreshAllRelevanceScores ? 'no-current-snapshots' : 'no-current-snapshot',
          groupId: body.groupId,
          selectedGroupId: body.selectedGroupId ?? null,
        },
        'live_activity',
      );
    }

    res.json({ ok: true });
  });

  app.post('/api/live-activity-dismissed', (req, res) => {
    const body = req.body as Partial<LiveActivityDismissedRequest>;
    if (!body.groupId) {
      res.status(400).json({ error: 'groupId is required' });
      return;
    }

    const defaultSuppressForSeconds = Number(
      process.env.LIVE_ACTIVITY_DISMISS_SUPPRESS_SECONDS
        ?? DEFAULT_LIVE_ACTIVITY_DISMISS_SUPPRESS_SECONDS,
    );
    const entry = liveActivityDismissals.recordDismissalRequest(
      {
        groupId: body.groupId,
        clientId: body.clientId,
        activityId: body.activityId,
        token: body.token,
        suppressForSeconds: body.suppressForSeconds,
      },
      new Date(),
      Number.isFinite(defaultSuppressForSeconds)
        ? defaultSuppressForSeconds
        : DEFAULT_LIVE_ACTIVITY_DISMISS_SUPPRESS_SECONDS,
    );
    const removedToken = body.token ? tokens.unregister(body.token) : false;

    log.info(
      {
        source: 'relay',
        action: 'dismissed',
        groupId: body.groupId,
        clientId: body.clientId ?? null,
        activityId: body.activityId ?? null,
        token: body.token ? shortToken(body.token) : null,
        removedToken,
        suppressUntil: entry.suppressUntil,
      },
      'live_activity',
    );

    res.json({ ok: true, suppressUntil: entry.suppressUntil, removedToken });
  });

  app.post('/api/live-activity-command', async (req, res) => {
    const groupId = typeof req.body?.groupId === 'string' ? req.body.groupId : '';
    const token = typeof req.body?.token === 'string' ? req.body.token : '';
    const command = typeof req.body?.command === 'string' ? req.body.command : '';
    if (!groupId || !token || !command) {
      res.status(400).json({ ok: false, error: 'groupId, token, and command are required' });
      return;
    }
    if (!tokens.hasTokenForGroup(groupId, token)
      && !nowPlayingTokens.hasTokenForGroup(groupId, token)) {
      res.status(401).json({ ok: false, error: 'unregistered_media_control_token' });
      return;
    }

    try {
      switch (command) {
      case 'play':
        await sonos.play(groupId);
        break;
      case 'pause':
        await sonos.pause(groupId);
        break;
      case 'next':
        await sonos.next(groupId);
        break;
      case 'previous':
        await sonos.previous(groupId);
        break;
      case 'setGroupVolume': {
        const volume = req.body?.volume;
        if (typeof volume !== 'number' || Number.isNaN(volume)) {
          res.status(400).json({ ok: false, error: 'volume must be a number' });
          return;
        }
        await sonos.setGroupVolume(groupId, volume);
        break;
      }
      case 'setMemberVolume': {
        const volume = req.body?.volume;
        const memberId = typeof req.body?.memberId === 'string' ? req.body.memberId : '';
        if (!memberId) {
          res.status(400).json({ ok: false, error: 'memberId is required' });
          return;
        }
        if (typeof volume !== 'number' || Number.isNaN(volume)) {
          res.status(400).json({ ok: false, error: 'volume must be a number' });
          return;
        }
        await sonos.setMemberVolume(groupId, memberId, volume);
        break;
      }
      case 'setSoundbarNightMode': {
        const nightMode = req.body?.nightMode;
        if (typeof nightMode !== 'boolean') {
          res.status(400).json({ ok: false, error: 'nightMode must be a boolean' });
          return;
        }
        await sonos.setSoundbarNightMode(groupId, nightMode);
        break;
      }
      case 'setSoundbarSpeechEnhancement': {
        const rawLevel = req.body?.speechEnhancementRawLevel;
        if (typeof rawLevel !== 'number' || Number.isNaN(rawLevel)) {
          res.status(400).json({ ok: false, error: 'speechEnhancementRawLevel must be a number' });
          return;
        }
        await sonos.setSoundbarSpeechEnhancementRawLevel(groupId, rawLevel);
        break;
      }
      default:
        res.status(400).json({ ok: false, error: 'unsupported_command' });
        return;
      }

      const snap = sonos.current(groupId);
      log.info(
        {
          source: 'relay',
          action: 'command',
          command,
          groupId,
          token: shortToken(token),
          snapshot: snap ? summarizeSnapshot(snap) : null,
        },
        'live_activity',
      );
      res.json({ ok: true, state: snap ? snapshotJson(snap) : null });
    } catch (err) {
      const msg = String(err);
      log.warn({ err, command, groupId, token: shortToken(token) }, 'Live Activity command failed');
      res.status(msg.includes('unknown_group') ? 404 : 500).json({ ok: false, error: msg });
    }
  });

  app.delete('/api/register-activity/:token', (req, res) => {
    const ok = tokens.unregister(req.params.token);
    log.info(
      {
        source: 'relay',
        action: 'unregister-request',
        token: shortToken(req.params.token),
        removed: ok,
      },
      'live_activity',
    );
    res.json({ ok });
  });

  // ---- listen + shutdown -----------------------------------------------
  let relayBonjour: RelayBonjourAdvertisement | null = null;
  const server = app.listen(RELAY_PORT, () => {
    log.info({ port: RELAY_PORT }, 'relay HTTP listening');
    relayBonjour = publishRelayBonjour(RELAY_PORT, log.child({ module: 'bonjour' }));
  });

  const shutdown = (signal: string) => {
    log.info({ signal }, 'shutting down');
    server.close();
    relayBonjour?.stop();
    sonos.stop();
    void hueAmbience.stop();
    apns.shutdown();
    setTimeout(() => process.exit(0), 500);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch(err => {
  log.fatal({ err }, 'fatal startup error');
  process.exit(1);
});

function summarizeSnapshot(snap: SonosGroupSnapshot): Record<string, unknown> {
  return {
    trackTitle: snap.trackTitle || 'Not Playing',
    artist: snap.artist || '-',
    isPlaying: snap.isPlaying,
    positionSeconds: Math.round(snap.positionSeconds),
    durationSeconds: Math.round(snap.durationSeconds),
    hasAlbumArtUri: Boolean(snap.albumArtUri),
    playbackSourceRaw: snap.playbackSourceRaw ?? null,
    sampledAt: snap.sampledAt.toISOString(),
  };
}

function summarizeLiveActivityState(state: LiveActivityContentState): Record<string, unknown> {
  return {
    trackTitle: state.trackTitle,
    artist: state.artist,
    isPlaying: state.isPlaying,
    positionSeconds: Math.round(state.positionSeconds),
    durationSeconds: Math.round(state.durationSeconds),
    color: state.dominantColorHex ?? null,
    artBytes: base64ByteLength(state.albumArtThumbnail),
    artworkTraceId: state.artworkTraceId ?? null,
    groupMemberCount: state.groupMemberCount,
    playbackSourceRaw: state.playbackSourceRaw ?? null,
    liveActivityStyleRaw: state.liveActivityStyleRaw ?? null,
    audioQualityLabel: state.audioQualityLabel ?? null,
    hasStartedAt: state.startedAt !== undefined && state.startedAt !== null,
    hasEndsAt: state.endsAt !== undefined && state.endsAt !== null,
  };
}

function base64ByteLength(value: string | null | undefined): number {
  if (!value) return 0;
  try {
    return Buffer.byteLength(value, 'base64');
  } catch {
    return 0;
  }
}

function shortToken(token: string): string {
  return token.length <= 12 ? token : `${token.slice(0, 6)}…${token.slice(-4)}`;
}
