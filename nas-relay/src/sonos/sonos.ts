import {
  SonosDeviceDiscovery,
  SonosEventListener,
  SonosEvents,
  SonosManager,
  ServiceEvents,
  type SonosDevice,
} from '@svrooij/sonos';
import { createSocket } from 'node:dgram';
import { EventEmitter } from 'node:events';
import https from 'node:https';
import type { Logger } from 'pino';
import {
  createSonosArtworkResolver,
  type ITunesArtworkLookupClient,
  type SonosArtworkResolutionSource,
  type SonosArtworkResolver,
} from '../artwork/sonosArtworkResolver.js';
import type { SonosGroupMemberSnapshot, SonosGroupSnapshot } from '../types.js';
import {
  buildAppleMusicArtistStationPlayback,
  buildFavoriteCreateElements,
  buildCurrentTrackResourceMetadata,
  favoriteForCurrentURI,
  favoriteUsesDirectTransport,
  parseSonosFavorites,
  resolveAppleMusicArtistId,
  serviceDescriptorForCurrentURI,
  sonosQueueView,
  type SonosFavoriteAddResult,
  type SonosCurrentFavoriteStatus,
  type SonosFavoriteItem,
  type SonosQueueArtworkResult,
  type SonosQueueItem,
  type SonosQueueView,
} from './sonosLibrary.js';

export type SonosSnapshotChangeTrigger =
  | 'sonos-change'
  | 'periodic-refresh'
  | 'initial-prime'
  | 'transition-settle-refresh';

export interface SonosSnapshotChangeContext {
  trigger: SonosSnapshotChangeTrigger;
}

export type SonosDiscoveryMode = 'auto' | 'seed';
export type SonosDiscoveryStatus = 'idle' | 'starting' | 'ready' | 'failed';

export interface SonosDiscoveryState {
  mode: SonosDiscoveryMode;
  status: SonosDiscoveryStatus;
  error: string | null;
}

export interface SonosLocalPlaybackQuality {
  label: string;
  serviceName?: string | null;
  lossless?: boolean | null;
  immersive?: boolean | null;
  bitDepth?: number | null;
  sampleRate?: number | null;
}

export interface SonosLocalControlClient {
  playbackMetadata?(input: { host: string; playerId: string }): Promise<SonosLocalPlaybackMetadata | null>;
  playbackQuality(input: { host: string; playerId: string }): Promise<SonosLocalPlaybackQuality | null>;
}

export interface SonosDiscoveryPlayer {
  host: string;
  port: number;
}

export interface SonosDiscoveryClient {
  SearchOne(timeoutSeconds?: number): Promise<SonosDiscoveryPlayer>;
}

export interface SonosEventListenerClient {
  UpdateSettings(settings: { host?: string; port?: number }): boolean;
  GetStatus(): {
    host: string;
    port: number;
    isListening: boolean;
    subscriptionUrl: string;
    subscriptionCount: number;
  };
}

export interface SonosBridgeOptions {
  localControl?: SonosLocalControlClient | null;
  artworkITunes?: ITunesArtworkLookupClient | null;
  artworkResolver?: SonosArtworkResolver | null;
  transitionSettleRefreshMs?: number;
  eventRefreshDebounceMs?: number;
  volumeCommandDebounceMs?: number;
  playbackWatchdogIntervalMs?: number;
  fullHouseWatchdogEveryCycles?: number;
  managerFactory?: () => SonosManager;
  discoveryFactory?: () => SonosDiscoveryClient;
  eventListener?: SonosEventListenerClient;
  listenerHostResolver?: (sonosHost: string) => Promise<string>;
  topologyRecoveryDiscoveryTimeoutSeconds?: number;
}

interface RefreshSnapshotOptions {
  suppressTransientNonPlaying?: boolean;
  topologyVerified?: boolean;
  topologyGroup?: ParsedZoneGroup;
  includeGroupDetails?: boolean;
}

interface SonosLocalPlayerInfo {
  groupId?: string | null;
}

interface QueueArtworkCacheEntry {
  url: string | null;
  source: SonosQueueItem['artworkSource'];
  expiresAt: number;
}

interface PendingVolumeWrite {
  volume: number;
  operation: (volume: number) => Promise<void>;
  timer: NodeJS.Timeout;
  waiters: Array<{
    resolve: () => void;
    reject: (reason: unknown) => void;
  }>;
}

interface AttachedDeviceListeners {
  device: {
    Events?: {
      off?: (event: SonosEvents, listener: (...args: any[]) => void) => void;
    };
  };
  listeners: Array<{
    event: SonosEvents;
    listener: (...args: any[]) => void;
  }>;
}

interface AttachedManagerTopologyListener {
  manager: SonosManager;
  events: EventEmitter;
  listener: (data: unknown) => void;
}

const QUEUE_ARTWORK_CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1_000;
const QUEUE_ARTWORK_MISS_TTL_MS = 15 * 60 * 1_000;
const QUEUE_ARTWORK_CACHE_MAX_ENTRIES = 2_000;
const QUEUE_ARTWORK_BATCH_LIMIT = 12;
const QUEUE_ARTWORK_LOOKUP_INTERVAL_MS = 350;
const QUEUE_ARTWORK_RATE_LIMIT_BACKOFF_MS = 15 * 60 * 1_000;

interface SonosLocalPlaybackMetadata {
  service?: {
    name?: string | null;
    id?: string | null;
  } | null;
  container?: {
    name?: string | null;
    imageUrl?: string | null;
    service?: {
      name?: string | null;
      id?: string | null;
    } | null;
  } | null;
  track?: {
    name?: string | null;
    imageUrl?: string | null;
    durationMillis?: number | null;
    artist?: {
      name?: string | null;
      imageUrl?: string | null;
    } | null;
    album?: {
      name?: string | null;
      imageUrl?: string | null;
    } | null;
    service?: {
      name?: string | null;
      id?: string | null;
    } | null;
    quality?: {
      bitDepth?: number | null;
      sampleRate?: number | null;
      lossless?: boolean | null;
      immersive?: boolean | null;
    } | null;
  } | null;
  currentItem?: {
    track?: {
      name?: string | null;
      imageUrl?: string | null;
      durationMillis?: number | null;
      artist?: {
        name?: string | null;
        imageUrl?: string | null;
      } | null;
      album?: {
        name?: string | null;
        imageUrl?: string | null;
      } | null;
      service?: {
        name?: string | null;
        id?: string | null;
      } | null;
      quality?: {
        bitDepth?: number | null;
        sampleRate?: number | null;
        lossless?: boolean | null;
        immersive?: boolean | null;
      } | null;
    } | null;
  } | null;
}

interface SonosZoneInfo {
  HTAudioIn?: number | string | null;
}

interface SonosTVAudioFormatSnapshot {
  rawCode: number;
  label: string;
  geekLabel: string;
  hasSignal: boolean;
}

const SONOS_LOCAL_CONTROL_PORT = 1443;
const SONOS_LOCAL_CONTROL_API_KEY = '12345678-abcd-1234-5678-123456789000';
const SONOS_ROUTE_PROBE_TIMEOUT_MS = 1_500;

/**
 * Ask the kernel which local IPv4 address it would use to reach a Sonos peer.
 * Connecting a UDP socket performs route selection without sending traffic.
 */
export function localIPv4AddressForSonosPeer(sonosHost: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = createSocket('udp4');
    let settled = false;
    const timer = setTimeout(() => {
      finish(new Error(`route lookup for Sonos peer ${sonosHost} timed out`));
    }, SONOS_ROUTE_PROBE_TIMEOUT_MS);
    timer.unref?.();

    const finish = (err?: Error, address?: string): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.removeAllListeners();
      try {
        socket.close();
      } catch {
        // The socket can already be closed after an asynchronous connect error.
      }
      if (err) {
        reject(err);
      } else if (address) {
        resolve(address);
      } else {
        reject(new Error(`route lookup for Sonos peer ${sonosHost} returned no address`));
      }
    };

    socket.once('error', err => {
      finish(err);
    });
    socket.connect(9, sonosHost, () => {
      try {
        const address = socket.address();
        if (typeof address === 'string' || address.family !== 'IPv4') {
          finish(new Error(`route lookup for Sonos peer ${sonosHost} did not return IPv4`));
          return;
        }
        finish(undefined, address.address);
      } catch (err) {
        finish(err instanceof Error ? err : new Error(String(err)));
      }
    });
  });
}

class SonosLocalControlApiClient implements SonosLocalControlClient {
  private readonly groupIdsByPlayerId = new Map<string, string>();

  constructor(
    private readonly log: Logger,
    private readonly timeoutMs = 4_000,
  ) {}

  async playbackMetadata(input: { host: string; playerId: string }): Promise<SonosLocalPlaybackMetadata | null> {
    const cachedGroupId = this.groupIdsByPlayerId.get(input.playerId);
    if (cachedGroupId) {
      try {
        return await this.getPlaybackMetadata(input.host, cachedGroupId);
      } catch (err) {
        this.groupIdsByPlayerId.delete(input.playerId);
        this.log.debug(
          { err, host: input.host, playerId: input.playerId, groupId: cachedGroupId },
          'cached Sonos local Control API group lookup failed',
        );
      }
    }

    const playerInfo = await this.getPlayerInfo(input.host, input.playerId);
    const groupId = firstObjectString(playerInfo.groupId);
    if (!groupId) return null;

    this.groupIdsByPlayerId.set(input.playerId, groupId);
    return await this.getPlaybackMetadata(input.host, groupId);
  }

  async playbackQuality(input: { host: string; playerId: string }): Promise<SonosLocalPlaybackQuality | null> {
    const metadata = await this.playbackMetadata(input);
    return metadata ? localPlaybackQualityFromPlaybackMetadata(metadata) : null;
  }

  private async getPlayerInfo(host: string, playerId: string): Promise<SonosLocalPlayerInfo> {
    return this.getJson<SonosLocalPlayerInfo>(
      host,
      `/api/v1/players/${encodeSonosLocalPathSegment(playerId)}/info`,
    );
  }

  private async getPlaybackMetadata(host: string, groupId: string): Promise<SonosLocalPlaybackMetadata> {
    return this.getJson<SonosLocalPlaybackMetadata>(
      host,
      `/api/v1/groups/${encodeSonosLocalPathSegment(groupId)}/playbackMetadata`,
    );
  }

  private getJson<T>(host: string, path: string): Promise<T> {
    return new Promise((resolve, reject) => {
      const req = https.request(
        {
          hostname: hostnameForHttpsRequest(host),
          port: SONOS_LOCAL_CONTROL_PORT,
          path,
          method: 'GET',
          rejectUnauthorized: !isLocalSonosControlHost(host),
          headers: {
            Accept: 'application/json',
            'X-Sonos-Api-Key': SONOS_LOCAL_CONTROL_API_KEY,
          },
          timeout: this.timeoutMs,
        },
        res => {
          const chunks: Buffer[] = [];
          res.on('data', chunk => chunks.push(Buffer.from(chunk)));
          res.on('end', () => {
            const text = Buffer.concat(chunks).toString('utf8');
            if (!res.statusCode || res.statusCode < 200 || res.statusCode >= 300) {
              reject(new Error(`Sonos local Control API GET ${path} failed: HTTP ${res.statusCode} ${text}`));
              return;
            }
            try {
              resolve(JSON.parse(text) as T);
            } catch (err) {
              reject(err);
            }
          });
        },
      );

      req.on('timeout', () => {
        req.destroy(new Error(`Sonos local Control API GET ${path} timed out`));
      });
      req.on('error', reject);
      req.end();
    });
  }
}

/// Wraps @svrooij/sonos to give us a single clean event stream:
///   `change` (groupId, snapshot)
/// fired whenever any meaningful field shifts on any coordinator. The
/// underlying lib emits a flurry of granular events (current-track, volume,
/// transport-state, playback-stopped, etc.) that we collapse into one snapshot
/// per group so the consumer only needs one handler.
export class SonosBridge extends EventEmitter {
  private manager: SonosManager;
  private readonly managerFactory: () => SonosManager;
  private readonly discoveryFactory: () => SonosDiscoveryClient;
  private readonly eventListener: SonosEventListenerClient;
  private readonly listenerHostResolver: (sonosHost: string) => Promise<string>;
  private readonly snapshots = new Map<string, SonosGroupSnapshot>();
  private readonly refreshSequences = new Map<string, number>();
  private readonly localQualityLogSignatures = new Map<string, string>();
  private readonly log: Logger;
  private readonly localControl: SonosLocalControlClient | null;
  private readonly artworkResolver: SonosArtworkResolver | null;
  private readonly queueArtworkCache = new Map<string, QueueArtworkCacheEntry>();
  private readonly queueArtworkInFlight = new Map<string, Promise<QueueArtworkCacheEntry>>();
  private readonly queueViews = new Map<string, SonosQueueView>();
  private queueArtworkLookupTail = Promise.resolve();
  private nextQueueArtworkLookupAt = 0;
  private queueArtworkBackoffUntil = 0;
  private readonly transitionSettleRefreshMs: number;
  private readonly eventRefreshDebounceMs: number;
  private readonly volumeCommandDebounceMs: number;
  private readonly playbackWatchdogIntervalMs: number;
  private readonly fullHouseWatchdogEveryCycles: number;
  private readonly topologyRecoveryDiscoveryTimeoutSeconds: number;
  private readonly transitionSettleRefreshTimers = new Map<string, NodeJS.Timeout>();
  private readonly commandConfirmationRefreshTimers = new Map<string, NodeJS.Timeout>();
  private readonly eventRefreshTimers = new Map<string, NodeJS.Timeout>();
  private readonly volumeEventRefreshTimers = new Map<string, NodeJS.Timeout>();
  private readonly pendingVolumeWrites = new Map<string, PendingVolumeWrite>();
  private readonly attachedDeviceListenerKeys = new Set<string>();
  private readonly attachedDeviceListeners = new Map<string, AttachedDeviceListeners>();
  private attachedManagerTopologyListener: AttachedManagerTopologyListener | null = null;
  private visibleTopologyCoordinatorKeys = new Set<string>();
  private topologyFilterReady = false;
  private topologyRefreshTimer: NodeJS.Timeout | null = null;
  private topologyRecoveryPromise: Promise<ParsedZoneGroup[] | null> | null = null;
  private periodicHandle: NodeJS.Timeout | null = null;
  private periodicCycle = 0;
  private discoveryState: SonosDiscoveryState = {
    mode: 'auto',
    status: 'idle',
    error: null,
  };

  constructor(log: Logger, options: SonosBridgeOptions = {}) {
    super();
    this.managerFactory = options.managerFactory ?? (() => new SonosManager());
    this.discoveryFactory = options.discoveryFactory ?? (() => new SonosDeviceDiscovery());
    this.eventListener = options.eventListener ?? SonosEventListener.DefaultInstance;
    this.listenerHostResolver = options.listenerHostResolver ?? localIPv4AddressForSonosPeer;
    this.manager = this.managerFactory();
    this.log = log.child({ module: 'sonos' });
    this.localControl = options.localControl === undefined
      ? new SonosLocalControlApiClient(this.log)
      : options.localControl;
    this.artworkResolver = options.artworkResolver === undefined
      ? createSonosArtworkResolver({
        logger: this.log,
        ...(options.artworkITunes === undefined ? {} : { itunes: options.artworkITunes }),
      })
      : options.artworkResolver;
    this.transitionSettleRefreshMs = options.transitionSettleRefreshMs ?? 1_200;
    this.eventRefreshDebounceMs = options.eventRefreshDebounceMs ?? 250;
    this.volumeCommandDebounceMs = options.volumeCommandDebounceMs ?? 300;
    this.playbackWatchdogIntervalMs = options.playbackWatchdogIntervalMs ?? 10 * 60_000;
    this.fullHouseWatchdogEveryCycles = Math.max(1, options.fullHouseWatchdogEveryCycles ?? 3);
    this.topologyRecoveryDiscoveryTimeoutSeconds =
      options.topologyRecoveryDiscoveryTimeoutSeconds ?? 10;
  }

