import express from 'express';
import pino from 'pino';
import pinoHttp from 'pino-http';
import path from 'node:path';

import { SonosBridge, type SonosSnapshotChangeContext } from './sonos.js';
import { createInternalSonosRouter, internalAuthMiddleware } from './internalSonosRoutes.js';
import { ApnsClient } from './apns.js';
import { TokenStore } from './tokenStore.js';
import { HueAmbienceConfigStore } from './hueConfigStore.js';
import { HueAmbienceService } from './hueAmbienceService.js';
import { createHueAmbienceRouter } from './hueRoutes.js';
import { createHueMusicAmbienceRenderer } from './hueEdkSidecarRenderer.js';
import type { HueEntertainmentControlClient } from './hueEntertainmentStream.js';
import type { HueLightClient } from './hueTypes.js';
import { Cs2GameStateService } from './cs2GameState.js';
import { createCs2GameStateRouter } from './cs2Routes.js';
import { Cs2LightingService } from './cs2Lighting.js';
import { createArtworkRouter } from './artworkRoutes.js';
import { ArtworkHintStore, createArtworkHintsRouter } from './artworkHints.js';
import { createPlaybackStateRouter } from './playbackStateRoutes.js';
import { shouldIgnoreHttpAutoLog } from './httpLogging.js';
import {
  buildLiveActivityContentState,
  hashLiveActivityContentState,
} from './liveActivityContentState.js';
import {
  LiveActivityPreferenceStore,
  type LiveActivityPreferencesRequest,
} from './liveActivityPreferences.js';
import {
  LiveActivityPushInFlightRegistry,
  liveActivityPushResultLogLevel,
  shouldForceLiveActivityCalibration,
} from './liveActivityPushPolicy.js';
import { snapshotJson } from './relaySnapshotJson.js';
import { publishRelayBonjour, type RelayBonjourAdvertisement } from './bonjour.js';
import type { LiveActivityContentState, RegisterRequest, SonosGroupSnapshot } from './types.js';

const log = pino({
  level: process.env.LOG_LEVEL ?? 'info',
  transport: process.env.NODE_ENV === 'production' ? undefined : { target: 'pino-pretty' },
});

const RELAY_PORT = Number(process.env.RELAY_PORT ?? 8787);
const SEED_IP = process.env.SONOS_SEED_IP?.trim() || undefined;
const DATA_DIR = process.env.DATA_DIR ?? '/app/data';
const CS2_LIGHTING_LOG_PATH = process.env.CS2_LIGHTING_LOG_PATH
  ?? path.join(DATA_DIR, 'cs2-lighting.jsonl');
const DEFAULT_APNS_BUNDLE_ID = 'com.charm.SonosWidget';
const DEFAULT_APNS_TEAM_ID = '3MSS7DJGVR';

