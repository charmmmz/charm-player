import { SonosEvents, SonosManager, type SonosDevice } from '@svrooij/sonos';
import { EventEmitter } from 'node:events';
import type { Logger } from 'pino';
import type { SonosGroupSnapshot } from './types.js';

export type SonosSnapshotChangeTrigger =
  | 'sonos-change'
  | 'periodic-refresh'
  | 'initial-prime';

export interface SonosSnapshotChangeContext {
  trigger: SonosSnapshotChangeTrigger;
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
  private readonly log: Logger;
  private periodicHandle: NodeJS.Timeout | null = null;

  constructor(log: Logger) {
    super();
    this.log = log.child({ module: 'sonos' });
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
    await this.refreshSnapshot(coord);
  }

  async previous(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    await coord.Previous();
    await this.refreshSnapshot(coord);
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
  ): Promise<void> {
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
      const transport = await coordinator.AVTransportService.GetTransportInfo();
      const position = await coordinator.AVTransportService.GetPositionInfo();
      if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return;

      const isPlaying = String(transport.CurrentTransportState) === 'PLAYING';
      const trackUri = firstNonEmpty(position.TrackURI, coordinator.CurrentTrackUri, device.CurrentTrackUri);
      const playbackSourceRaw = playbackSourceFromTrackUri(trackUri);
      const positionSeconds = parseDuration(position.RelTime ?? '00:00:00');
      const durationSeconds = parseDuration(position.TrackDuration ?? '00:00:00');
      const metadata = trackMetadataFromMetadata(position.TrackMetaData);
      const audioQualityLabel = audioQualityLabelFromMetadata(
        position.TrackMetaData,
        playbackSourceRaw,
      );

      // Prefer GetPositionInfo's parsed DIDL because radio streams put the
      // current song in r:streamContent while sonos-ts may cache that raw
      // `TYPE=SNG|TITLE ...` payload as Artist.
      const trackTitle = firstMeaningfulMetadata(
        'title',
        metadata.title,
        coordinator.CurrentTrack?.Title,
        device.CurrentTrack?.Title,
      );
      const artist = firstMeaningfulMetadata(
        'artist',
        metadata.artist,
        coordinator.CurrentTrack?.Artist,
        device.CurrentTrack?.Artist,
      );
      const album = firstMeaningfulMetadata(
        'album',
        metadata.album,
        coordinator.CurrentTrack?.Album,
        device.CurrentTrack?.Album,
      );
      const albumArtUri = absoluteAlbumArtUri(
        coordinator.CurrentTrack?.AlbumArtUri
          ?? coordinator.CurrentTrack?.AlbumArtURI
          ?? device.CurrentTrack?.AlbumArtUri
          ?? device.CurrentTrack?.AlbumArtURI
          ?? metadata.albumArtUri,
        coordinator.Host ?? device.Host ?? resolvedGroupId,
      );

      const snapshot: SonosGroupSnapshot = {
        groupId: resolvedGroupId,
        speakerName: coordinator.Name ?? device.Name ?? device.Uuid,
        trackTitle,
        artist,
        album,
        albumArtUri,
        isPlaying,
        playbackSourceRaw,
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
    } catch (err) {
      if (groupId && !this.isCurrentRefresh(groupId, refreshSequence)) return;
      this.log.warn(
        { err, device: device.Name },
        'snapshot refresh failed — will retry on next event',
      );
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