  get discovery(): SonosDiscoveryState {
    return this.discoveryState;
  }

  async start(seedIp?: string): Promise<void> {
    const trimmedSeedIp = seedIp?.trim() ?? '';
    const mode: SonosDiscoveryMode = trimmedSeedIp ? 'seed' : 'auto';
    this.discoveryState = { mode, status: 'starting', error: null };

    try {
      const ok = trimmedSeedIp
        ? await this.startFromSeed(trimmedSeedIp)
        : await this.startFromDiscovery();
      if (!ok) {
        throw new Error(trimmedSeedIp
          ? `Sonos seed ${trimmedSeedIp} did not respond — verify the IP`
          : 'No Sonos speakers discovered by SSDP');
      }
      this.discoveryState = { mode, status: 'ready', error: null };
    } catch (err) {
      const message = errorSummary(err);
      this.discoveryState = { mode, status: 'failed', error: message };
      throw err;
    }

    this.attachManagerListeners(this.manager);

    // ZoneGroupState is authoritative for which devices are user-visible
    // coordinators. sonos-ts also discovers bonded surrounds, stereo-pair
    // partners and Subs as devices; priming every discovered device creates
    // phantom dashboard groups for those Invisible=1 members.
    await this.refreshTopologySnapshots('initial-prime');

    // GENA is the primary source of truth. Keep a deliberately slow watchdog
    // for the rare case where a firmware update silently drops subscriptions:
    // active groups get a light playback refresh every ten minutes, while a
    // full topology/group-detail refresh runs only every third cycle.
    this.periodicHandle = setInterval(() => {
      void this.runPlaybackWatchdog();
    }, this.playbackWatchdogIntervalMs);
    this.periodicHandle.unref?.();
  }

  private async startFromSeed(seedIp: string): Promise<boolean> {
    this.log.info({ seedIp }, 'discovering Sonos household via seed IP');
    await this.configureEventListenerForPeer(seedIp);
    return this.manager.InitializeFromDevice(seedIp);
  }

  private async startFromDiscovery(): Promise<boolean> {
    const timeoutSeconds = 10;
    this.log.info({ timeoutSeconds }, 'discovering Sonos household via SSDP');
    const player = await this.discoveryFactory().SearchOne(timeoutSeconds);
    await this.configureEventListenerForPeer(player.host);
    return this.manager.InitializeFromDevice(player.host, player.port);
  }

  private async configureEventListenerForPeer(sonosHost: string): Promise<void> {
    const configuredHost = process.env.SONOS_LISTENER_HOST?.trim();
    let listenerHost = configuredHost;
    let source = 'environment';

    if (!listenerHost) {
      source = 'route';
      try {
        listenerHost = await this.listenerHostResolver(sonosHost);
      } catch (err) {
        this.log.warn(
          { err, sonosHost },
          'could not determine the local Sonos event callback address; using library default',
        );
        return;
      }
    }

    this.eventListener.UpdateSettings({ host: listenerHost });
    const status = this.eventListener.GetStatus();
    const context = {
      sonosHost,
      listenerHost: status.host,
      listenerPort: status.port,
      subscriptionUrl: status.subscriptionUrl,
      source,
    };
    if (status.host !== listenerHost) {
      this.log.warn(
        { ...context, requestedListenerHost: listenerHost },
        'Sonos event callback address did not apply',
      );
      return;
    }
    this.log.info(context, 'Sonos event callback address configured');
  }

  stop(): void {
    if (this.periodicHandle) clearInterval(this.periodicHandle);
    this.periodicHandle = null;
    for (const timer of this.transitionSettleRefreshTimers.values()) {
      clearTimeout(timer);
    }
    this.transitionSettleRefreshTimers.clear();
    for (const timer of this.commandConfirmationRefreshTimers.values()) {
      clearTimeout(timer);
    }
    this.commandConfirmationRefreshTimers.clear();
    for (const timer of this.eventRefreshTimers.values()) {
      clearTimeout(timer);
    }
    this.eventRefreshTimers.clear();
    for (const timer of this.volumeEventRefreshTimers.values()) {
      clearTimeout(timer);
    }
    this.volumeEventRefreshTimers.clear();
    for (const pending of this.pendingVolumeWrites.values()) {
      clearTimeout(pending.timer);
      for (const waiter of pending.waiters) {
        waiter.reject(new Error('Sonos bridge stopped before volume command was sent'));
      }
    }
    this.pendingVolumeWrites.clear();
    if (this.topologyRefreshTimer) clearTimeout(this.topologyRefreshTimer);
    this.topologyRefreshTimer = null;
    this.detachDeviceListeners();
    this.detachManagerTopologyListener(this.manager);
    this.cancelManagerSubscription(this.manager);
  }

  /// Latest known snapshot for a group, or undefined if we haven't sampled yet.
  current(groupId: string): SonosGroupSnapshot | undefined {
    return this.snapshots.get(groupId);
  }

  allSnapshots(): SonosGroupSnapshot[] {
    return Array.from(this.snapshots.values());
  }

  /// Coordinator IP used as `groupId` by iOS / relay health — resolve group coordinator.
  resolveCoordinator(groupId: string): SonosDevice | undefined {
    for (const device of this.manager.Devices) {
      const coord = device.Coordinator ?? device;
      const host = firstNonEmpty(coord.Host, device.Host);
      const uuid = firstNonEmpty(coord.Uuid, device.Uuid);
      if (this.topologyFilterReady && !this.isVisibleTopologyCoordinator(host, uuid)) continue;
      if (host === groupId) return coord;
    }
    return undefined;
  }

  async pullFreshSnapshot(groupId: string): Promise<SonosGroupSnapshot | undefined> {
    const coord = this.resolveCoordinator(groupId);
    if (!coord) return undefined;
    await this.refreshSnapshot(coord);
    return this.snapshots.get(groupId);
  }

  async play(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    this.scheduleCommandConfirmationRefresh(coord, groupId);
    try {
      await coord.Play();
    } catch (err) {
      this.cancelCommandConfirmationRefresh(groupId);
      throw err;
    }
  }

  async pause(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    this.scheduleCommandConfirmationRefresh(coord, groupId);
    try {
      await coord.Pause();
    } catch (err) {
      this.cancelCommandConfirmationRefresh(groupId);
      throw err;
    }
  }

  async next(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    this.scheduleCommandConfirmationRefresh(coord, groupId, true);
    try {
      await coord.Next();
    } catch (err) {
      this.cancelCommandConfirmationRefresh(groupId);
      throw err;
    }
  }

  async previous(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    this.scheduleCommandConfirmationRefresh(coord, groupId, true);
    try {
      await coord.Previous();
    } catch (err) {
      this.cancelCommandConfirmationRefresh(groupId);
      throw err;
    }
  }

  async listFavorites(groupId: string): Promise<SonosFavoriteItem[]> {
    return await this.loadFavorites(this.requireCoordinator(groupId));
  }

  async currentFavoriteStatus(groupId: string): Promise<SonosCurrentFavoriteStatus> {
    const coord = this.requireCoordinator(groupId);
    const snapshot = this.current(groupId) ?? await this.pullFreshSnapshot(groupId);
    const position = await coord.AVTransportService.GetPositionInfo();
    const uri = firstNonEmpty(position.TrackURI, snapshot?.trackUri);
    const available = Boolean(uri)
      && snapshot?.playbackSourceRaw !== 'tv'
      && Number(snapshot?.durationSeconds ?? 0) > 0;
    if (!available || !uri) return { available: false, isFavorite: false, favorite: null };

    const favorite = favoriteForCurrentURI(await this.loadFavorites(coord), uri) ?? null;
    return { available: true, isFavorite: favorite !== null, favorite };
  }

  async listQueue(groupId: string): Promise<SonosQueueView> {
    const coord = this.requireCoordinator(groupId);
    const [queue, position] = await Promise.all([
      coord.GetQueue(),
      coord.AVTransportService.GetPositionInfo(),
    ]);
    const view = sonosQueueView(groupId, queue.Result, queue.UpdateID, position.Track);
    this.queueViews.set(groupId, view);
    return this.applyCachedQueueArtwork(view);
  }

  async resolveQueueArtworkAlbums(
    groupId: string,
    albumKeys: string[],
  ): Promise<SonosQueueArtworkResult[]> {
    if (!this.artworkResolver) return [];
    let view = this.queueViews.get(groupId);
    if (!view) {
      await this.listQueue(groupId);
      view = this.queueViews.get(groupId);
    }
    if (!view) return [];

    const requested = [...new Set(albumKeys
      .filter((key): key is string => typeof key === 'string' && key.trim().length > 0)
      .map(key => key.trim()))]
      .slice(0, QUEUE_ARTWORK_BATCH_LIMIT);
    const representatives = new Map<string, SonosQueueItem>();
    for (const item of view.items) {
      if (requested.includes(item.albumKey) && !representatives.has(item.albumKey)) {
        representatives.set(item.albumKey, item);
      }
    }

    const resolved = new Map<string, QueueArtworkCacheEntry>();
    await mapWithConcurrency([...representatives.entries()], 2, async ([albumKey, item]) => {
      resolved.set(albumKey, await this.resolveQueueAlbumArtwork(groupId, albumKey, item));
    });
    return requested.flatMap(albumKey => {
      const artwork = resolved.get(albumKey);
      return artwork ? [{
        albumKey,
        albumArtUri: artwork.url,
        artworkSource: artwork.source,
      }] : [];
    });
  }

  private applyCachedQueueArtwork(view: SonosQueueView): SonosQueueView {
    return {
      ...view,
      items: view.items.map(item => {
        const artwork = this.queueArtworkCache.get(item.albumKey);
        return artwork?.url && artwork.expiresAt > Date.now()
          ? { ...item, albumArtUri: artwork.url, artworkSource: artwork.source }
          : item;
      }),
    };
  }

  private async resolveQueueAlbumArtwork(
    groupId: string,
    albumKey: string,
    item: SonosQueueItem,
  ): Promise<QueueArtworkCacheEntry> {
    const now = Date.now();
    const cached = this.queueArtworkCache.get(albumKey);
    if (cached && cached.expiresAt > now) return cached;
    const pending = this.queueArtworkInFlight.get(albumKey);
    if (pending) return await pending;
    if (this.queueArtworkBackoffUntil > now) {
      return this.rememberQueueArtwork(albumKey, {
        url: null,
        source: 'none',
        expiresAt: this.queueArtworkBackoffUntil,
      });
    }

    const request = (async () => {
      try {
        await this.waitForQueueArtworkLookupSlot();
        if (this.queueArtworkBackoffUntil > Date.now()) {
          return this.rememberQueueArtwork(albumKey, {
            url: null,
            source: 'none',
            expiresAt: this.queueArtworkBackoffUntil,
          });
        }
        const resolution = await this.artworkResolver!.resolve({
          groupId,
          trigger: 'queue',
          title: item.title,
          artist: item.artist,
          album: item.album,
          trackUri: item.uri,
          albumArtUri: item.sonosAlbumArtUri,
          playbackSourceRaw: playbackSourceFromTrackUri(item.uri),
        });
        if (resolution.fallbackErrorStatus === 'rate-limited') {
          this.queueArtworkBackoffUntil = Date.now() + QUEUE_ARTWORK_RATE_LIMIT_BACKOFF_MS;
          this.log.warn(
            { album: item.album, albumKey, backoffMs: QUEUE_ARTWORK_RATE_LIMIT_BACKOFF_MS },
            'queue artwork iTunes lookup entered rate-limit backoff',
          );
        }
        const publicFallback = publicQueueArtworkURL(resolution.fallbackUrl);
        const publicPrimary = resolution.source === 'getaa'
          ? null
          : publicQueueArtworkURL(resolution.url);
        const url = publicFallback ?? publicPrimary;
        const source = url
          ? queueArtworkSource(publicFallback ? resolution.fallbackSource : resolution.source)
          : 'none';
        return this.rememberQueueArtwork(albumKey, {
          url,
          source,
          expiresAt: now + (url ? QUEUE_ARTWORK_CACHE_TTL_MS : QUEUE_ARTWORK_MISS_TTL_MS),
        });
      } catch (error) {
        this.log.debug({ error, album: item.album, albumKey }, 'queue album artwork resolution failed');
        return this.rememberQueueArtwork(albumKey, {
          url: null,
          source: 'none',
          expiresAt: now + QUEUE_ARTWORK_MISS_TTL_MS,
        });
      }
    })();
    this.queueArtworkInFlight.set(albumKey, request);
    try {
      return await request;
    } finally {
      this.queueArtworkInFlight.delete(albumKey);
    }
  }

  private rememberQueueArtwork(albumKey: string, entry: QueueArtworkCacheEntry): QueueArtworkCacheEntry {
    this.queueArtworkCache.delete(albumKey);
    this.queueArtworkCache.set(albumKey, entry);
    while (this.queueArtworkCache.size > QUEUE_ARTWORK_CACHE_MAX_ENTRIES) {
      const oldest = this.queueArtworkCache.keys().next().value as string | undefined;
      if (!oldest) break;
      this.queueArtworkCache.delete(oldest);
    }
    return entry;
  }

  private async waitForQueueArtworkLookupSlot(): Promise<void> {
    let release!: () => void;
    const turn = new Promise<void>(resolve => { release = resolve; });
    const previous = this.queueArtworkLookupTail;
    this.queueArtworkLookupTail = turn;
    await previous;
    try {
      const waitMs = Math.max(0, this.nextQueueArtworkLookupAt - Date.now());
      if (waitMs > 0) await queueArtworkLookupDelay(waitMs);
      this.nextQueueArtworkLookupAt = Date.now() + QUEUE_ARTWORK_LOOKUP_INTERVAL_MS;
    } finally {
      release();
    }
  }