async function main(): Promise<void> {
  // ---- core wiring ------------------------------------------------------
  const tokens = new TokenStore(DATA_DIR, log);
  await tokens.load();
  const hueConfigStore = new HueAmbienceConfigStore(DATA_DIR);
  const hueAmbience = new HueAmbienceService(
    hueConfigStore,
    log.child({ module: 'hue-ambience' }),
    undefined,
    undefined,
    undefined,
    (config, client) => createHueMusicAmbienceRenderer(
      config,
      client as HueLightClient & HueEntertainmentControlClient,
    ),
  );
  await hueAmbience.load();
  const cs2GameState = new Cs2GameStateService();
  const cs2Lighting = new Cs2LightingService(hueConfigStore, undefined, {
    beforeRender: () => hueAmbience.pauseForExternalRenderer(),
    logger: log.child({ module: 'cs2-lighting' }),
    logFilePath: CS2_LIGHTING_LOG_PATH,
  });

  const apns = await ApnsClient.create(
    {
      bundleId: process.env.APNS_BUNDLE_ID ?? DEFAULT_APNS_BUNDLE_ID,
      keyPath: process.env.APNS_KEY_PATH ?? path.join(DATA_DIR, 'apns.p8'),
      keyId: process.env.APNS_KEY_ID ?? '',
      teamId: process.env.APNS_TEAM_ID ?? DEFAULT_APNS_TEAM_ID,
      production: (process.env.APNS_PRODUCTION ?? 'false') === 'true',
    },
    log,
  );

  const artworkHints = new ArtworkHintStore();
  const sonos = new SonosBridge(log, { artworkHints });
  await sonos.start(SEED_IP);
  const liveActivityPreferences = new LiveActivityPreferenceStore();
  const liveActivityPushesInFlight = new LiveActivityPushInFlightRegistry();

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
    const state = await buildLiveActivityContentState(enrichedSnap);
    const hash = hashLiveActivityContentState(state);
    log.debug(
      {
        source: 'relay',
        action: 'state-built',
        trigger,
        force,
        groupId: snap.groupId,
        registeredTokens: matching.length,
        hash,
        state: summarizeLiveActivityState(state),
      },
      'live_activity',
    );

    // Skip no-op pushes for normal Sonos events. Periodic refreshes are a
    // deliberate low-frequency calibration path for position/timerInterval.
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
      );
      for (const t of targets) {
        tokens.recordSent(t.token, hash);
      }
      for (const dead of result.unregistered) tokens.unregister(dead);

      const logLevel = liveActivityPushResultLogLevel(trigger, {
        failed: result.failed,
        unregisteredCount: result.unregistered.length,
      });
      log[logLevel](
        {
          source: 'relay',
          action: 'apns-update',
          trigger,
          force,
          groupId: snap.groupId,
          tokenCount: targets.length,
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

  sonos.on('change', async (
    snap: SonosGroupSnapshot,
    context?: SonosSnapshotChangeContext,
  ) => {
    if (!cs2Lighting.shouldDeferAlbumAmbience()) {
      hueAmbience.receiveSnapshot(snap);
    }

    const trigger = context?.trigger ?? 'sonos-change';
    const force = trigger === 'periodic-refresh';
    if (force && !shouldForceLiveActivityCalibration(snap)) {
      return;
    }
    await pushLiveActivitySnapshot(snap, trigger, {
      force,
      logNoTokens: trigger !== 'periodic-refresh',
    });
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
  app.use('/api', createPlaybackStateRouter(sonos));
  app.use('/api', createArtworkRouter(log.child({ module: 'artwork' })));
  app.use('/api', createArtworkHintsRouter(artworkHints, log.child({ module: 'artwork-hints' })));
  app.use('/api', createHueAmbienceRouter(hueAmbience, log));
  app.use('/api', createCs2GameStateRouter(cs2GameState, log.child({ module: 'cs2' })));

  cs2GameState.on('state', snapshot => {
    void cs2Lighting.receive(snapshot);
  });

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
      apns: apns.status(),
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
      cs2Lighting: cs2Lighting.status(),
      cs2: {
        providers: cs2GameState.status(),
      },
    });
  });

  /// iOS posts here right after `Activity.request(pushType: .token)` resolves
  /// and on every `pushTokenUpdates` rotation. Body shape: `RegisterRequest`.
  /// Replies with the current ContentState so the iOS side can sanity-check
  /// what the server thinks is playing without waiting for the next event.
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

    // Push an initial state immediately so the Lock Screen reflects current
    // playback the moment the user starts the Live Activity, not after the
    // next track change.
    const snap = sonos.current(body.groupId);
    if (snap) {
      const enrichedSnap = liveActivityPreferences.apply(snap);
      const state = await buildLiveActivityContentState(enrichedSnap);
      const hash = hashLiveActivityContentState(state);
      log.info(
        {
          source: 'relay',
          action: 'state-built',
          trigger: 'register-initial',
          groupId: body.groupId,
          token: shortToken(body.token),
          hash,
          state: summarizeLiveActivityState(state),
        },
        'live_activity',
      );
      const result = await apns.pushUpdate([body.token], state);
      for (const dead of result.unregistered) tokens.unregister(dead);
      tokens.recordSent(body.token, hash);
      log.info(
        {
          source: 'relay',
          action: 'apns-update',
          trigger: 'register-initial',
          groupId: body.groupId,
          token: shortToken(body.token),
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
      nowPlaying: body.nowPlaying,
    });

    log.info(
      {
        source: 'relay',
        action: 'preferences-update',
        groupId: body.groupId,
        liveActivityStyleRaw: body.liveActivityStyleRaw ?? null,
        hasNowPlayingHint: Boolean(body.nowPlaying),
        nowPlayingTrackTitle: body.nowPlaying?.trackTitle ?? null,
      },
      'live_activity',
    );

    const snap = sonos.current(body.groupId);
    if (snap) {
      await pushLiveActivitySnapshot(snap, 'app-preferences', {
        force: true,
        logNoTokens: false,
      });
    } else {
      log.info(
        {
          source: 'relay',
          action: 'skip',
          trigger: 'app-preferences',
          reason: 'no-current-snapshot',
          groupId: body.groupId,
        },
        'live_activity',
      );
    }

    res.json({ ok: true });
  });

  app.post('/api/live-activity-command', async (req, res) => {
    const groupId = typeof req.body?.groupId === 'string' ? req.body.groupId : '';
    const token = typeof req.body?.token === 'string' ? req.body.token : '';
    const command = typeof req.body?.command === 'string' ? req.body.command : '';
    if (!groupId || !token || !command) {
      res.status(400).json({ ok: false, error: 'groupId, token, and command are required' });
      return;
    }
    if (!tokens.hasTokenForGroup(groupId, token)) {
      res.status(401).json({ ok: false, error: 'unregistered_live_activity_token' });
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
