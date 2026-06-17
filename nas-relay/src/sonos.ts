import { SonosEvents, SonosManager, type SonosDevice } from '@svrooij/sonos';
import { EventEmitter } from 'node:events';
import https from 'node:https';
import type { Logger } from 'pino';
import type { SonosGroupSnapshot } from './types.js';

export type SonosSnapshotChangeTrigger =
  | 'sonos-change'
  | 'periodic-refresh'
  | 'initial-prime'
  | 'transition-settle-refresh';

export interface SonosSnapshotChangeContext {
  trigger: SonosSnapshotChangeTrigger;
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
  playbackQuality(input: { host: string; playerId: string }): Promise<SonosLocalPlaybackQuality | null>;
}

export interface SonosBridgeOptions {
  localControl?: SonosLocalControlClient | null;
  transitionSettleRefreshMs?: number;
}

interface RefreshSnapshotOptions {
  suppressTransientNonPlaying?: boolean;
}

interface SonosLocalPlayerInfo {
  groupId?: string | null;
}

interface SonosLocalPlaybackMetadata {
  service?: {
    name?: string | null;
    id?: string | null;
  } | null;
  container?: {
    service?: {
      name?: string | null;
      id?: string | null;
    } | null;
  } | null;
  track?: {
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

const SONOS_LOCAL_CONTROL_PORT = 1443;
const SONOS_LOCAL_CONTROL_API_KEY = '12345678-abcd-1234-5678-123456789000';

class SonosLocalControlApiClient implements SonosLocalControlClient {
  private readonly groupIdsByPlayerId = new Map<string, string>();

  constructor(
    private readonly log: Logger,
    private readonly timeoutMs = 4_000,
  ) {}

  async playbackQuality(input: { host: string; playerId: string }): Promise<SonosLocalPlaybackQuality | null> {
    const cachedGroupId = this.groupIdsByPlayerId.get(input.playerId);
    if (cachedGroupId) {
      try {
        return localPlaybackQualityFromPlaybackMetadata(
          await this.getPlaybackMetadata(input.host, cachedGroupId),
        );
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
    return localPlaybackQualityFromPlaybackMetadata(
      await this.getPlaybackMetadata(input.host, groupId),
    );
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
  private readonly manager = new SonosManager();
  private readonly snapshots = new Map<string, SonosGroupSnapshot>();
  private readonly refreshSequences = new Map<string, number>();
  private readonly localQualityLogSignatures = new Map<string, string>();
  private readonly log: Logger;
  private readonly localControl: SonosLocalControlClient | null;
  private readonly transitionSettleRefreshMs: number;
  private readonly transitionSettleRefreshTimers = new Map<string, NodeJS.Timeout>();
  private periodicHandle: NodeJS.Timeout | null = null;

  constructor(log: Logger, options: SonosBridgeOptions = {}) {
    super();
    this.log = log.child({ module: 'sonos' });
    this.localControl = options.localControl === undefined
      ? new SonosLocalControlApiClient(this.log)
      : options.localControl;
    this.transitionSettleRefreshMs = options.transitionSettleRefreshMs ?? 1_200;
  }

  async start(seedIp: string): Promise<void> {
    this.log.info({ seedIp }, 'discovering Sonos household via seed IP');
    const ok = await this.manager.InitializeFromDevice(seedIp);
    if (!ok) {
      throw new Error(`Sonos seed ${seedIp} did not respond — verify the IP`);
    }

    for (const device of this.manager.Devices) {
      this.log.info(
        { name: device.Name, host: device.Host, uuid: device.Uuid },
        'attached Sonos device',
      );
      this.attachDeviceListeners(device);
      // Prime the snapshot table so a register-activity coming in immediately
      // can ship something useful even before the first Sonos event fires.
      void this.refreshSnapshot(device, 'initial-prime').catch(err =>
        this.log.warn({ err, device: device.Name }, 'initial snapshot fetch failed'),
      );
    }

    // Belt-and-braces: poll once a minute as a safety net in case GENA
    // subscriptions silently expire (Sonos firmware bug; renews are auto
    // but rare hiccups aren't unheard of).
    this.periodicHandle = setInterval(() => {
      for (const device of this.manager.Devices) {
        void this.refreshSnapshot(device, 'periodic-refresh').catch(() => undefined);
      }
    }, 60_000);
  }

  stop(): void {
    if (this.periodicHandle) clearInterval(this.periodicHandle);
    for (const timer of this.transitionSettleRefreshTimers.values()) {
      clearTimeout(timer);
    }
    this.transitionSettleRefreshTimers.clear();
    this.manager.CancelSubscription();
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
      const coord = device.Coordinator;
      if (coord.Host === groupId) return coord;
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
    await coord.Play();
    await this.refreshSnapshot(coord);
  }

  async pause(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    await coord.Pause();
    await this.refreshSnapshot(coord);
  }

  async next(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    await coord.Next();
    await this.refreshSnapshot(coord, 'sonos-change', { suppressTransientNonPlaying: true });
  }

  async previous(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    await coord.Previous();
    await this.refreshSnapshot(coord, 'sonos-change', { suppressTransientNonPlaying: true });
  }

  async setGroupVolume(groupId: string, volume: number): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    const v = Math.min(100, Math.max(0, Math.round(volume)));
    await coord.GroupRenderingControlService.SetGroupVolume({
      InstanceID: 0,
      DesiredVolume: v,
    });
    await this.refreshSnapshot(coord);
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

  // ---- internals --------------------------------------------------------

  private attachDeviceListeners(device: any): void {
    // sonos-ts devices have an Events emitter that re-emits a useful subset
    // of the underlying UPnP service events. We just need a "something
    // happened, please re-snapshot" trigger; the actual state we always pull
    // fresh via PositionInfo / TransportInfo to avoid event-payload drift
    // between firmware versions.
    try {
      device.Events.on(SonosEvents.AVTransport, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.CurrentTrackUri, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.CurrentTrackMetadata, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.CurrentTransportState, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.CurrentTransportStateSimple, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.PlaybackStopped, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.GroupName, () => void this.refreshSnapshot(device));
    } catch (err) {
      this.log.warn({ err, device: device.Name }, 'failed to attach device events');
    }
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
      const coordinator = device.Coordinator ?? device;
      const resolvedGroupId = firstNonEmpty(coordinator.Host, device.Host, device.Uuid);
      if (!resolvedGroupId) {
        throw new Error(`missing Sonos group id for ${device.Name ?? 'unknown device'}`);
      }
      groupId = resolvedGroupId;
      refreshSequence = this.beginRefresh(resolvedGroupId);
      const previousSnapshot = this.snapshots.get(resolvedGroupId);
      const transport = await coordinator.AVTransportService.GetTransportInfo();
      const position = await coordinator.AVTransportService.GetPositionInfo();
      if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;

      const isPlaying = String(transport.CurrentTransportState) === 'PLAYING';
      const trackUri = firstNonEmpty(position.TrackURI, coordinator.CurrentTrackUri, device.CurrentTrackUri);
      const playbackSourceRaw = playbackSourceFromTrackUri(trackUri);
      const positionSeconds = parseDuration(position.RelTime ?? '00:00:00');
      const durationSeconds = parseDuration(position.TrackDuration ?? '00:00:00');
      const metadata = trackMetadataFromMetadata(position.TrackMetaData);
      const metadataDiagnostic = trackMetadataDiagnostic(position.TrackMetaData);
      let audioQualityLabel = audioQualityLabelFromMetadata(
        position.TrackMetaData,
        playbackSourceRaw,
      );
      const localQuality = await this.localControlPlaybackQuality(coordinator, device);
      if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return false;
      if (localQuality?.label) {
        audioQualityLabel = localQuality.label;
      }
      const soundbarEQ = await this.soundbarEQForSnapshot(coordinator, playbackSourceRaw);
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
      let albumArtUri = absoluteAlbumArtUri(
        coordinator.CurrentTrack?.AlbumArtUri
          ?? coordinator.CurrentTrack?.AlbumArtURI
          ?? device.CurrentTrack?.AlbumArtUri
          ?? device.CurrentTrack?.AlbumArtURI
          ?? metadata.albumArtUri,
        coordinator.Host ?? device.Host ?? resolvedGroupId,
      );

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
      }
      if (liveStream) {
        this.log.info(
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
        albumArtUri,
        isPlaying,
        playbackSourceRaw,
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
        groupMemberCount: await this.groupMemberCountForCoordinator(coordinator, resolvedGroupId),
        sampledAt: new Date(),
      };

      this.snapshots.set(resolvedGroupId, snapshot);
      this.emit('change', snapshot, { trigger } satisfies SonosSnapshotChangeContext);
      return true;
    } catch (err) {
      if (groupId && !this.isCurrentRefresh(groupId, refreshSequence)) return false;
      this.log.warn(
        { err, device: device.Name },
        'snapshot refresh failed — will retry on next event',
      );
      return false;
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

  private scheduleTransitionSettleRefresh(device: any, groupId: string): void {
    if (this.transitionSettleRefreshMs <= 0) return;
    if (this.transitionSettleRefreshTimers.has(groupId)) return;

    const timer = setTimeout(() => {
      this.transitionSettleRefreshTimers.delete(groupId);
      void this.refreshSnapshot(device, 'transition-settle-refresh').catch(err => {
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

  private async groupMemberCountForCoordinator(coordinator: any, groupId: string): Promise<number> {
    const parsedCount = await this.parsedZoneGroupMemberCountForCoordinator(coordinator, groupId);
    if (parsedCount !== null) {
      return parsedCount;
    }
    return this.inferredGroupMemberCountForCoordinator(coordinator, groupId);
  }

  private async parsedZoneGroupMemberCountForCoordinator(
    coordinator: any,
    groupId: string,
  ): Promise<number | null> {
    const coordinatorHost = firstNonEmpty(coordinator.Host, groupId);
    const coordinatorUuid = firstNonEmpty(coordinator.Uuid);
    const manager = this.manager as unknown as {
      LoadAllGroups?: () => Promise<ParsedZoneGroup[]>;
    };

    if (typeof manager.LoadAllGroups !== 'function') {
      return null;
    }

    try {
      const groups = await manager.LoadAllGroups.call(this.manager);
      const group = groups.find(candidate =>
        zoneGroupMatchesCoordinator(candidate, coordinatorHost, coordinatorUuid));
      if (!group) {
        return null;
      }

      const visibleMembers = (group.members ?? [])
        .filter(member => !isInvisibleDevice(member as unknown as Record<string, unknown>));
      return Math.max(1, visibleMembers.length);
    } catch {
      return null;
    }
  }

  private inferredGroupMemberCountForCoordinator(coordinator: any, groupId: string): number {
    let devices: any[] = [];
    try {
      devices = this.manager.Devices as any[];
    } catch {
      devices = [coordinator];
    }

    const coordinatorHost = firstNonEmpty(coordinator.Host, groupId);
    const coordinatorUuid = firstNonEmpty(coordinator.Uuid);
    let count = 0;

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
        count += 1;
      } else if (
        coordinatorUuid
        && (candidateCoordinatorUuid === coordinatorUuid || deviceUuid === coordinatorUuid)
      ) {
        count += 1;
      }
    }

    return Math.max(1, count);
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
} | null {
  if (!coordinator || typeof coordinator !== 'object') return null;
  const service = (coordinator as { RenderingControlService?: unknown }).RenderingControlService;
  if (!service || typeof service !== 'object') return null;
  const candidate = service as {
    GetEQ?: (input: { InstanceID: number; EQType: string }) => Promise<{ CurrentValue?: number | string }>;
    SetEQ?: (input: { InstanceID: number; EQType: string; DesiredValue: number }) => Promise<unknown>;
  };
  return candidate;
}

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
    Invisible?: boolean;
  };
  members?: Array<{
    host?: string;
    uuid?: string;
    Invisible?: boolean;
  }>;
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
  return reconcileRadioStreamContent(baseMetadata, xmlTagValue(metadata, 'r:streamContent'));
}

function trackMetadataDiagnostic(metadata: unknown): SonosTrackMetadataDiagnostic {
  if (!metadata || typeof metadata !== 'object') {
    const raw = typeof metadata === 'string' ? metadata : '';
    const streamContent = xmlTagValue(raw, 'r:streamContent');
    return {
      didlTitle: xmlTagValue(raw, 'dc:title'),
      didlArtist: xmlTagValue(raw, 'dc:creator') ?? xmlTagValue(raw, 'upnp:artist'),
      didlAlbum: xmlTagValue(raw, 'upnp:album'),
      streamContent,
      streamFields: streamContent ? radioStreamContentFields(streamContent) : {},
    };
  }

  const track = metadata as Record<string, unknown>;
  const streamContent = firstObjectString(
    track.StreamContent,
    track.streamContent,
    track.StreamInfo,
    track.streamInfo,
  );
  return {
    didlTitle: firstObjectString(track.Title, track.title) || null,
    didlArtist: firstObjectString(track.Artist, track.artist, track.Creator, track.creator) || null,
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
    firstObjectString(track.StreamContent, track.streamContent, track.StreamInfo, track.streamInfo),
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
  if (input.metadataDiagnostic.streamFields.title || input.metadataDiagnostic.streamFields.artist) return false;
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
    'apple music radio',
    'radio',
    'station',
  ].includes(normalized);
}

function summarizeTrackUri(trackUri: string): string {
  if (trackUri.length <= 96) return trackUri;
  return `${trackUri.slice(0, 80)}…${trackUri.slice(-12)}`;
}

function isInvisibleDevice(device: Record<string, unknown>): boolean {
  return device.Invisible === true || device.invisible === true || device.isInvisible === true;
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

function decodeXmlEntities(value: string): string {
  return value
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'");
}