  async playFavorite(groupId: string, favoriteId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    const favorites = await this.loadFavorites(coord);
    const favorite = favorites.find(item => item.id === favoriteId);
    if (!favorite) throw new Error(`unknown_favorite: no Sonos Favorite ${favoriteId}`);
    if (favorite.playbackKind === 'artistStation') {
      const artistStationId = favorite.artistStationId ?? await resolveAppleMusicArtistId(favorite.title);
      const station = artistStationId
        ? buildAppleMusicArtistStationPlayback({ ...favorite, artistStationId }, favorites)
        : null;
      if (!station) throw new Error(`artist_station_unavailable: ${favorite.title}`);
      await coord.AVTransportService.SetAVTransportURI({
        InstanceID: 0,
        CurrentURI: station.uri,
        CurrentURIMetaData: encodeSonosSoapMetadata(station.metadata),
      });
      await playbackSettleDelay(800);
      await coord.Play();
      await this.refreshSnapshot(coord, 'sonos-change', { suppressTransientNonPlaying: true });
      return;
    }
    if (favorite.playbackKind !== 'direct' || !favorite.uri || !favorite.resourceMetadata) {
      throw new Error(`favorite_not_playable: ${favorite.title}`);
    }

    if (favoriteUsesDirectTransport(favorite)) {
      await coord.AVTransportService.SetAVTransportURI({
        InstanceID: 0,
        CurrentURI: favorite.uri,
        CurrentURIMetaData: encodeSonosSoapMetadata(favorite.resourceMetadata),
      });
      await coord.Play();
      await this.refreshSnapshot(coord, 'sonos-change', { suppressTransientNonPlaying: true });
      return;
    }

    // Match the iOS LAN playback path for albums, playlists and tracks. Sonos
    // content containers cannot be loaded as the active transport directly;
    // they must first expand into the coordinator's queue.
    try {
      await coord.AVTransportService.RemoveAllTracksFromQueue({ InstanceID: 0 });
    } catch (err) {
      // Sonos returns UPnP 804 when the queue is already empty. iOS treats
      // queue clearing as best-effort as well, so continue to AddURIToQueue.
      this.log.debug({ err, groupId, favoriteId }, 'favorite queue was already empty or could not be cleared');
    }
    const added = await coord.AVTransportService.AddURIToQueue({
      InstanceID: 0,
      EnqueuedURI: favorite.uri,
      EnqueuedURIMetaData: encodeSonosSoapMetadata(favorite.resourceMetadata),
      DesiredFirstTrackNumberEnqueued: 0,
      EnqueueAsNext: false,
    });
    const coordinatorUuid = firstNonEmpty(coord.Uuid);
    if (!coordinatorUuid) {
      throw new Error(`favorite_playback_unavailable: coordinator UUID is missing for ${favorite.title}`);
    }
    await coord.AVTransportService.SetAVTransportURI({
      InstanceID: 0,
      CurrentURI: `x-rincon-queue:${coordinatorUuid}#0`,
      CurrentURIMetaData: '',
    });
    const firstTrackNumber = Math.max(1, Number(added.FirstTrackNumberEnqueued) || 1);
    await coord.AVTransportService.Seek({
      InstanceID: 0,
      Unit: 'TRACK_NR',
      Target: String(firstTrackNumber),
    });
    await coord.Play();
    await this.refreshSnapshot(coord, 'sonos-change', { suppressTransientNonPlaying: true });
  }

  async addCurrentTrackToFavorites(groupId: string): Promise<SonosFavoriteAddResult> {
    const coord = this.requireCoordinator(groupId);
    const snapshot = this.current(groupId) ?? await this.pullFreshSnapshot(groupId);
    if (!snapshot || snapshot.playbackSourceRaw === 'tv' || snapshot.durationSeconds <= 0) {
      throw new Error('current_favorite_unavailable: select a regular music track first');
    }

    const position = await coord.AVTransportService.GetPositionInfo();
    const uri = firstNonEmpty(position.TrackURI, snapshot.trackUri);
    if (!uri) throw new Error('current_favorite_unavailable: current track URI is missing');

    const favorites = await this.loadFavorites(coord);
    const existing = favoriteForCurrentURI(favorites, uri);
    if (existing) return { added: false, alreadyExists: true, favorite: existing };

    const positionMetadata = position.TrackMetaData as { UpnpClass?: unknown } | null | undefined;
    const favoriteInput = {
      title: snapshot.trackTitle,
      artist: snapshot.artist,
      album: snapshot.album,
      albumArtUri: snapshot.albumArtUri ?? snapshot.albumArtFallbackUri ?? null,
      uri,
      upnpClass: firstObjectString(positionMetadata?.UpnpClass),
      serviceDescriptor: serviceDescriptorForCurrentURI(favorites, uri),
    };
    const resourceMetadata = buildCurrentTrackResourceMetadata(favoriteInput);
    const response = await coord.ContentDirectoryService.CreateObject({
      ContainerID: 'FV:2',
      // @svrooij/sonos inserts ContentDirectory `Elements` verbatim instead
      // of encoding it as an XML string. CreateObject expects escaped DIDL
      // here, matching the iOS SonosAPI SOAP body.
      Elements: encodeSonosSoapMetadata(buildFavoriteCreateElements(favoriteInput)),
    });
    const created: SonosFavoriteItem = {
      id: firstNonEmpty(response.ObjectID, `FV:2/${Date.now()}`),
      title: snapshot.trackTitle,
      description: snapshot.trackTitle,
      type: 'instantPlay',
      category: 'song',
      playbackKind: 'direct',
      artistStationId: null,
      albumArtUri: snapshot.albumArtUri ?? snapshot.albumArtFallbackUri ?? null,
      uri,
      resourceMetadata,
      playbackSourceRaw: snapshot.playbackSourceRaw ?? null,
      playable: true,
    };
    return { added: true, alreadyExists: false, favorite: created };
  }

  async setGroupVolume(groupId: string, volume: number): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    const v = Math.min(100, Math.max(0, Math.round(volume)));
    await this.coalesceVolumeWrite(`group:${groupId}`, v, async desiredVolume => {
      await coord.GroupRenderingControlService.SetGroupVolume({
        InstanceID: 0,
        DesiredVolume: desiredVolume,
      });
      this.applyOptimisticGroupVolume(groupId, desiredVolume);
    });
  }

  private async loadFavorites(coord: SonosDevice): Promise<SonosFavoriteItem[]> {
    const response = await coord.ContentDirectoryService.Browse({
      ObjectID: 'FV:2',
      BrowseFlag: 'BrowseDirectChildren',
      Filter: '*',
      StartingIndex: 0,
      RequestedCount: 0,
      SortCriteria: '',
    });
    return parseSonosFavorites(response.Result, coord.Host);
  }

  async setMemberVolume(groupId: string, memberId: string, volume: number): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    const desiredVolume = Math.min(100, Math.max(0, Math.round(volume)));
    await this.coalesceVolumeWrite(`member:${groupId}:${memberId}`, desiredVolume, async latestVolume => {
      const cachedMembers = this.snapshots.get(groupId)?.groupMembers ?? [];
      const members = cachedMembers.length > 0
        ? cachedMembers
        : await this.groupMembersForCoordinator(coord, groupId);
      const member = members.find(candidate => candidate.id === memberId || candidate.host === memberId);
      if (!member) throw new Error(`unknown_member: no visible Sonos member ${memberId} in ${groupId}`);

      const device = this.findDevice(member.host, member.id);
      const service = renderingControlService(device);
      if (!service || typeof service.SetVolume !== 'function') {
        throw new Error(`missing_rendering_control_service: ${member.name}`);
      }
      await service.SetVolume({ InstanceID: 0, Channel: 'Master', DesiredVolume: latestVolume });
      this.applyOptimisticMemberVolume(groupId, member.id, member.host, latestVolume);
    });
  }

  /// Moves every visible member of one Sonos group into another group.
  async mergeGroups(sourceGroupId: string, intoGroupId: string): Promise<void> {
    if (sourceGroupId === intoGroupId) {
      throw new Error('same_group: source and destination groups must be different');
    }

    const groups = await this.loadAllZoneGroups();
    const source = this.requireZoneGroup(groups, sourceGroupId);
    const target = this.requireZoneGroup(groups, intoGroupId);
    const targetCoordinatorUuid = firstObjectString(target.coordinator?.uuid);
    if (!targetCoordinatorUuid) {
      throw new Error(`missing_coordinator: no coordinator UUID for group ${intoGroupId}`);
    }

    const members = this.visibleZoneMembers(source);
    if (!members.length) {
      throw new Error(`empty_group: no visible members for group ${sourceGroupId}`);
    }

    for (const member of members) {
      const device = this.requireZoneMemberDevice(member);
      await device.AVTransportService.SetAVTransportURI({
        InstanceID: 0,
        CurrentURI: `x-rincon:${targetCoordinatorUuid}`,
        CurrentURIMetaData: '',
      });
      if (members.length > 1) await topologyMutationDelay(300);
    }

    await this.refreshTopologyAfterMutation();
  }

  /// Separates every non-coordinator member, leaving each visible room standalone.
  async separateGroup(groupId: string): Promise<void> {
    const groups = await this.loadAllZoneGroups();
    const source = this.requireZoneGroup(groups, groupId);
    const coordinatorUuid = firstObjectString(source.coordinator?.uuid);
    const members = this.visibleZoneMembers(source)
      .filter(member => firstObjectString(member.uuid) !== coordinatorUuid);
    if (!members.length) return;

    for (const member of members) {
      const device = this.requireZoneMemberDevice(member);
      await device.AVTransportService.BecomeCoordinatorOfStandaloneGroup({ InstanceID: 0 });
      if (members.length > 1) await topologyMutationDelay(300);
    }

    await this.refreshTopologyAfterMutation();
  }

  async setSoundbarNightMode(groupId: string, enabled: boolean): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    await this.setEQLevel(coord, 'NightMode', enabled ? 1 : 0);
    await this.refreshSnapshot(coord);
  }

  async setSoundbarSpeechEnhancementRawLevel(groupId: string, rawLevel: number): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    const level = clampSpeechEnhancementLevel(rawLevel);
    if (level === 0) {
      await this.setOptionalEQLevel(coord, 'SpeechEnhanceEnabled', 0);
      await this.setEQLevel(coord, 'DialogLevel', 0);
    } else {
      await this.setEQLevel(coord, 'DialogLevel', level);
      await this.setOptionalEQLevel(coord, 'SpeechEnhanceEnabled', 1);
    }
    await this.refreshSnapshot(coord);
  }

  private requireCoordinator(groupId: string): SonosDevice {
    const coord = this.resolveCoordinator(groupId);
    if (!coord) {
      throw new Error(`unknown_group: no coordinator matches groupId ${groupId}`);
    }
    return coord;
  }

  private async loadAllZoneGroups(
    sourceManager: SonosManager = this.manager,
  ): Promise<ParsedZoneGroup[]> {
    const manager = sourceManager as unknown as {
      LoadAllGroups?: () => Promise<ParsedZoneGroup[]>;
    };
    if (typeof manager.LoadAllGroups !== 'function') {
      throw new Error('grouping_unavailable: Sonos topology service is unavailable');
    }
    return manager.LoadAllGroups.call(sourceManager);
  }

  private requireZoneGroup(groups: ParsedZoneGroup[], groupId: string): ParsedZoneGroup {
    const group = groups.find(candidate => zoneGroupMatchesCoordinator(candidate, groupId, groupId));
    if (!group) throw new Error(`unknown_group: no Sonos topology group matches ${groupId}`);
    return group;
  }

  private visibleZoneMembers(group: ParsedZoneGroup): NonNullable<ParsedZoneGroup['members']> {
    return (group.members ?? [])
      .filter(member => !isInvisibleDevice(member as unknown as Record<string, unknown>));
  }

  private requireZoneMemberDevice(member: NonNullable<ParsedZoneGroup['members']>[number]): SonosDevice {
    const host = firstObjectString(member.host) ?? '';
    const uuid = firstObjectString(member.uuid) ?? '';
    const device = this.manager.Devices.find(candidate => (
      (host && candidate.Host === host) || (uuid && candidate.Uuid === uuid)
    ));
    if (!device) {
      throw new Error(`unknown_player: no Sonos device matches ${uuid || host || 'topology member'}`);
    }
    return device;
  }

  private async refreshTopologyAfterMutation(): Promise<void> {
    await topologyMutationDelay(500);
    await this.refreshTopologySnapshots('sonos-change');
  }

  // ---- internals --------------------------------------------------------

  private async runPlaybackWatchdog(): Promise<void> {
    this.periodicCycle += 1;
    if (this.periodicCycle % this.fullHouseWatchdogEveryCycles === 0) {
      await this.refreshTopologySnapshots('periodic-refresh');
      return;
    }

    const activeGroupIds = [...this.snapshots.values()]
      .filter(snapshot => snapshot.isPlaying)
      .map(snapshot => snapshot.groupId);
    await Promise.all(activeGroupIds.map(async groupId => {
      const coordinator = this.resolveCoordinator(groupId);
      if (!coordinator) return;
      await this.refreshSnapshot(coordinator, 'periodic-refresh', {
        includeGroupDetails: false,
      });
    }));
  }

  private coalesceVolumeWrite(
    key: string,
    volume: number,
    operation: (volume: number) => Promise<void>,
  ): Promise<void> {
    if (this.volumeCommandDebounceMs <= 0) return operation(volume);

    return new Promise<void>((resolve, reject) => {
      const existing = this.pendingVolumeWrites.get(key);
      if (existing) {
        existing.volume = volume;
        existing.operation = operation;
        existing.waiters.push({ resolve, reject });
        clearTimeout(existing.timer);
        existing.timer = this.volumeWriteTimer(key);
        return;
      }

      const pending: PendingVolumeWrite = {
        volume,
        operation,
        timer: this.volumeWriteTimer(key),
        waiters: [{ resolve, reject }],
      };
      this.pendingVolumeWrites.set(key, pending);
    });
  }

  private volumeWriteTimer(key: string): NodeJS.Timeout {
    const timer = setTimeout(() => {
      void this.flushVolumeWrite(key);
    }, this.volumeCommandDebounceMs);
    return timer;
  }

  private async flushVolumeWrite(key: string): Promise<void> {
    const pending = this.pendingVolumeWrites.get(key);
    if (!pending) return;
    this.pendingVolumeWrites.delete(key);
    try {
      await pending.operation(pending.volume);
      for (const waiter of pending.waiters) waiter.resolve();
    } catch (err) {
      for (const waiter of pending.waiters) waiter.reject(err);
    }
  }

  private applyOptimisticGroupVolume(groupId: string, volume: number): void {
    const previous = this.snapshots.get(groupId);
    if (!previous || previous.groupVolume === volume) return;
    this.publishSnapshot({ ...previous, groupVolume: volume, sampledAt: new Date() }, 'sonos-change');
  }

  private applyOptimisticMemberVolume(
    groupId: string,
    memberId: string,
    memberHost: string,
    volume: number,
  ): void {
    const previous = this.snapshots.get(groupId);
    if (!previous) return;
    const groupMembers = (previous.groupMembers ?? []).map(member => (
      member.id === memberId || member.host === memberHost
        ? { ...member, volume }
        : member
    ));
    this.publishSnapshot({ ...previous, groupMembers, sampledAt: new Date() }, 'sonos-change');
  }

  private attachManagerListeners(manager: SonosManager): void {
    this.attachManagerTopologyListener(manager);

    for (const device of manager.Devices) {
      if (!shouldAttachSonosDeviceEvents(device)) continue;
      this.log.info(
        { name: device.Name, host: device.Host, uuid: device.Uuid },
        'attached Sonos device',
      );
      this.attachDeviceListeners(device);
    }

    const managerWithNewDevice = manager as unknown as {
      OnNewDevice?: (listener: (device: SonosDevice) => void) => void;
    };
    managerWithNewDevice.OnNewDevice?.(device => {
      if (shouldAttachSonosDeviceEvents(device)) {
        this.log.info(
          { name: device.Name, host: device.Host, uuid: device.Uuid },
          'attached newly discovered Sonos device',
        );
        this.attachDeviceListeners(device);
      }
      this.scheduleTopologyRefresh();
    });
  }

  private attachManagerTopologyListener(manager: SonosManager): void {
    this.detachManagerTopologyListener();
    // SonosManager already owns the GENA subscription. Listening to its
    // existing service emitter adds no second subscription or polling loop.
    const zoneService = (manager as unknown as {
      zoneService?: { Events?: EventEmitter };
    }).zoneService;
    const events = zoneService?.Events;
    if (!events) {
      this.log.debug('Sonos manager has no ZoneGroupTopology event emitter');
      return;
    }

    const listener = (data: unknown): void => {
      if (
        typeof data !== 'object'
        || data === null
        || !Object.prototype.hasOwnProperty.call(data, 'ZoneGroupState')
      ) {
        return;
      }
      this.scheduleTopologyRefresh();
    };
    events.on(ServiceEvents.ServiceEvent, listener);
    this.attachedManagerTopologyListener = { manager, events, listener };
  }

  private detachManagerTopologyListener(manager?: SonosManager): void {
    const attached = this.attachedManagerTopologyListener;
    if (!attached || (manager && attached.manager !== manager)) return;
    attached.events.off(ServiceEvents.ServiceEvent, attached.listener);
    this.attachedManagerTopologyListener = null;
  }

  private attachDeviceListeners(device: any): void {
    // sonos-ts devices have an Events emitter that re-emits a useful subset
    // of the underlying UPnP service events. We just need a "something
    // happened, please re-snapshot" trigger; the actual state we always pull
    // fresh via PositionInfo / TransportInfo to avoid event-payload drift
    // between firmware versions.
    const key = firstNonEmpty(device?.Uuid, device?.Host, device?.Name);
    if (key && this.attachedDeviceListenerKeys.has(key)) return;
    if (key) this.attachedDeviceListenerKeys.add(key);
    try {
      const listeners: AttachedDeviceListeners['listeners'] = [
        { event: SonosEvents.AVTransport, listener: () => this.scheduleEventRefresh(device) },
        { event: SonosEvents.CurrentTrackUri, listener: () => this.scheduleEventRefresh(device) },
        { event: SonosEvents.CurrentTrackMetadata, listener: () => this.scheduleEventRefresh(device) },
        { event: SonosEvents.CurrentTransportState, listener: () => this.scheduleEventRefresh(device) },
        { event: SonosEvents.CurrentTransportStateSimple, listener: () => this.scheduleEventRefresh(device) },
        { event: SonosEvents.PlaybackStopped, listener: () => this.scheduleEventRefresh(device) },
        {
          event: SonosEvents.Volume,
          listener: (volume: unknown) => this.scheduleVolumeEventRefresh(device, volume),
        },
        { event: SonosEvents.Coordinator, listener: () => this.scheduleTopologyRefresh() },
        { event: SonosEvents.GroupName, listener: () => this.scheduleTopologyRefresh() },
      ];
      for (const { event, listener } of listeners) device.Events.on(event, listener);
      if (key) this.attachedDeviceListeners.set(key, { device, listeners });
    } catch (err) {
      this.log.warn({ err, device: device.Name }, 'failed to attach device events');
    }
  }

  private scheduleEventRefresh(device: any): void {
    const groupId = this.snapshotGroupId(device)
      ?? firstNonEmpty(device?.Host, device?.Uuid, device?.Name)
      ?? 'unknown';
    this.cancelCommandConfirmationRefresh(groupId);

    if (this.eventRefreshDebounceMs <= 0) {
      void this.refreshSnapshot(device, 'sonos-change', { includeGroupDetails: false }).catch(err => {
        this.log.debug({ err, groupId }, 'debounced Sonos event refresh failed');
      });
      return;
    }

    const existing = this.eventRefreshTimers.get(groupId);
    if (existing) clearTimeout(existing);

    const timer = setTimeout(() => {
      this.eventRefreshTimers.delete(groupId);
      void this.refreshSnapshot(device, 'sonos-change', { includeGroupDetails: false }).catch(err => {
        this.log.debug({ err, groupId }, 'debounced Sonos event refresh failed');
      });
    }, this.eventRefreshDebounceMs);
    timer.unref?.();
    this.eventRefreshTimers.set(groupId, timer);
  }

  private scheduleVolumeEventRefresh(device: any, eventVolume: unknown): void {
    const groupId = this.snapshotGroupId(device)
      ?? firstNonEmpty(device?.Host, device?.Uuid, device?.Name)
      ?? 'unknown';
    this.cancelCommandConfirmationRefresh(groupId);

    const existing = this.volumeEventRefreshTimers.get(groupId);
    if (existing) clearTimeout(existing);
    const timer = setTimeout(() => {
      this.volumeEventRefreshTimers.delete(groupId);
      void this.refreshVolumeSnapshot(device, eventVolume).catch(err => {
        this.log.debug({ err, groupId }, 'lightweight Sonos volume refresh failed');
      });
    }, Math.max(0, this.eventRefreshDebounceMs));
    timer.unref?.();
    this.volumeEventRefreshTimers.set(groupId, timer);
  }

  private async refreshVolumeSnapshot(device: any, eventVolume: unknown): Promise<void> {
    const groupId = this.snapshotGroupId(device);
    if (!groupId) return;
    const previous = this.snapshots.get(groupId);
    if (!previous) {
      await this.refreshSnapshot(device);
      return;
    }

    const coordinator = device?.Coordinator ?? device;
    const groupVolume = await this.groupVolumeForSnapshot(coordinator, previous.groupVolume);
    const coordinatorHost = firstNonEmpty(coordinator?.Host, device?.Host);
    const coordinatorUuid = firstNonEmpty(coordinator?.Uuid, device?.Uuid);
    const numericEventVolume = Number(eventVolume);
    const groupMembers = Number.isFinite(numericEventVolume)
      ? (previous.groupMembers ?? []).map(member => (
        (coordinatorHost && member.host === coordinatorHost)
          || (coordinatorUuid && member.id === coordinatorUuid)
          ? { ...member, volume: Math.min(100, Math.max(0, Math.round(numericEventVolume))) }
          : member
      ))
      : previous.groupMembers ?? [];
    this.publishSnapshot({
      ...previous,
      groupVolume,
      groupMembers,
      sampledAt: new Date(),
    }, 'sonos-change');
  }

  private detachDeviceListeners(): void {
    for (const { device, listeners } of this.attachedDeviceListeners.values()) {
      for (const { event, listener } of listeners) device.Events?.off?.(event, listener);
    }
    this.attachedDeviceListeners.clear();
    this.attachedDeviceListenerKeys.clear();
  }

  private scheduleTopologyRefresh(): void {
    if (this.topologyRefreshTimer) clearTimeout(this.topologyRefreshTimer);
    this.topologyRefreshTimer = setTimeout(() => {
      this.topologyRefreshTimer = null;
      void this.refreshTopologySnapshots('sonos-change').catch(err => {
        this.log.debug({ err }, 'Sonos topology event refresh failed');
      });
    }, this.eventRefreshDebounceMs);
    this.topologyRefreshTimer.unref?.();
  }

  private async refreshTopologySnapshots(trigger: SonosSnapshotChangeTrigger): Promise<void> {
    let groups: ParsedZoneGroup[];
    try {
      groups = await this.loadAllZoneGroups();
    } catch (err) {
      if (errorSummary(err).includes('grouping_unavailable')) {
        // Keep compatibility with older or lightweight SonosManager
        // implementations that never exposed parsed topology at all. This is
        // not a stale network seed and therefore cannot be repaired by trying
        // alternate IPs.
        await this.refreshDiscoveredCoordinatorSnapshots(trigger);
        return;
      }
      this.log.warn({ err }, 'Sonos topology seed unavailable; attempting alternate speakers');
      const recoveredGroups = await this.recoverTopologyFromAlternateSpeaker();
      if (!recoveredGroups) {
        // Older/mocked sonos-ts managers may not expose parsed topology. Keep a
        // deduplicated coordinator fallback instead of failing discovery.
        this.log.warn({ err }, 'Sonos topology recovery failed; using discovered coordinator fallback');
        await this.refreshDiscoveredCoordinatorSnapshots(trigger);
        return;
      }
      groups = recoveredGroups;
    }

    const activeGroupIds = new Set<string>();
    const coordinatorKeys = new Set<string>();
    const coordinators: Array<{ device: SonosDevice; group: ParsedZoneGroup }> = [];

    for (const group of groups) {
      const host = firstObjectString(group.coordinator?.host);
      const uuid = firstObjectString(group.coordinator?.uuid);
      const coordinatorMember = (group.members ?? []).find(member => (
        (host && firstObjectString(member.host) === host)
        || (uuid && firstObjectString(member.uuid) === uuid)
      ));
      if (
        isInvisibleDevice(group.coordinator as unknown as Record<string, unknown>)
        || (coordinatorMember
          && isInvisibleDevice(coordinatorMember as unknown as Record<string, unknown>))
      ) {
        continue;
      }

      const coordinator = this.manager.Devices.find(device => (
        (host && device.Host === host) || (uuid && device.Uuid === uuid)
      ));
      if (!coordinator) {
        this.log.debug({ groupId: host || uuid }, 'topology coordinator device is not attached');
        continue;
      }

      const resolvedHost = firstNonEmpty(host, coordinator.Host);
      const resolvedUuid = firstNonEmpty(uuid, coordinator.Uuid);
      if (resolvedHost) {
        activeGroupIds.add(resolvedHost);
        coordinatorKeys.add(resolvedHost);
      }
      if (resolvedUuid) coordinatorKeys.add(resolvedUuid);
      coordinators.push({ device: coordinator, group });
      // Bonded stereo partners, surrounds, and Subs are represented through
      // their coordinator. They do not need their own transport/rendering
      // event subscriptions.
      this.attachDeviceListeners(coordinator);
    }

    this.visibleTopologyCoordinatorKeys = coordinatorKeys;
    this.topologyFilterReady = true;

    await Promise.all(coordinators.map(async ({ device: coordinator, group }) => {
      try {
        await this.refreshSnapshot(coordinator, trigger, { topologyVerified: true, topologyGroup: group });
      } catch (err) {
        this.log.debug(
          { err, groupId: coordinator.Host ?? coordinator.Uuid },
          'topology coordinator snapshot refresh failed',
        );
      }
    }));

    for (const groupId of this.snapshots.keys()) {
      if (!activeGroupIds.has(groupId)) this.snapshots.delete(groupId);
    }
  }

  private async recoverTopologyFromAlternateSpeaker(): Promise<ParsedZoneGroup[] | null> {
    if (this.topologyRecoveryPromise) return this.topologyRecoveryPromise;

    this.topologyRecoveryPromise = this.performTopologyRecovery();
    try {
      return await this.topologyRecoveryPromise;
    } finally {
      this.topologyRecoveryPromise = null;
    }
  }

  private async performTopologyRecovery(): Promise<ParsedZoneGroup[] | null> {
    const candidates = this.topologyRecoveryCandidateIPs();
    for (const [index, seedIp] of candidates.entries()) {
      const candidateManager = this.managerFactory();
      try {
        const initialized = await candidateManager.InitializeFromDevice(seedIp);
        if (!initialized) throw new Error('seed did not initialize a Sonos household');
        const groups = await this.loadAllZoneGroups(candidateManager);
        if (groups.length === 0) throw new Error('seed returned an empty Sonos topology');
        this.replaceManager(candidateManager);
        this.discoveryState = { ...this.discoveryState, status: 'ready', error: null };
        this.log.info(
          { seedIp, attempts: index + 1, groups: groups.length },
          'Sonos topology recovered through alternate speaker',
        );
        return groups;
      } catch (err) {
        this.cancelManagerSubscription(candidateManager);
        this.log.debug(
          { err, seedIp, attempt: index + 1 },
          'alternate Sonos topology seed failed',
        );
      }
    }

    const discoveredManager = this.managerFactory();
    try {
      const initialized = await discoveredManager.InitializeWithDiscovery(
        this.topologyRecoveryDiscoveryTimeoutSeconds,
      );
      if (!initialized) throw new Error('SSDP did not discover a Sonos household');
      const groups = await this.loadAllZoneGroups(discoveredManager);
      if (groups.length === 0) throw new Error('SSDP returned an empty Sonos topology');
      this.replaceManager(discoveredManager);
      this.discoveryState = { mode: 'auto', status: 'ready', error: null };
      this.log.info(
        { groups: groups.length },
        'Sonos topology recovered through fresh SSDP discovery',
      );
      return groups;
    } catch (err) {
      this.cancelManagerSubscription(discoveredManager);
      this.log.warn({ err, candidates: candidates.length }, 'fresh Sonos topology discovery failed');
      return null;
    }
  }

  private topologyRecoveryCandidateIPs(): string[] {
    const candidates: string[] = [];
    const seen = new Set<string>();
    const append = (value: unknown): void => {
      const host = firstObjectString(value);
      if (!host || seen.has(host)) return;
      seen.add(host);
      candidates.push(host);
    };

    const snapshots = [...this.snapshots.values()].sort((left, right) =>
      Number(right.isPlaying) - Number(left.isPlaying));
    for (const snapshot of snapshots) {
      append(snapshot.groupId);
      for (const member of snapshot.groupMembers ?? []) append(member.host);
    }

    try {
      for (const device of this.manager.Devices) {
        const coordinator = device.Coordinator ?? device;
        append(coordinator.Host);
        append(device.Host);
      }
    } catch {
      // The final SSDP attempt below can recover when no cached roster exists.
    }

    return candidates;
  }

  private replaceManager(nextManager: SonosManager): void {
    const previousManager = this.manager;
    this.detachDeviceListeners();
    this.detachManagerTopologyListener(previousManager);
    this.manager = nextManager;
    this.cancelManagerSubscription(previousManager);

    for (const timer of this.eventRefreshTimers.values()) clearTimeout(timer);
    this.eventRefreshTimers.clear();
    for (const timer of this.transitionSettleRefreshTimers.values()) clearTimeout(timer);
    this.transitionSettleRefreshTimers.clear();
    if (this.topologyRefreshTimer) clearTimeout(this.topologyRefreshTimer);
    this.topologyRefreshTimer = null;

    this.visibleTopologyCoordinatorKeys.clear();
    this.topologyFilterReady = false;
    this.attachManagerListeners(nextManager);
  }

  private cancelManagerSubscription(manager: SonosManager): void {
    try {
      manager.CancelSubscription();
    } catch (err) {
      this.log.debug({ err }, 'failed to cancel stale Sonos manager subscription');
    }
  }

  private async refreshDiscoveredCoordinatorSnapshots(trigger: SonosSnapshotChangeTrigger): Promise<void> {
    let devices: SonosDevice[];
    try {
      devices = this.manager.Devices;
    } catch (err) {
      this.log.debug({ err }, 'no discovered Sonos devices available for topology fallback');
      return;
    }
    const coordinators = new Map<string, SonosDevice>();
    for (const device of devices) {
      if (isInvisibleDevice(device as unknown as Record<string, unknown>)) continue;
      const coordinator = device.Coordinator ?? device;
      if (isInvisibleDevice(coordinator as unknown as Record<string, unknown>)) continue;
      const key = firstNonEmpty(coordinator.Host, coordinator.Uuid, device.Host, device.Uuid);
      if (key && !coordinators.has(key)) coordinators.set(key, coordinator);
    }
    await Promise.all([...coordinators.values()].map(coordinator => (
      this.refreshSnapshot(coordinator, trigger).catch(err => {
        this.log.debug(
          { err, groupId: coordinator.Host ?? coordinator.Uuid },
          'fallback coordinator snapshot refresh failed',
        );
      })
    )));
  }

  private isVisibleTopologyCoordinator(host: string, uuid: string): boolean {
    return Boolean(
      (host && this.visibleTopologyCoordinatorKeys.has(host))
      || (uuid && this.visibleTopologyCoordinatorKeys.has(uuid)),
    );
  }

  private async refreshSnapshot(
    device: any,
    trigger: SonosSnapshotChangeTrigger = 'sonos-change',
    options: RefreshSnapshotOptions = {},
  ): Promise<boolean> {
    let groupId: string | null = null;
    let refreshSequence = 0;
    try {
      // Use the coordinator LAN IP as the group identifier so iOS and the
      // relay agree without an extra mapping step. iOS sends `playbackIP`,
      // which is `coordinatorIP ?? ipAddress`.
      // Parsed ZoneGroupState is authoritative during topology refreshes.
      // sonos-ts can retain a stale `device.Coordinator` briefly after a room
      // leaves a group; following it here would write the departed room's
      // members into the old coordinator snapshot.
      const coordinator = options.topologyVerified ? device : (device.Coordinator ?? device);
      const resolvedGroupId = options.topologyVerified
        ? firstNonEmpty(device.Host, device.Uuid)
        : this.snapshotGroupId(device);
      if (!resolvedGroupId) {
        throw new Error(`missing Sonos group id for ${device.Name ?? 'unknown device'}`);
      }
      const coordinatorHost = firstNonEmpty(coordinator.Host, device.Host);
      const coordinatorUuid = firstNonEmpty(coordinator.Uuid, device.Uuid);
      if (
        this.topologyFilterReady
        && options.topologyVerified !== true
        && !this.isVisibleTopologyCoordinator(coordinatorHost, coordinatorUuid)
      ) {
        this.snapshots.delete(resolvedGroupId);
        return false;
      }
      groupId = resolvedGroupId;
      refreshSequence = this.beginRefresh(resolvedGroupId);
      const previousSnapshot = this.snapshots.get(resolvedGroupId);
      const transport = await coordinator.AVTransportService.GetTransportInfo();
      const position = await coordinator.AVTransportService.GetPositionInfo();
      if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;

      const transportStateRaw = String(transport.CurrentTransportState || 'UNKNOWN').toUpperCase();
      const isPlaying = transportStateRaw === 'PLAYING';
      const trackUri = firstNonEmpty(position.TrackURI, coordinator.CurrentTrackUri, device.CurrentTrackUri);
      let playbackSourceRaw = playbackSourceFromTrackUri(trackUri);
      const positionSeconds = parseDuration(position.RelTime ?? '00:00:00');
      const durationSeconds = parseDuration(position.TrackDuration ?? '00:00:00');
      const metadata = trackMetadataFromMetadata(position.TrackMetaData);
      const metadataDiagnostic = trackMetadataDiagnostic(position.TrackMetaData);
      let localPlaybackMetadata: SonosLocalPlaybackMetadata | null = null;
      let audioQualityLabel = audioQualityLabelFromMetadata(
        position.TrackMetaData,
        playbackSourceRaw,
      );
      let tvAudioFormat: SonosTVAudioFormatSnapshot | null = null;
      if (playbackSourceRaw === 'tv') {
        tvAudioFormat = await this.tvAudioFormatForSnapshot(coordinator);
        audioQualityLabel = tvAudioFormat?.geekLabel ?? audioQualityLabel;
        if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;
      } else {
        localPlaybackMetadata = await this.localControlPlaybackMetadata(coordinator, device);
        if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;
        if (!playbackSourceRaw || playbackSourceRaw === 'unknown') {
          playbackSourceRaw = playbackSourceFromServiceName(
            localPlaybackServiceName(localPlaybackMetadata),
          ) ?? playbackSourceRaw;
        }
        const localQuality = localPlaybackMetadata
          ? localPlaybackQualityFromPlaybackMetadata(localPlaybackMetadata)
          : this.localControl?.playbackMetadata
            ? null
            : await this.localControlPlaybackQuality(coordinator, device);
        if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;
        if (localQuality?.label) {
          audioQualityLabel = localQuality.label;
        }
      }
      const includeGroupDetails = options.includeGroupDetails
        ?? options.topologyVerified
        ?? previousSnapshot === undefined;
      const shouldRefreshSoundbarEQ = includeGroupDetails
        || (playbackSourceRaw === 'tv' && previousSnapshot?.playbackSourceRaw !== 'tv');
      const soundbarEQ = shouldRefreshSoundbarEQ
        ? await this.soundbarEQForSnapshot(coordinator, playbackSourceRaw)
        : {
          soundbarNightMode: previousSnapshot?.soundbarNightMode,
          soundbarSpeechEnhancementRawLevel: previousSnapshot?.soundbarSpeechEnhancementRawLevel,
        };
      if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;
      const groupVolume = includeGroupDetails || previousSnapshot?.groupVolume == null
        ? await this.groupVolumeForSnapshot(coordinator, previousSnapshot?.groupVolume)
        : previousSnapshot.groupVolume;
      if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;
      const groupMembers = includeGroupDetails || !(previousSnapshot?.groupMembers?.length)
        ? await this.groupMembersForCoordinator(
          coordinator,
          resolvedGroupId,
          options.topologyGroup,
        )
        : previousSnapshot.groupMembers ?? [];
      if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;

      // Prefer GetPositionInfo's parsed DIDL because radio streams put the
      // current song in r:streamContent while sonos-ts may cache that raw
      // `TYPE=SNG|TITLE ...` payload as Artist.
      let trackTitle = firstMeaningfulMetadata(
        'title',
        metadata.title,
        coordinator.CurrentTrack?.Title,
        device.CurrentTrack?.Title,
      );
      let artist = firstMeaningfulMetadata(
        'artist',
        metadata.artist,
        coordinator.CurrentTrack?.Artist,
        device.CurrentTrack?.Artist,
      );
      let album = firstMeaningfulMetadata(
        'album',
        metadata.album,
        coordinator.CurrentTrack?.Album,
        device.CurrentTrack?.Album,
      );
      const albumArtHost = coordinator.Host ?? device.Host ?? resolvedGroupId;
      const metadataAlbumArtUri = absoluteAlbumArtUri(
        coordinator.CurrentTrack?.AlbumArtUri
          ?? coordinator.CurrentTrack?.AlbumArtURI
          ?? device.CurrentTrack?.AlbumArtUri
          ?? device.CurrentTrack?.AlbumArtURI
          ?? metadata.albumArtUri,
        albumArtHost,
      );
      let albumArtUri = sonosGetAAAlbumArtUri(metadataAlbumArtUri)
        ?? albumArtUriFromTrackUri(trackUri, albumArtHost);
      let albumArtFallbackUri: string | null = null;

      if (shouldSuppressTransientNonPlayingSnapshot({
        options,
        trigger,
        previousSnapshot,
        trackTitle,
        isPlaying,
        positionSeconds,
        durationSeconds,
      })) {
        this.log.debug(
          {
            groupId: resolvedGroupId,
            trigger,
            transportState: String(transport.CurrentTransportState),
            previousTitle: previousSnapshot?.trackTitle ?? null,
            transientTitle: trackTitle,
          },
          'suppressed transient Sonos transition snapshot',
        );
        this.scheduleTransitionSettleRefresh(coordinator, resolvedGroupId);
        return false;
      }

      const liveStream = isLiveRadioSnapshot({
        trackUri,
        durationSeconds,
        playbackSourceRaw,
      });
      if (liveStream && localPlaybackMetadata) {
        const localTrackMetadata = trackMetadataFromLocalPlaybackMetadata(localPlaybackMetadata);
        trackTitle = firstMeaningfulMetadata('title', localTrackMetadata.title, trackTitle);
        artist = firstMeaningfulMetadata('artist', localTrackMetadata.artist, artist);
        album = firstMeaningfulMetadata('album', localTrackMetadata.album, album);
        const localAlbumArtUri = usableAlbumArtUri(
          absoluteAlbumArtUri(localTrackMetadata.albumArtUri, albumArtHost),
        );
        if (localAlbumArtUri) {
          albumArtUri = localAlbumArtUri;
        }
      }
      const heldPreviousLiveMetadata = shouldHoldPreviousLiveMetadata({
        liveStream,
        metadata,
        metadataDiagnostic,
        trackTitle,
        artist,
        previousSnapshot,
      });
      if (heldPreviousLiveMetadata && previousSnapshot) {
        trackTitle = previousSnapshot.trackTitle;
        artist = previousSnapshot.artist;
        album = previousSnapshot.album;
        albumArtUri = previousSnapshot.albumArtUri ?? albumArtUri;
        albumArtFallbackUri = previousSnapshot.albumArtFallbackUri ?? albumArtFallbackUri;
      }
      if (this.artworkResolver) {
        const artworkResolution = await this.artworkResolver.resolve({
          groupId: resolvedGroupId,
          trigger,
          title: trackTitle,
          artist,
          album,
          trackUri,
          albumArtUri,
          playbackSourceRaw,
        });
        if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;

        if (artworkResolution.url && artworkResolution.url !== albumArtUri) {
          this.log.debug(
            {
              groupId: resolvedGroupId,
              trigger,
              source: artworkResolution.source,
              catalogID: artworkResolution.catalogID ?? null,
              title: trackTitle,
              artist,
              album,
              previousAlbumArtUri: summarizeAlbumArtUri(albumArtUri),
              resolvedAlbumArtUri: summarizeAlbumArtUri(artworkResolution.url),
            },
            'snapshot album art resolver applied',
          );
          albumArtUri = artworkResolution.url;
          albumArtFallbackUri = null;
        } else {
          albumArtFallbackUri = usableAlbumArtUri(artworkResolution.fallbackUrl) ?? null;
          this.log.debug(
            {
              groupId: resolvedGroupId,
              trigger,
              source: artworkResolution.source,
              catalogID: artworkResolution.catalogID ?? null,
              fallbackSource: artworkResolution.fallbackSource ?? null,
              fallbackCatalogID: artworkResolution.fallbackCatalogID ?? null,
              title: trackTitle,
              artist,
              album,
              playbackSourceRaw,
              trackUri: summarizeTrackUri(trackUri),
              albumArtUri: summarizeAlbumArtUri(albumArtUri),
              fallbackAlbumArtUri: summarizeAlbumArtUri(albumArtFallbackUri),
            },
            'snapshot album art resolver kept current artwork',
          );
        }
      }
      if (liveStream) {
        this.log.debug(
          {
            groupId: resolvedGroupId,
            trigger,
            trackUri: summarizeTrackUri(trackUri),
            didlTitle: metadataDiagnostic.didlTitle,
            didlArtist: metadataDiagnostic.didlArtist,
            streamContent: metadataDiagnostic.streamContent,
            streamTitle: metadataDiagnostic.streamFields.title ?? null,
            streamArtist: metadataDiagnostic.streamFields.artist ?? null,
            fallbackTitle: firstObjectString(coordinator.CurrentTrack?.Title, device.CurrentTrack?.Title),
            fallbackArtist: firstObjectString(coordinator.CurrentTrack?.Artist, device.CurrentTrack?.Artist),
            finalTitle: trackTitle,
            finalArtist: artist,
            heldPreviousLiveMetadata,
          },
          'live radio metadata resolved',
        );
      }

      const snapshot: SonosGroupSnapshot = {
        groupId: resolvedGroupId,
        speakerName: coordinator.Name ?? device.Name ?? device.Uuid,
        trackTitle,
        artist,
        album,
        trackUri,
        albumArtUri,
        albumArtFallbackUri,
        isPlaying,
        transportStateRaw,
        groupVolume,
        playbackSourceRaw,
        tvAudioFormatRawCode: tvAudioFormat?.rawCode,
        tvAudioFormatLabel: tvAudioFormat?.label,
        tvHasSignal: tvAudioFormat?.hasSignal,
        soundbarNightMode: soundbarEQ.soundbarNightMode,
        soundbarSpeechEnhancementRawLevel: soundbarEQ.soundbarSpeechEnhancementRawLevel,
        audioQualityLabel,
        musicAmbienceEligible: isMusicAmbienceEligibleForSnapshot({
          trackTitle,
          artist,
          album,
          albumArtUri,
          playbackSourceRaw,
        }),
        positionSeconds,
        durationSeconds,
        groupMemberCount: Math.max(1, groupMembers.length),
        groupMembers,
        sampledAt: new Date(),
      };

      return this.publishSnapshot(snapshot, trigger);
    } catch (err) {
      if (groupId && !this.isCurrentRefresh(groupId, refreshSequence)) return false;
      this.log.warn(
        { err, device: device.Name },
        'snapshot refresh failed — will retry on next event',
      );
      return false;
    }
  }

  private snapshotGroupId(device: any): string | null {
    const coordinator = device?.Coordinator ?? device;
    return firstNonEmpty(coordinator?.Host, device?.Host, device?.Uuid);
  }

  private async groupVolumeForSnapshot(
    coordinator: any,
    previousVolume?: number | null,
  ): Promise<number | null> {
    const service = coordinator?.GroupRenderingControlService;
    if (typeof service?.GetGroupVolume !== 'function') return previousVolume ?? null;

    try {
      const response = await service.GetGroupVolume({ InstanceID: 0 });
      const volume = Number(response?.CurrentVolume);
      return Number.isFinite(volume) ? Math.min(100, Math.max(0, Math.round(volume))) : previousVolume ?? null;
    } catch (err) {
      this.log.debug({ err, groupId: coordinator?.Host ?? null }, 'group volume snapshot failed');
      return previousVolume ?? null;
    }
  }

  private beginRefresh(groupId: string): number {
    const sequence = (this.refreshSequences.get(groupId) ?? 0) + 1;
    this.refreshSequences.set(groupId, sequence);
    return sequence;
  }

  private isCurrentRefresh(groupId: string, sequence: number): boolean {
    return this.refreshSequences.get(groupId) === sequence;
  }

  private publishSnapshot(
    snapshot: SonosGroupSnapshot,
    trigger: SonosSnapshotChangeTrigger,
  ): boolean {
    const previous = this.snapshots.get(snapshot.groupId);
    this.snapshots.set(snapshot.groupId, snapshot);
    if (previous && sonosSnapshotsMeaningfullyEqual(previous, snapshot)) return false;
    this.emit('change', snapshot, { trigger } satisfies SonosSnapshotChangeContext);
    return true;
  }

  private scheduleCommandConfirmationRefresh(
    device: any,
    groupId: string,
    suppressTransientNonPlaying = false,
  ): void {
    this.cancelCommandConfirmationRefresh(groupId);
    if (this.transitionSettleRefreshMs <= 0) return;
    const timer = setTimeout(() => {
      this.commandConfirmationRefreshTimers.delete(groupId);
      void this.refreshSnapshot(device, 'transition-settle-refresh', {
        includeGroupDetails: false,
        suppressTransientNonPlaying,
      }).catch(err => {
        this.log.debug({ err, groupId }, 'Sonos command confirmation refresh failed');
      });
    }, this.transitionSettleRefreshMs);
    timer.unref?.();
    this.commandConfirmationRefreshTimers.set(groupId, timer);
  }

  private cancelCommandConfirmationRefresh(groupId: string): void {
    const timer = this.commandConfirmationRefreshTimers.get(groupId);
    if (!timer) return;
    clearTimeout(timer);
    this.commandConfirmationRefreshTimers.delete(groupId);
  }

  private scheduleTransitionSettleRefresh(device: any, groupId: string): void {
    if (this.transitionSettleRefreshMs <= 0) return;
    if (this.transitionSettleRefreshTimers.has(groupId)) return;

    const timer = setTimeout(() => {
      this.transitionSettleRefreshTimers.delete(groupId);
      void this.refreshSnapshot(device, 'transition-settle-refresh', {
        includeGroupDetails: false,
      }).catch(err => {
        this.log.debug({ err, groupId }, 'transition settle refresh failed');
      });
    }, this.transitionSettleRefreshMs);
    timer.unref?.();
    this.transitionSettleRefreshTimers.set(groupId, timer);
  }

  private async localControlPlaybackQuality(
    coordinator: Record<string, unknown>,
    device: Record<string, unknown>,
  ): Promise<SonosLocalPlaybackQuality | null> {
    if (!this.localControl) return null;

    const host = firstObjectString(coordinator.Host, device.Host);
    const playerId = firstObjectString(coordinator.Uuid, device.Uuid);
    if (!host || !playerId) return null;

    try {
      const quality = await this.localControl.playbackQuality({ host, playerId });
      this.logLocalControlPlaybackQuality({ host, playerId, quality });
      return quality;
    } catch (err) {
      this.logLocalControlPlaybackQuality({ host, playerId, err });
      return null;
    }
  }

  private async localControlPlaybackMetadata(
    coordinator: Record<string, unknown>,
    device: Record<string, unknown>,
  ): Promise<SonosLocalPlaybackMetadata | null> {
    if (!this.localControl?.playbackMetadata) return null;

    const host = firstObjectString(coordinator.Host, device.Host);
    const playerId = firstObjectString(coordinator.Uuid, device.Uuid);
    if (!host || !playerId) return null;

    try {
      const metadata = await this.localControl.playbackMetadata({ host, playerId });
      this.logLocalControlPlaybackQuality({
        host,
        playerId,
        quality: metadata ? localPlaybackQualityFromPlaybackMetadata(metadata) : null,
      });
      return metadata;
    } catch (err) {
      this.logLocalControlPlaybackQuality({ host, playerId, err });
      return null;
    }
  }

  private logLocalControlPlaybackQuality(input: {
    host: string;
    playerId: string;
    quality?: SonosLocalPlaybackQuality | null;
    err?: unknown;
  }): void {
    const status = input.quality?.label ? 'resolved' : input.err ? 'error' : 'missing';
    const fields = {
      source: 'relay',
      action: 'local-control-quality',
      status,
      host: input.host,
      playerId: input.playerId,
      serviceName: input.quality?.serviceName ?? null,
      label: input.quality?.label ?? null,
      lossless: input.quality?.lossless ?? null,
      immersive: input.quality?.immersive ?? null,
      bitDepth: input.quality?.bitDepth ?? null,
      sampleRate: input.quality?.sampleRate ?? null,
      error: input.err ? errorSummary(input.err) : null,
    };
    const signature = JSON.stringify(fields);
    const key = `${input.host}|${input.playerId}`;
    if (this.localQualityLogSignatures.get(key) === signature) {
      this.log.debug(fields, 'Sonos local Control API playback quality unchanged');
      return;
    }

    this.localQualityLogSignatures.set(key, signature);
    this.log.info(
      fields,
      status === 'resolved'
        ? 'Sonos local Control API playback quality resolved'
        : 'Sonos local Control API playback quality unavailable',
    );
  }

  private async soundbarEQForSnapshot(
    coordinator: unknown,
    playbackSourceRaw: string | null,
  ): Promise<Pick<SonosGroupSnapshot, 'soundbarNightMode' | 'soundbarSpeechEnhancementRawLevel'>> {
    if (playbackSourceRaw !== 'tv') return {};

    const [nightValue, speechEnabledValue, dialogValue] = await Promise.all([
      this.getEQLevel(coordinator, 'NightMode'),
      this.getEQLevel(coordinator, 'SpeechEnhanceEnabled'),
      this.getEQLevel(coordinator, 'DialogLevel'),
    ]);
    const dialogLevel = clampSpeechEnhancementLevel(dialogValue ?? 0);
    const speechEnabled = speechEnabledValue === null
      ? dialogLevel > 0
      : speechEnabledValue > 0;

    return {
      soundbarNightMode: nightValue === null ? undefined : nightValue > 0,
      soundbarSpeechEnhancementRawLevel: speechEnabled && dialogLevel > 0 ? dialogLevel : 0,
    };
  }

  private async tvAudioFormatForSnapshot(coordinator: unknown): Promise<SonosTVAudioFormatSnapshot | null> {
    const service = devicePropertiesService(coordinator);
    if (!service || typeof service.GetZoneInfo !== 'function') return null;
    try {
      const response = await service.GetZoneInfo();
      const rawCode = Number(response?.HTAudioIn);
      if (!Number.isFinite(rawCode)) return null;
      const normalizedRawCode = Math.round(rawCode);
      const label = tvAudioFormatLabel(normalizedRawCode);
      return {
        rawCode: normalizedRawCode,
        label,
        geekLabel: tvAudioFormatGeekLabelFromLabel(label),
        hasSignal: tvAudioFormatHasSignal(label),
      };
    } catch {
      return null;
    }
  }

  private async getEQLevel(coordinator: unknown, eqType: string): Promise<number | null> {
    const service = renderingControlService(coordinator);
    if (!service || typeof service.GetEQ !== 'function') return null;
    try {
      const response = await service.GetEQ({ InstanceID: 0, EQType: eqType });
      const value = Number(response?.CurrentValue);
      return Number.isFinite(value) ? value : null;
    } catch {
      return null;
    }
  }

  private async setEQLevel(coordinator: unknown, eqType: string, value: number): Promise<void> {
    const service = renderingControlService(coordinator);
    if (!service || typeof service.SetEQ !== 'function') {
      throw new Error(`missing_rendering_control_service: ${eqType}`);
    }
    await service.SetEQ({ InstanceID: 0, EQType: eqType, DesiredValue: value });
  }

  private async setOptionalEQLevel(coordinator: unknown, eqType: string, value: number): Promise<void> {
    try {
      await this.setEQLevel(coordinator, eqType, value);
    } catch (err) {
      this.log.debug({ err, eqType }, 'optional soundbar EQ write failed');
    }
  }

  private async groupMembersForCoordinator(
    coordinator: any,
    groupId: string,
    knownGroup?: ParsedZoneGroup,
  ): Promise<SonosGroupMemberSnapshot[]> {
    const coordinatorHost = firstNonEmpty(coordinator.Host, groupId);
    const coordinatorUuid = firstNonEmpty(coordinator.Uuid);
    const manager = this.manager as unknown as {
      LoadAllGroups?: () => Promise<ParsedZoneGroup[]>;
    };

    try {
      const group = knownGroup ?? (
        typeof manager.LoadAllGroups === 'function'
          ? (await manager.LoadAllGroups.call(this.manager)).find(candidate =>
            zoneGroupMatchesCoordinator(candidate, coordinatorHost, coordinatorUuid))
          : undefined
      );
      if (group) {
        const members = await Promise.all((group.members ?? [])
          .filter(member => !isInvisibleDevice(member as unknown as Record<string, unknown>))
          .map(member => this.groupMemberSnapshot(member, coordinatorHost, coordinatorUuid)));
        const visible = members.filter((member): member is SonosGroupMemberSnapshot => member !== null);
        if (visible.length > 0) return visible;
      }
    } catch {
      // Fall through to sonos-ts' in-memory coordinator relationships.
    }

    // A SonosManager device object does not retain ZoneGroupState's
    // `Invisible` flag. If topology is temporarily unreachable, keep the last
    // topology-verified logical membership rather than reclassifying bonded
    // stereo partners, surrounds, or Subs as independently grouped rooms.
    const cachedMembers = this.snapshots.get(groupId)?.groupMembers;
    if (cachedMembers && cachedMembers.length > 0) return cachedMembers;

    return this.inferredGroupMembersForCoordinator(coordinator, groupId);
  }

  private async groupMemberSnapshot(
    member: NonNullable<ParsedZoneGroup['members']>[number],
    coordinatorHost: string,
    coordinatorUuid: string,
  ): Promise<SonosGroupMemberSnapshot | null> {
    const host = firstObjectString(member.host) ?? '';
    const uuid = firstObjectString(member.uuid) ?? '';
    if (!host && !uuid) return null;
    const device = this.findDevice(host, uuid);
    return {
      id: uuid || host,
      name: firstObjectString(member.name, device?.Name, host, uuid) || 'Unknown room',
      host: host || firstNonEmpty(device?.Host),
      isCoordinator: Boolean(
        (coordinatorHost && host === coordinatorHost)
        || (coordinatorUuid && uuid === coordinatorUuid)
      ),
      volume: await this.memberVolumeForSnapshot(device),
    };
  }

  private async inferredGroupMembersForCoordinator(
    coordinator: any,
    groupId: string,
  ): Promise<SonosGroupMemberSnapshot[]> {
    let devices: any[] = [];
    try {
      devices = this.manager.Devices as any[];
    } catch {
      devices = [coordinator];
    }

    const coordinatorHost = firstNonEmpty(coordinator.Host, groupId);
    const coordinatorUuid = firstNonEmpty(coordinator.Uuid);
    const matched: any[] = [];

    for (const device of devices) {
      if (!device || typeof device !== 'object' || isInvisibleDevice(device)) continue;
      const deviceCoordinator = (device as Record<string, unknown>).Coordinator ?? device;
      const candidateCoordinator = typeof deviceCoordinator === 'object' && deviceCoordinator
        ? deviceCoordinator as Record<string, unknown>
        : {};
      const deviceRecord = device as Record<string, unknown>;

      const candidateCoordinatorHost = firstNonEmpty(
        candidateCoordinator.Host as string,
        deviceRecord.CoordinatorHost as string,
      );
      const candidateCoordinatorUuid = firstNonEmpty(candidateCoordinator.Uuid as string);
      const deviceHost = firstNonEmpty(deviceRecord.Host as string);
      const deviceUuid = firstNonEmpty(deviceRecord.Uuid as string);

      if (coordinatorHost && (candidateCoordinatorHost === coordinatorHost || deviceHost === coordinatorHost)) {
        matched.push(device);
      } else if (
        coordinatorUuid
        && (candidateCoordinatorUuid === coordinatorUuid || deviceUuid === coordinatorUuid)
      ) {
        matched.push(device);
      }
    }

    if (matched.length === 0) matched.push(coordinator);
    return Promise.all(matched.map(async device => {
      const host = firstNonEmpty(device.Host);
      const uuid = firstNonEmpty(device.Uuid, host);
      return {
        id: uuid,
        name: firstNonEmpty(device.Name, host, uuid) || 'Unknown room',
        host,
        isCoordinator: Boolean(
          (coordinatorHost && host === coordinatorHost)
          || (coordinatorUuid && uuid === coordinatorUuid)
        ),
        volume: await this.memberVolumeForSnapshot(device),
      };
    }));
  }

  private findDevice(host: string, uuid: string): any | undefined {
    try {
      return this.manager.Devices.find(device => (
        (host && device.Host === host) || (uuid && device.Uuid === uuid)
      ));
    } catch {
      return undefined;
    }
  }

  private async memberVolumeForSnapshot(device: unknown): Promise<number | null> {
    const service = renderingControlService(device);
    if (!service || typeof service.GetVolume !== 'function') return null;
    try {
      const response = await service.GetVolume({ InstanceID: 0, Channel: 'Master' });
      const volume = Number(response?.CurrentVolume);
      return Number.isFinite(volume) ? Math.min(100, Math.max(0, Math.round(volume))) : null;
    } catch {
      return null;
    }
  }
}

/// Parse `HH:MM:SS` (Sonos's RelTime / TrackDuration format) → seconds.
function parseDuration(s: string): number {
  const parts = s.split(':').map(Number);
  if (parts.length !== 3 || parts.some(Number.isNaN)) return 0;
  return parts[0]! * 3600 + parts[1]! * 60 + parts[2]!;
}

function clampSpeechEnhancementLevel(level: number): number {
  if (!Number.isFinite(level)) return 0;
  return Math.max(0, Math.min(4, Math.round(level)));
}

function renderingControlService(coordinator: unknown): {
  GetEQ?: (input: { InstanceID: number; EQType: string }) => Promise<{ CurrentValue?: number | string }>;
  SetEQ?: (input: { InstanceID: number; EQType: string; DesiredValue: number }) => Promise<unknown>;
  GetVolume?: (input: { InstanceID: number; Channel: string }) => Promise<{ CurrentVolume?: number | string }>;
  SetVolume?: (input: { InstanceID: number; Channel: string; DesiredVolume: number }) => Promise<unknown>;
} | null {
  if (!coordinator || typeof coordinator !== 'object') return null;
  const service = (coordinator as { RenderingControlService?: unknown }).RenderingControlService;
  if (!service || typeof service !== 'object') return null;
  const candidate = service as {
    GetEQ?: (input: { InstanceID: number; EQType: string }) => Promise<{ CurrentValue?: number | string }>;
    SetEQ?: (input: { InstanceID: number; EQType: string; DesiredValue: number }) => Promise<unknown>;
    GetVolume?: (input: { InstanceID: number; Channel: string }) => Promise<{ CurrentVolume?: number | string }>;
    SetVolume?: (input: { InstanceID: number; Channel: string; DesiredVolume: number }) => Promise<unknown>;
  };
  return candidate;
}

function devicePropertiesService(coordinator: unknown): {
  GetZoneInfo?: () => Promise<SonosZoneInfo>;
} | null {
  if (!coordinator || typeof coordinator !== 'object') return null;
  const service = (coordinator as { DevicePropertiesService?: unknown }).DevicePropertiesService;
  if (!service || typeof service !== 'object') return null;
  return service as { GetZoneInfo?: () => Promise<SonosZoneInfo> };
}

function tvAudioFormatGeekLabelFromLabel(label: string): string {
  const codec = tvAudioFormatCodec(label);
  const channelLayout = tvAudioFormatIsAtmos(label)
    ? null
    : ['7.1', '5.1', '2.0'].find(layout => label.includes(layout)) ?? null;
  return [codec, channelLayout].filter(Boolean).join(' · ');
}

function tvAudioFormatHasSignal(label: string): boolean {
  const normalized = label.toLowerCase();
  return !normalized.includes('no input') && !normalized.includes('no audio');
}

function tvAudioFormatLabel(code: number): string {
  return tvAudioFormatLabels[code] ?? `Unknown (code: ${code})`;
}

function tvAudioFormatIsAtmos(label: string): boolean {
  return label.toLowerCase().includes('atmos');
}

function tvAudioFormatCodec(label: string): string {
  if (label.includes('Atmos (TrueHD)')) return 'Dolby Atmos · TrueHD';
  if (label.includes('Atmos (DD+)')) return 'Dolby Atmos · DD+';
  if (label.includes('Atmos (MAT 2.0)')) return 'Dolby Atmos · MAT';
  if (label.includes('Dolby TrueHD')) return 'Dolby TrueHD';
  if (label.includes('Dolby Digital Plus')) return 'Dolby Digital+';
  if (label.includes('Dolby Multichannel PCM')) return 'Multichannel PCM';
  if (label.includes('Multichannel PCM')) return 'Multichannel PCM';
  if (label.includes('Dolby')) return 'Dolby Digital';
  if (label.includes('DTS')) return 'DTS';
  if (label.startsWith('PCM')) return 'PCM';
  if (label === 'Stereo') return 'Stereo PCM';
  return label;
}

const tvAudioFormatLabels: Record<number, string> = {
  0: 'No input connected',
  2: 'Stereo',
  7: 'Dolby 2.0',
  18: 'Dolby 5.1',
  21: 'No input',
  22: 'No audio',
  59: 'Dolby Atmos (DD+)',
  61: 'Dolby Atmos (TrueHD)',
  63: 'Dolby Atmos (MAT 2.0)',
  33554434: 'PCM 2.0',
  33554454: 'PCM 2.0 no audio',
  33554488: 'Dolby 2.0',
  33554490: 'Dolby Digital Plus 2.0',
  33554492: 'Dolby TrueHD 2.0',
  33554494: 'Dolby Multichannel PCM 2.0',
  84934658: 'Multichannel PCM 5.1',
  84934713: 'Dolby 5.1',
  84934714: 'Dolby Digital Plus 5.1',
  84934716: 'Dolby TrueHD 5.1',
  84934718: 'Dolby Multichannel PCM 5.1',
  84934721: 'DTS 5.1',
  118489090: 'Multichannel PCM 7.1',
  118489146: 'Dolby Digital Plus 7.1',
};

export function albumArtUriFromMetadata(metadata: unknown): string | null {
  return trackMetadataFromMetadata(metadata).albumArtUri;
}

export function playbackSourceFromTrackUri(trackUri: unknown): string | null {
  if (typeof trackUri !== 'string') return null;
  const uri = trackUri.trim().toLowerCase();
  if (uri.length === 0) return null;

  if (uri.startsWith('x-sonos-spotify:') || uri.includes('sid=9&') || uri.endsWith('sid=9')) return 'spotify';
  if (uri.startsWith('x-sonosprog-http:') || uri.includes('sid=204')) return 'appleMusic';
  if (uri.includes('sid=203')) return 'amazonMusic';
  if (uri.includes('sid=174')) return 'tidal';
  if (uri.includes('sid=284')) return 'youtubeMusic';
  if (uri.startsWith('x-sonos-htastream:')) return 'tv';
  if (uri.startsWith('x-sonos-vli:') || uri.startsWith('x-rincon-stream:')) return 'airplay';
  if (
    uri.startsWith('x-sonosapi-stream:')
    || uri.startsWith('x-sonosapi-radio:')
    || uri.startsWith('x-rincon-mp3radio:')
    || uri.startsWith('aac:')
  ) {
    return 'radio';
  }
  if (uri.startsWith('x-file-cifs:') || uri.startsWith('x-rincon-playlist:')) return 'library';
  return null;
}

export function sonosSnapshotsMeaningfullyEqual(
  left: SonosGroupSnapshot,
  right: SonosGroupSnapshot,
): boolean {
  const { sampledAt: _leftSampledAt, ...leftContent } = left;
  const { sampledAt: _rightSampledAt, ...rightContent } = right;
  return JSON.stringify(leftContent) === JSON.stringify(rightContent);
}

function publicQueueArtworkURL(value: unknown): string | null {
  if (typeof value !== 'string' || !value.trim()) return null;
  try {
    const url = new URL(value.trim());
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : null;
  } catch {
    return null;
  }
}

function queueArtworkSource(
  source: SonosArtworkResolutionSource | null | undefined,
): SonosQueueItem['artworkSource'] {
  return source === 'itunes-lookup' || source === 'itunes-search' ? source : 'none';
}

async function mapWithConcurrency<T>(
  values: T[],
  concurrency: number,
  operation: (value: T) => Promise<void>,
): Promise<void> {
  let index = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, async () => {
    while (index < values.length) {
      const value = values[index++];
      await operation(value);
    }
  }));
}

export function playbackSourceFromServiceName(serviceName: unknown): string | null {
  if (typeof serviceName !== 'string') return null;
  const name = serviceName.trim().toLowerCase();
  if (!name) return null;
  if (name.includes('spotify')) return 'spotify';
  if (name.includes('apple')) return 'appleMusic';
  if (name.includes('amazon')) return 'amazonMusic';
  if (name.includes('tidal')) return 'tidal';
  if (name.includes('youtube')) return 'youtubeMusic';
  if (name.includes('netease') || name.includes('网易')) return 'neteaseMusic';
  if (name.includes('tunein') || name.includes('radio')) return 'radio';
  return null;
}

function localPlaybackServiceName(metadata: SonosLocalPlaybackMetadata | null): string | null {
  if (!metadata) return null;
  const track = metadata.currentItem?.track ?? metadata.track;
  return firstObjectString(
    track?.service?.name,
    metadata.service?.name,
    metadata.container?.service?.name,
  ) || null;
}

function isLiveRadioSnapshot(input: {
  trackUri: string;
  durationSeconds: number;
  playbackSourceRaw: string | null;
}): boolean {
  const uri = input.trackUri.toLowerCase();
  const liveUri = uri.startsWith('x-sonosapi-hls:')
    || uri.startsWith('x-sonosapi-stream:')
    || uri.startsWith('x-sonosapi-radio:')
    || uri.startsWith('x-rincon-mp3radio:')
    || uri.startsWith('aac:');
  return liveUri || (input.durationSeconds <= 0 && input.playbackSourceRaw === 'radio');
}

export function isMusicAmbienceEligibleForSnapshot(snapshot: {
  trackTitle?: string | null;
  artist?: string | null;
  album?: string | null;
  albumArtUri?: string | null;
  playbackSourceRaw?: string | null;
}): boolean {
  if (snapshot.playbackSourceRaw === 'tv' || snapshot.playbackSourceRaw === 'lineIn') {
    return false;
  }

  if (snapshot.albumArtUri && snapshot.albumArtUri.trim().length > 0) return true;

  const title = normalizedMetadata(snapshot.trackTitle);
  const artist = normalizedMetadata(snapshot.artist);
  const album = normalizedMetadata(snapshot.album);
  if (!title) return false;

  if (snapshot.playbackSourceRaw && snapshot.playbackSourceRaw !== 'unknown') return true;
  return Boolean(artist || album);
}

export interface SonosTrackMetadata {
  title: string | null;
  artist: string | null;
  album: string | null;
  albumArtUri: string | null;
}

interface SonosTrackMetadataDiagnostic {
  didlTitle: string | null;
  didlArtist: string | null;
  didlAlbum: string | null;
  streamContent: string | null;
  streamFields: Partial<Pick<SonosTrackMetadata, 'title' | 'artist' | 'album'>>;
}

interface ParsedZoneGroup {
  coordinator?: {
    host?: string;
    uuid?: string;
    name?: string;
    Invisible?: boolean;
  };
  members?: Array<{
    host?: string;
    uuid?: string;
    name?: string;
    Invisible?: boolean;
  }>;
}

function topologyMutationDelay(milliseconds: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

function playbackSettleDelay(milliseconds: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

function queueArtworkLookupDelay(milliseconds: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

// @svrooij/sonos encodes URI string fields but inserts metadata string fields
// verbatim into its SOAP envelope. Escape the nested DIDL document exactly once
// so Sonos receives it as the text value of *MetaData instead of malformed XML.
export function encodeSonosSoapMetadata(metadata: string): string {
  return metadata
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export function trackMetadataFromMetadata(metadata: unknown): SonosTrackMetadata {
  if (!metadata) {
    return emptyTrackMetadata();
  }
  if (typeof metadata !== 'string') {
    return trackMetadataFromTrackObject(metadata);
  }

  const baseMetadata = {
    title: xmlTagValue(metadata, 'dc:title'),
    artist: xmlTagValue(metadata, 'dc:creator') ?? xmlTagValue(metadata, 'upnp:artist'),
    album: xmlTagValue(metadata, 'upnp:album'),
    albumArtUri: xmlTagValue(metadata, 'upnp:albumArtURI'),
  };
  return reconcileRadioStreamContent(
    baseMetadata,
    xmlTagValue(metadata, 'r:streamContent') ?? radioStreamContentFromCachedArtist(baseMetadata.artist),
  );
}

function trackMetadataDiagnostic(metadata: unknown): SonosTrackMetadataDiagnostic {
  if (!metadata || typeof metadata !== 'object') {
    const raw = typeof metadata === 'string' ? metadata : '';
    const didlArtist = xmlTagValue(raw, 'dc:creator') ?? xmlTagValue(raw, 'upnp:artist');
    const streamContent = xmlTagValue(raw, 'r:streamContent') ?? radioStreamContentFromCachedArtist(didlArtist);
    return {
      didlTitle: xmlTagValue(raw, 'dc:title'),
      didlArtist,
      didlAlbum: xmlTagValue(raw, 'upnp:album'),
      streamContent,
      streamFields: streamContent ? radioStreamContentFields(streamContent) : {},
    };
  }

  const track = metadata as Record<string, unknown>;
  const didlArtist = firstObjectString(track.Artist, track.artist, track.Creator, track.creator) || null;
  const streamContent = firstObjectString(
    track.StreamContent,
    track.streamContent,
    track.StreamInfo,
    track.streamInfo,
  ) || radioStreamContentFromCachedArtist(didlArtist);
  return {
    didlTitle: firstObjectString(track.Title, track.title) || null,
    didlArtist,
    didlAlbum: firstObjectString(track.Album, track.album) || null,
    streamContent: streamContent || null,
    streamFields: streamContent ? radioStreamContentFields(streamContent) : {},
  };
}

function audioQualityLabelFromMetadata(
  metadata: unknown,
  sourceRaw: string | null,
): string | null {
  if (typeof metadata !== 'string') {
    return null;
  }

  const resAttributes = xmlElementAttributes(metadata, 'res');
  if (!resAttributes) {
    return null;
  }

  const protocolInfo = xmlAttributeValue(resAttributes, 'protocolInfo');
  if (!protocolInfo) {
    return null;
  }

  return audioQualityLabelFromProtocolInfo({
    protocolInfo,
    sampleRate: xmlAttributeValue(resAttributes, 'sampleFrequency'),
    bitDepth: xmlAttributeValue(resAttributes, 'bitsPerSample'),
    channels: xmlAttributeValue(resAttributes, 'nrAudioChannels'),
    streamContent: xmlTagValue(metadata, 'r:streamContent') ?? '',
    sourceRaw,
  });
}

function audioQualityLabelFromProtocolInfo(input: {
  protocolInfo: string;
  sampleRate: string | null;
  bitDepth: string | null;
  channels: string | null;
  streamContent: string;
  sourceRaw: string | null;
}): string | null {
  const parts = input.protocolInfo.split(':');
  if (parts.length < 3) return null;

  const mime = (parts[2] ?? '').toLowerCase();
  const streamContent = input.streamContent.toLowerCase().trim();
  let sampleRate = input.sampleRate;
  let bitDepth = input.bitDepth;

  const streamMatch = input.streamContent.match(/(\d+)\/(\d+\.?\d*)/);
  if (streamMatch) {
    bitDepth ??= streamMatch[1] ?? null;
    if (!sampleRate && streamMatch[2]) {
      const parsed = Number(streamMatch[2]);
      sampleRate = Number.isFinite(parsed) && parsed < 1000
        ? String(Math.round(parsed * 1000))
        : streamMatch[2];
    }
  }

  const codec = audioCodecFromMetadata({
    mime,
    streamContent,
    sampleRate,
    bitDepth,
    sourceRaw: input.sourceRaw,
  });
  if (!codec) return null;

  const sampleRateNumber = parsePositiveInteger(sampleRate);
  const bitDepthNumber = parsePositiveInteger(bitDepth);
  const channelsNumber = parsePositiveInteger(input.channels);
  const normalizedCodec = codec.toLowerCase();
  const isAtmos = normalizedCodec.includes('atmos') || (channelsNumber ?? 0) > 2;
  if (isAtmos) return 'Dolby Atmos';

  const isLossless = isLosslessCodec(normalizedCodec, sampleRateNumber, bitDepthNumber);
  if (isLossless) {
    const isHiRes = (sampleRateNumber ?? 0) > 48_000
      || ((sampleRateNumber ?? 0) >= 48_000 && (bitDepthNumber ?? 0) >= 24);
    return isHiRes ? 'Hi-Res Lossless' : 'Lossless';
  }

  return codec.toUpperCase();
}

export function localPlaybackQualityFromPlaybackMetadata(
  metadata: SonosLocalPlaybackMetadata,
): SonosLocalPlaybackQuality | null {
  const track = metadata.currentItem?.track ?? metadata.track;
  const quality = track?.quality;
  if (!quality) return null;

  const bitDepth = positiveNumber(quality.bitDepth);
  const sampleRate = positiveNumber(quality.sampleRate);
  const label = localPlaybackQualityLabel({
    bitDepth,
    sampleRate,
    lossless: quality.lossless ?? null,
    immersive: quality.immersive ?? null,
  });
  if (!label) return null;

  return {
    label,
    serviceName: firstObjectString(
      track?.service?.name,
      metadata.service?.name,
      metadata.container?.service?.name,
    ),
    lossless: quality.lossless ?? null,
    immersive: quality.immersive ?? null,
    bitDepth,
    sampleRate,
  };
}

function trackMetadataFromLocalPlaybackMetadata(
  metadata: SonosLocalPlaybackMetadata,
): SonosTrackMetadata {
  const track = metadata.currentItem?.track ?? metadata.track;
  if (!track) return emptyTrackMetadata();

  return {
    title: firstObjectString(track.name),
    artist: firstObjectString(track.artist?.name),
    album: firstObjectString(track.album?.name),
    albumArtUri: firstObjectString(
      track.imageUrl,
      track.album?.imageUrl,
      metadata.container?.imageUrl,
    ),
  };
}

function localPlaybackQualityLabel(input: {
  bitDepth: number | null;
  sampleRate: number | null;
  lossless: boolean | null;
  immersive: boolean | null;
}): string | null {
  if (input.immersive === true) {
    return 'Dolby Atmos';
  }

  if (input.lossless === true) {
    const hiRes = (input.sampleRate ?? 0) > 48_000
      || ((input.sampleRate ?? 0) >= 48_000 && (input.bitDepth ?? 0) >= 24);
    return hiRes ? 'Hi-Res Lossless' : 'Lossless';
  }

  if (input.lossless === false && input.bitDepth && input.sampleRate) {
    return `${input.bitDepth}-bit/${formatSampleRate(input.sampleRate)}`;
  }

  return null;
}

function formatSampleRate(sampleRate: number): string {
  const khz = sampleRate / 1000;
  return `${Number.isInteger(khz) ? khz.toFixed(0) : khz.toFixed(1).replace(/\.0$/, '')} kHz`;
}

function audioCodecFromMetadata(input: {
  mime: string;
  streamContent: string;
  sampleRate: string | null;
  bitDepth: string | null;
  sourceRaw: string | null;
}): string | null {
  const { mime, streamContent, sampleRate, bitDepth, sourceRaw } = input;
  if (streamContent.includes('flac')) return 'FLAC';
  if (streamContent.includes('alac')) return 'ALAC';
  if (streamContent.includes('pcm')) return 'PCM';
  if (streamContent.includes('aiff')) return 'AIFF';
  if (streamContent.includes('wav')) return 'WAV';
  if (
    streamContent.includes('dolby')
    || streamContent.includes('atmos')
    || streamContent.includes('ac3')
    || streamContent.includes('ec3')
  ) {
    return 'Atmos';
  }
  if (streamContent.includes('ogg')) return 'OGG';
  if (mime.includes('flac')) return 'FLAC';
  if (mime.includes('wav') || mime.includes('wave')) return 'WAV';
  if (mime.includes('aiff')) return 'AIFF';
  if (mime.includes('mp4') || mime.includes('m4a')) {
    return bitDepth || sampleRate ? 'ALAC' : null;
  }
  if (mime.includes('mp3') || mime.includes('mpeg')) {
    if (sourceRaw === 'library' || sourceRaw === 'radio' || bitDepth || sampleRate) {
      return 'MP3';
    }
    return null;
  }
  if (mime.includes('ogg')) return 'OGG';
  if (mime.includes('wma')) return 'WMA';
  return mime.replace(/^audio\//, '').toUpperCase();
}

function isLosslessCodec(
  normalizedCodec: string,
  sampleRate: number | null,
  bitDepth: number | null,
): boolean {
  if (
    normalizedCodec.includes('hi-res')
    || normalizedCodec.includes('hires')
    || normalizedCodec.includes('hi res')
  ) {
    return true;
  }
  if (
    normalizedCodec === 'lossless'
    || normalizedCodec.includes('lossless')
    || normalizedCodec.includes('flac')
    || normalizedCodec.includes('alac')
    || normalizedCodec.includes('wav')
    || normalizedCodec.includes('aiff')
    || normalizedCodec.includes('pcm')
  ) {
    return true;
  }
  return (normalizedCodec === 'aac' || normalizedCodec.includes('mp4') || normalizedCodec.includes('m4a'))
    && (bitDepth !== null || sampleRate !== null);
}

function trackMetadataFromTrackObject(metadata: unknown): SonosTrackMetadata {
  if (!metadata || typeof metadata !== 'object') return emptyTrackMetadata();
  const track = metadata as Record<string, unknown>;

  const baseMetadata = {
    title: firstObjectString(track.Title, track.title),
    artist: firstObjectString(track.Artist, track.artist, track.Creator, track.creator),
    album: firstObjectString(track.Album, track.album),
    albumArtUri: firstObjectString(track.AlbumArtUri, track.AlbumArtURI, track.albumArtUri),
  };
  return reconcileRadioStreamContent(
    baseMetadata,
    firstObjectString(track.StreamContent, track.streamContent, track.StreamInfo, track.streamInfo)
      || radioStreamContentFromCachedArtist(baseMetadata.artist),
  );
}

function emptyTrackMetadata(): SonosTrackMetadata {
  return {
    title: null,
    artist: null,
    album: null,
    albumArtUri: null,
  };
}

function normalizedMetadata(value: string | null | undefined): string {
  const normalized = (value ?? '').trim().toLowerCase();
  return normalized === 'unknown' ? '' : normalized;
}

function reconcileRadioStreamContent(
  metadata: SonosTrackMetadata,
  streamContent: string | null,
): SonosTrackMetadata {
  const decoded = decodeXmlEntities(streamContent ?? '').trim();
  if (!decoded) return metadata;

  const fields = radioStreamContentFields(decoded);
  if (fields.title || fields.artist || fields.album) {
    return {
      ...metadata,
      title: fields.title ?? metadata.title,
      artist: fields.artist ?? metadata.artist,
      album: fields.album ?? metadata.album,
    };
  }

  const separator = decoded.indexOf(' - ');
  if (separator > 0) {
    const artist = decoded.slice(0, separator).trim();
    const title = decoded.slice(separator + 3).trim();
    return {
      ...metadata,
      title: title || metadata.title,
      artist: artist || metadata.artist,
    };
  }

  if (!normalizedMetadata(metadata.artist)) {
    return {
      ...metadata,
      title: decoded,
    };
  }

  return metadata;
}

function radioStreamContentFromCachedArtist(artist: string | null | undefined): string | null {
  return artist && looksLikeRadioStreamContent(artist) ? artist : null;
}

function radioStreamContentFields(streamContent: string): Partial<Pick<SonosTrackMetadata, 'title' | 'artist' | 'album'>> {
  const fields: Partial<Pick<SonosTrackMetadata, 'title' | 'artist' | 'album'>> = {};
  for (const segment of streamContent.split('|')) {
    const trimmed = segment.trim();
    const upper = trimmed.toUpperCase();
    for (const [key, property] of [
      ['TITLE', 'title'],
      ['ARTIST', 'artist'],
      ['ALBUM', 'album'],
    ] as const) {
      const spacePrefix = `${key} `;
      const equalsPrefix = `${key}=`;
      let value: string | null = null;
      if (upper.startsWith(spacePrefix)) {
        value = trimmed.slice(spacePrefix.length).trim();
      } else if (upper.startsWith(equalsPrefix)) {
        value = trimmed.slice(equalsPrefix.length).trim();
      }
      if (value) fields[property] = value;
    }
  }
  return fields;
}

function firstMeaningfulMetadata(
  field: 'title' | 'artist' | 'album',
  ...values: Array<string | null | undefined>
): string {
  for (const value of values) {
    const stringValue = firstObjectString(value);
    if (!stringValue || !normalizedMetadata(stringValue)) continue;
    const streamFields = looksLikeRadioStreamContent(stringValue)
      ? radioStreamContentFields(stringValue)
      : {};
    const streamFieldValue = streamFields[field];
    if (streamFieldValue) return streamFieldValue;
    if (looksLikeRadioStreamContent(stringValue)) continue;
    return stringValue;
  }
  const fallback = firstNonEmpty(...values);
  return looksLikeRadioStreamContent(fallback) ? '' : fallback;
}

function shouldHoldPreviousLiveMetadata(input: {
  liveStream: boolean;
  metadata: SonosTrackMetadata;
  metadataDiagnostic: SonosTrackMetadataDiagnostic;
  trackTitle: string;
  artist: string;
  previousSnapshot: SonosGroupSnapshot | undefined;
}): boolean {
  if (!input.liveStream || !input.previousSnapshot?.isPlaying) return false;
  if (input.previousSnapshot.durationSeconds > 0) return false;
  if (!normalizedMetadata(input.previousSnapshot.trackTitle)) return false;
  if (input.metadataDiagnostic.streamFields.title || input.metadataDiagnostic.streamFields.artist) {
    return isGenericLiveFallback(input.metadataDiagnostic.streamFields.title)
      || isGenericLiveFallback(input.trackTitle);
  }
  if (normalizedMetadata(input.metadata.title) || normalizedMetadata(input.metadata.artist)) return false;

  return !normalizedMetadata(input.trackTitle)
    || isGenericLiveFallback(input.trackTitle)
    || isGenericLiveFallback(input.artist);
}

function shouldSuppressTransientNonPlayingSnapshot(input: {
  options: RefreshSnapshotOptions;
  trigger: SonosSnapshotChangeTrigger;
  previousSnapshot: SonosGroupSnapshot | undefined;
  trackTitle: string;
  isPlaying: boolean;
  positionSeconds: number;
  durationSeconds: number;
}): boolean {
  if (input.previousSnapshot?.isPlaying !== true) return false;
  if (input.isPlaying) return false;
  if (input.positionSeconds > 1) return false;
  if (input.options.suppressTransientNonPlaying === true) return true;
  if (!isTransitionSuppressibleTrigger(input.trigger)) return false;
  if (input.durationSeconds <= 0) return false;

  const previousTitle = normalizedMetadata(input.previousSnapshot.trackTitle);
  const transientTitle = normalizedMetadata(input.trackTitle);
  return Boolean(previousTitle && transientTitle && previousTitle !== transientTitle);
}

function isTransitionSuppressibleTrigger(trigger: SonosSnapshotChangeTrigger): boolean {
  return trigger === 'sonos-change' || trigger === 'transition-settle-refresh';
}

function errorSummary(err: unknown): string {
  if (err instanceof Error) return `${err.name}: ${err.message}`;
  return String(err);
}

function isGenericLiveFallback(value: string | null | undefined): boolean {
  const normalized = normalizedMetadata(value);
  if (!normalized) return true;
  return [
    'single',
    'song',
    'track',
    'music',
    'apple music',
    'apple music 1',
    'apple music chill',
    'apple music classical',
    'apple music club',
    'apple music country',
    'apple music hits',
    'apple music radio',
    'radio',
    'station',
  ].includes(normalized);
}

function summarizeTrackUri(trackUri: string): string {
  if (trackUri.length <= 96) return trackUri;
  return `${trackUri.slice(0, 80)}…${trackUri.slice(-12)}`;
}

function summarizeAlbumArtUri(albumArtUri: string | null | undefined): string | null {
  if (!albumArtUri) return null;
  if (albumArtUri.length <= 120) return albumArtUri;
  return `${albumArtUri.slice(0, 96)}…${albumArtUri.slice(-16)}`;
}

function isInvisibleDevice(device: Record<string, unknown> | null | undefined): boolean {
  if (!device) return false;
  const value = device.Invisible ?? device.invisible ?? device.isInvisible;
  return value === true || value === 1 || value === '1';
}

export function shouldAttachSonosDeviceEvents(
  device: { Coordinator?: unknown } | null | undefined,
): boolean {
  if (!device) return false;
  return device.Coordinator == null || device.Coordinator === device;
}

function zoneGroupMatchesCoordinator(
  group: ParsedZoneGroup,
  coordinatorHost: string,
  coordinatorUuid: string,
): boolean {
  const groupCoordinator = group.coordinator ?? {};
  const groupCoordinatorHost = firstObjectString(groupCoordinator.host);
  const groupCoordinatorUuid = firstObjectString(groupCoordinator.uuid);

  return Boolean(
    (coordinatorHost && groupCoordinatorHost === coordinatorHost)
      || (coordinatorUuid && groupCoordinatorUuid === coordinatorUuid),
  );
}

function looksLikeRadioStreamContent(value: string): boolean {
  const upper = value.toUpperCase();
  return upper.startsWith('TYPE=') || upper.includes('|TITLE ') || upper.includes('|TITLE=');
}

function xmlElementAttributes(xml: string, tag: string): string | null {
  const escapedTag = tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = xml.match(new RegExp(`<${escapedTag}\\s+([^>]*)>`, 'i'));
  return match?.[1] ? decodeXmlEntities(match[1]).trim() : null;
}

function xmlTagValue(xml: string, tag: string): string | null {
  const escapedTag = tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = xml.match(new RegExp(`<${escapedTag}[^>]*>([^<]+)<\\/${escapedTag}>`, 'i'));
  const value = match?.[1] ? decodeXmlEntities(match[1]).trim() : '';
  return value.length > 0 ? value : null;
}

function xmlAttributeValue(attributes: string, name: string): string | null {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = attributes.match(new RegExp(`${escapedName}\\s*=\\s*(['"])(.*?)\\1`, 'i'));
  const value = match?.[2] ? decodeXmlEntities(match[2]).trim() : '';
  return value.length > 0 ? value : null;
}

function parsePositiveInteger(value: string | null): number | null {
  if (!value) return null;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function positiveNumber(value: number | null | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : null;
}

function encodeSonosLocalPathSegment(value: string): string {
  return encodeURIComponent(value).replaceAll('%3A', ':');
}

function hostnameForHttpsRequest(host: string): string {
  const withoutBrackets = host.startsWith('[') && host.endsWith(']')
    ? host.slice(1, -1)
    : host;
  return withoutBrackets.split('%', 1)[0] ?? withoutBrackets;
}

function isLocalSonosControlHost(host: string): boolean {
  const normalized = hostnameForHttpsRequest(host).toLowerCase();
  if (normalized === 'localhost' || normalized.endsWith('.local')) return true;
  if (normalized.startsWith('192.168.') || normalized.startsWith('10.') || normalized.startsWith('169.254.')) {
    return true;
  }
  if (normalized.startsWith('172.')) {
    const second = Number.parseInt(normalized.split('.')[1] ?? '', 10);
    return Number.isInteger(second) && second >= 16 && second <= 31;
  }
  return normalized === '::1'
    || normalized.startsWith('fe80:')
    || normalized.startsWith('fc')
    || normalized.startsWith('fd');
}

function firstNonEmpty(...values: Array<string | null | undefined>): string {
  return firstObjectString(...values) ?? '';
}

function firstObjectString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value !== 'string') continue;
    const trimmed = value.trim();
    if (trimmed.length > 0) return trimmed;
  }
  return null;
}

function absoluteAlbumArtUri(uri: string | null | undefined, host: string | undefined): string | null {
  if (!uri) return null;
  if (/^https?:\/\//i.test(uri)) return uri;
  if (!host) return uri;
  const path = uri.startsWith('/') ? uri : `/${uri}`;
  return `http://${host}:1400${path}`;
}

function sonosGetAAAlbumArtUri(uri: string | null | undefined): string | null {
  const trimmed = uri?.trim() ?? '';
  if (!trimmed) return null;
  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
    return parsed.pathname.toLowerCase().includes('/getaa') ? trimmed : null;
  } catch {
    return trimmed.startsWith('/getaa') ? trimmed : null;
  }
}

function usableAlbumArtUri(uri: string | null | undefined): string | null {
  const trimmed = uri?.trim() ?? '';
  if (!trimmed) return null;
  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
    return trimmed;
  } catch {
    return sonosGetAAAlbumArtUri(trimmed);
  }
}

function albumArtUriFromTrackUri(trackUri: string | null | undefined, host: string | undefined): string | null {
  const uri = trackUri?.trim() ?? '';
  const resolvedHost = host?.trim() ?? '';
  if (!uri || !resolvedHost) return null;

  const lower = uri.toLowerCase();
  if (
    lower.startsWith('x-sonos-htastream:')
    || lower.startsWith('x-rincon-queue:')
    || lower.startsWith('x-rincon-stream:')
    || lower.startsWith('x-sonos-vli:')
  ) {
    return null;
  }

  const supportsGetAA = lower.startsWith('x-sonos-http:')
    || lower.startsWith('x-sonosprog-http:')
    || lower.startsWith('x-sonosapi-hls:')
    || lower.startsWith('x-sonosapi-stream:')
    || lower.startsWith('x-sonosapi-radio:')
    || lower.startsWith('x-rincon-mp3radio:')
    || lower.startsWith('aac:');
  if (!supportsGetAA) return null;

  return `http://${resolvedHost}:1400/getaa?s=1&u=${encodeURIComponent(uri)}`;
}

function decodeXmlEntities(value: string): string {
  return value
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'");
}
