export interface SonosFavoriteItem {
  id: string;
  title: string;
  description: string | null;
  type: string | null;
  category: SonosFavoriteCategory;
  playbackKind: SonosFavoritePlaybackKind;
  artistStationId: string | null;
  albumArtUri: string | null;
  uri: string | null;
  resourceMetadata: string | null;
  playbackSourceRaw: string | null;
  playable: boolean;
}

export type SonosFavoriteCategory = 'playlist' | 'album' | 'song' | 'artist' | 'station' | 'collection';
export type SonosFavoritePlaybackKind = 'direct' | 'artistStation' | 'unavailable';

export interface SonosFavoritePlaybackPayload {
  uri: string;
  metadata: string;
  title: string;
}

interface AppleMusicArtistSearchResponse {
  results?: Array<{
    wrapperType?: string | null;
    artistId?: number | string | null;
    artistName?: string | null;
  }>;
}

const appleMusicArtistIdCache = new Map<string, string | null>();

export interface SonosQueueItem {
  id: string;
  trackNumber: number;
  title: string;
  artist: string;
  album: string;
  albumKey: string;
  albumArtUri: string | null;
  sonosAlbumArtUri: string | null;
  artworkSource: 'sonos' | 'itunes-lookup' | 'itunes-search' | 'none';
  uri: string | null;
  durationSeconds: number;
}

export interface SonosQueueView {
  groupId: string;
  updateId: number;
  currentTrackNumber: number | null;
  items: SonosQueueItem[];
}

export interface SonosQueueArtworkResult {
  albumKey: string;
  albumArtUri: string | null;
  artworkSource: SonosQueueItem['artworkSource'];
}

export interface SonosFavoriteAddResult {
  added: boolean;
  alreadyExists: boolean;
  favorite: SonosFavoriteItem;
}

export interface SonosCurrentFavoriteStatus {
  available: boolean;
  isFavorite: boolean;
  favorite: SonosFavoriteItem | null;
}

interface ParsedSonosTrack {
  Artist?: string;
  Title?: string;
  Album?: string;
  AlbumArtUri?: string;
  Duration?: string;
  ItemId?: string;
  TrackUri?: string;
}

export interface CurrentFavoriteMetadataInput {
  title: string;
  artist: string;
  album: string;
  albumArtUri: string | null;
  uri: string;
  upnpClass?: string | null;
  serviceDescriptor?: string | null;
}

export function parseSonosFavorites(result: unknown, host: string): SonosFavoriteItem[] {
  if (typeof result !== 'string' || !result.trim()) return [];
  const didl = decodeXmlEntities(result);
  return elementFragments(didl, 'item').map(fragment => {
    // Keep Sonos object IDs byte-for-byte as advertised. Catalog separators
    // such as `album%3a1499378108` are part of the transport URI; decoding the
    // colon makes the otherwise valid container fail at playback time.
    const uri = tagText(fragment, 'res');
    const resourceMetadata = tagText(fragment, 'r:resMD');
    const albumArt = tagText(fragment, 'upnp:albumArtURI');
    const description = tagText(fragment, 'r:description');
    const type = tagText(fragment, 'r:type');
    const category = favoriteCategory(uri, resourceMetadata, type);
    const playbackSourceRaw = favoritePlaybackSource(uri, resourceMetadata, description);
    const artistStationId = category === 'artist' ? appleMusicArtistId(resourceMetadata) : null;
    const playbackKind: SonosFavoritePlaybackKind = uri && resourceMetadata
      ? 'direct'
      : category === 'artist' && isAppleMusicDescription(description)
        ? 'artistStation'
        : 'unavailable';
    return {
      id: attributeValue(fragment, 'id') ?? '',
      title: tagText(fragment, 'dc:title') ?? 'Untitled Favorite',
      description,
      type,
      category,
      playbackKind,
      artistStationId,
      albumArtUri: absoluteSonosArtworkURL(albumArt, host),
      uri,
      resourceMetadata,
      playbackSourceRaw,
      playable: playbackKind !== 'unavailable',
    };
  }).filter(item => item.id || item.title);
}

export function favoritePlaybackSource(
  uri: string | null,
  resourceMetadata: string | null,
  description: string | null,
): string | null {
  const metadata = [uri, resourceMetadata, description].filter(Boolean).join(' ');
  const serviceType = metadata.match(/SA_RINCON(\d+)_/i)?.[1];
  if (serviceType === '52231') return 'appleMusic';
  if (serviceType === '3079') return 'spotify';
  if (serviceType === '51463') return 'amazonMusic';

  const normalized = metadata.toLowerCase().replace(/[^a-z0-9\u4e00-\u9fff]/g, '');
  if (normalized.includes('applemusic') || /[?&]sid=204(?:&|$)/i.test(uri ?? '')) return 'appleMusic';
  if (normalized.includes('spotify')) return 'spotify';
  if (normalized.includes('amazonmusic')) return 'amazonMusic';
  if (normalized.includes('youtubemusic')) return 'youtubeMusic';
  if (normalized.includes('netease') || normalized.includes('网易')) return 'neteaseMusic';
  return null;
}

export function favoriteUsesDirectTransport(favorite: SonosFavoriteItem): boolean {
  const uri = canonicalSonosURI(favorite.uri);
  return favorite.category === 'station'
    || uri.startsWith('x-sonosapi-radio:')
    || uri.startsWith('x-sonosapi-stream:')
    || uri.startsWith('x-sonosapi-hls:');
}

export function buildAppleMusicArtistStationPlayback(
  favorite: SonosFavoriteItem,
  favorites: SonosFavoriteItem[],
): SonosFavoritePlaybackPayload | null {
  if (favorite.playbackKind !== 'artistStation' || !favorite.artistStationId) return null;
  const service = favoriteServiceParameters(favorite, favorites);
  const descriptor = descriptorTag(favorite.resourceMetadata)
    ?? service?.descriptor
    ?? null;
  if (!service || !descriptor) return null;

  const radioId = `radio:ra.${favorite.artistStationId}`;
  const encodedRadioId = radioId.replace(/:/g, '%3a');
  const title = `${favorite.title} Radio`;
  const uri = `x-sonosapi-radio:${encodedRadioId}?sid=${service.sid}&flags=8300&sn=${service.sn}`;
  const metadata = '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" '
    + 'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
    + 'xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" '
    + 'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
    + `<item id="000c206c${escapeXml(encodedRadioId)}" parentID="" restricted="true">`
    + `<dc:title>${escapeXml(title)}</dc:title>`
    + '<upnp:class>object.item.audioItem.audioBroadcast.#programRadio</upnp:class>'
    + descriptor
    + '</item></DIDL-Lite>';
  return { uri, metadata, title };
}

export async function resolveAppleMusicArtistId(
  artistName: string,
  fetchJson: (url: URL, signal: AbortSignal) => Promise<AppleMusicArtistSearchResponse> = defaultAppleMusicArtistSearch,
): Promise<string | null> {
  const normalizedName = artistName.trim().toLowerCase();
  if (!normalizedName) return null;
  if (appleMusicArtistIdCache.has(normalizedName)) {
    return appleMusicArtistIdCache.get(normalizedName) ?? null;
  }

  const url = new URL('https://itunes.apple.com/search');
  url.searchParams.set('term', artistName.trim());
  url.searchParams.set('media', 'music');
  url.searchParams.set('entity', 'musicArtist');
  url.searchParams.set('limit', '5');
  url.searchParams.set('country', 'US');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 2_500);
  timer.unref?.();
  try {
    const response = await fetchJson(url, controller.signal);
    const artists = (response.results ?? []).filter(result =>
      result.wrapperType === 'artist' && result.artistId !== null && result.artistId !== undefined);
    const exact = artists.find(result => result.artistName?.trim().toLowerCase() === normalizedName);
    const match = exact ?? artists[0];
    const artistId = match ? nonEmpty(String(match.artistId ?? '')) : null;
    appleMusicArtistIdCache.set(normalizedName, artistId);
    return artistId;
  } finally {
    clearTimeout(timer);
  }
}

export function sonosQueueView(
  groupId: string,
  result: unknown,
  updateId: unknown,
  currentTrackNumber: unknown,
): SonosQueueView {
  const tracks = Array.isArray(result) ? result as ParsedSonosTrack[] : [];
  return {
    groupId,
    updateId: integerOrZero(updateId),
    currentTrackNumber: positiveInteger(currentTrackNumber),
    items: tracks.map((track, index) => {
      const item = {
        id: nonEmpty(track.ItemId) ?? `Q:0/${index + 1}`,
        trackNumber: queueTrackNumber(track.ItemId, index),
        title: nonEmpty(track.Title) ?? 'Untitled track',
        artist: nonEmpty(track.Artist) ?? '',
        album: nonEmpty(track.Album) ?? '',
        albumArtUri: httpURL(track.AlbumArtUri),
        uri: nonEmpty(track.TrackUri),
        durationSeconds: durationSeconds(track.Duration),
      };
      return {
        ...item,
        albumKey: sonosQueueAlbumKey(item),
        sonosAlbumArtUri: item.albumArtUri,
        artworkSource: item.albumArtUri ? 'sonos' as const : 'none' as const,
      };
    }),
  };
}

export function sonosQueueAlbumKey(
  item: Pick<SonosQueueItem, 'id' | 'album' | 'uri'>,
): string {
  const uri = canonicalSonosURI(item.uri);
  const service = uri.match(/[?&]sid=(\d+)/)?.[1]
    ?? uri.match(/^([a-z][a-z0-9+.-]*):/)?.[1]
    ?? 'unknown';
  const album = normalizedQueueAlbum(item.album);
  return album
    ? `album:${service}:${album}`
    : `track:${service}:${item.id.trim().toLowerCase()}`;
}

export function favoriteForCurrentURI(
  favorites: SonosFavoriteItem[],
  uri: string,
): SonosFavoriteItem | undefined {
  const current = canonicalSonosURI(uri);
  const currentPath = current.split('?')[0];
  const currentService = sonosServiceKey(uri);
  return favorites.find(favorite => {
    const favoriteURI = canonicalSonosURI(favorite.uri);
    if (favoriteURI.split('?')[0] !== currentPath) return false;
    const favoriteService = sonosServiceKey(favorite.uri);
    return !currentService || !favoriteService || currentService === favoriteService;
  });
}

export function serviceDescriptorForCurrentURI(
  favorites: SonosFavoriteItem[],
  uri: string,
): string | null {
  const currentService = sonosServiceKey(uri);
  const candidates = currentService
    ? favorites.filter(favorite => sonosServiceKey(favorite.uri) === currentService)
    : favorites;
  for (const favorite of candidates) {
    const descriptor = favorite.resourceMetadata?.match(/<desc\b[^>]*>[\s\S]*?<\/desc>/i)?.[0];
    if (descriptor) return descriptor;
  }
  return null;
}

export function buildCurrentTrackResourceMetadata(input: CurrentFavoriteMetadataInput): string {
  const itemId = currentTrackMetadataObjectID(input.uri);
  const descriptor = input.serviceDescriptor?.trim() || '<desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">RINCON_AssociatedZPUDN</desc>';
  const artist = input.artist.trim();
  const album = input.album.trim();
  const artwork = input.albumArtUri?.trim() ?? '';
  return '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" '
    + 'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
    + 'xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" '
    + 'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
    + `<item id="${escapeXml(itemId)}" parentID="" restricted="true">`
    + `<dc:title>${escapeXml(input.title)}</dc:title>`
    + `<upnp:class>${escapeXml(input.upnpClass?.trim() || 'object.item.audioItem.musicTrack')}</upnp:class>`
    + (artwork ? `<upnp:albumArtURI>${escapeXml(artwork)}</upnp:albumArtURI>` : '')
    + (artist ? `<dc:creator>${escapeXml(artist)}</dc:creator><upnp:albumArtist>${escapeXml(artist)}</upnp:albumArtist>` : '')
    + (album ? `<upnp:album>${escapeXml(album)}</upnp:album>` : '')
    + descriptor
    + '</item></DIDL-Lite>';
}

export function buildFavoriteCreateElements(input: CurrentFavoriteMetadataInput): string {
  const metadata = buildCurrentTrackResourceMetadata(input);
  const scheme = input.uri.split(':', 1)[0] || 'x-sonos-http';
  const artwork = input.albumArtUri?.trim() ?? '';
  return '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" '
    + 'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
    + 'xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" '
    + 'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
    + '<item id="" parentID="FV:2" restricted="false">'
    + `<dc:title>${escapeXml(input.title)}</dc:title>`
    + '<upnp:class>object.itemobject.item.sonos-favorite</upnp:class>'
    + `<res protocolInfo="${escapeXml(scheme)}:*:*:*">${escapeXml(input.uri)}</res>`
    + (artwork ? `<upnp:albumArtURI>${escapeXml(artwork)}</upnp:albumArtURI>` : '')
    + '<r:type>instantPlay</r:type>'
    + `<r:description>${escapeXml(input.title)}</r:description>`
    + `<r:resMD>${escapeXml(metadata)}</r:resMD>`
    + '</item></DIDL-Lite>';
}

function elementFragments(xml: string, tag: string): string[] {
  const pattern = new RegExp(`<${tag}\\b[\\s\\S]*?<\\/${tag}>`, 'gi');
  return xml.match(pattern) ?? [];
}

function tagText(fragment: string, tag: string): string | null {
  const escapedTag = tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = fragment.match(new RegExp(`<${escapedTag}\\b[^>]*>([\\s\\S]*?)<\\/${escapedTag}>`, 'i'));
  if (!match) return null;
  return decodeXmlEntities(match[1] ?? '').trim() || null;
}

function attributeValue(fragment: string, name: string): string | null {
  const openingTag = fragment.match(/^<[^>]+>/)?.[0] ?? '';
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = openingTag.match(new RegExp(`\\s${escapedName}=(?:"([^"]*)"|'([^']*)')`, 'i'));
  return match ? decodeXmlEntities(match[1] ?? match[2] ?? '') : null;
}

function decodeXmlEntities(value: string): string {
  return value
    .replace(/&#x([0-9a-f]+);/gi, (_match, hex: string) => String.fromCodePoint(Number.parseInt(hex, 16)))
    .replace(/&#([0-9]+);/g, (_match, digits: string) => String.fromCodePoint(Number.parseInt(digits, 10)))
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

function escapeXml(value: unknown): string {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function decodeTrackUri(value: string | null): string | null {
  if (!value) return null;
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function canonicalSonosURI(value: unknown): string {
  const uri = nonEmpty(value);
  if (!uri) return '';
  const decoded = decodeTrackUri(uri) ?? uri;
  return decoded.replace(/&amp;/gi, '&').trim().toLowerCase();
}

function sonosServiceKey(value: unknown): string | null {
  const uri = canonicalSonosURI(value);
  const sid = uri.match(/[?&]sid=(\d+)/)?.[1];
  const sn = uri.match(/[?&]sn=(\d+)/)?.[1];
  return sid && sn ? `${sid}:${sn}` : null;
}

function currentTrackMetadataObjectID(uri: string): string {
  const transportURI = uri.replace(/&amp;/gi, '&').trim();
  const resource = transportURI.match(/^x-sonos-http:([^?]+?)(?:\.mp4)?(?:\?|$)/i)?.[1];
  if (!resource) return '-1';
  if (/^1003[0-9a-f]{4}/i.test(resource)) return resource;
  const objectID = resource.replace(/%3a/ig, '%3a').replace(/:/g, '%3a');
  const flags = Number(transportURI.match(/[?&]flags=(\d+)/i)?.[1] ?? 0);
  const flagsHex = Number.isFinite(flags) ? Math.max(0, flags).toString(16).padStart(4, '0') : '0000';
  return `1003${flagsHex}${objectID}`;
}

function favoriteCategory(
  uri: string | null,
  resourceMetadata: string | null,
  type: string | null,
): SonosFavoriteCategory {
  const upnpClass = (tagText(resourceMetadata ?? '', 'upnp:class') ?? '').toLowerCase();
  if (upnpClass.includes('musicartist')) return 'artist';
  if (upnpClass.includes('musictrack')) return 'song';
  if (upnpClass.includes('audiobroadcast') || upnpClass.includes('audioitem') && !upnpClass.includes('musictrack')) return 'station';
  if (upnpClass.includes('musicalbum')) return 'album';
  if (upnpClass.includes('playlistcontainer') || upnpClass.includes('sameartist')) return 'playlist';
  if (upnpClass.includes('object.container')) return 'collection';

  const source = canonicalSonosURI(uri);
  if (source.includes('x-sonosapi-radio:') || source.includes('x-sonosapi-stream:')) return 'station';
  if (source.includes('album:') || source.includes('album%3a')) return 'album';
  if (source.includes('playlist:') || source.includes('playlist%3a')) return 'playlist';
  if (source.includes('song:') || source.includes('song%3a')) return 'song';
  if (source.includes('x-rincon-cpcontainer:')) return 'playlist';
  if (type?.trim().toLowerCase() === 'shortcut') return 'collection';
  return 'song';
}

function appleMusicArtistId(resourceMetadata: string | null): string | null {
  if (!resourceMetadata) return null;
  return resourceMetadata.match(/artist(?:%3a|:)(\d+)/i)?.[1] ?? null;
}

function isAppleMusicDescription(value: string | null): boolean {
  return value?.trim().toLowerCase() === 'apple music';
}

function favoriteServiceParameters(
  favorite: SonosFavoriteItem,
  favorites: SonosFavoriteItem[],
): { sid: string; sn: string; descriptor: string | null } | null {
  const targetDescriptor = descriptorText(favorite.resourceMetadata);
  const candidates = favorites
    .map(item => ({
      item,
      parameters: serviceParameters(item.uri),
      descriptor: descriptorTag(item.resourceMetadata),
      descriptorText: descriptorText(item.resourceMetadata),
    }))
    .filter(candidate => candidate.parameters);
  const exact = targetDescriptor
    ? candidates.find(candidate => candidate.descriptorText === targetDescriptor)
    : undefined;
  const sameService = candidates.find(candidate =>
    candidate.item.description?.trim().toLowerCase() === favorite.description?.trim().toLowerCase());
  const match = exact ?? sameService;
  if (!match?.parameters) return null;
  return { ...match.parameters, descriptor: descriptorTag(favorite.resourceMetadata) ?? match.descriptor };
}

function serviceParameters(uri: string | null): { sid: string; sn: string } | null {
  const source = canonicalSonosURI(uri);
  const sid = source.match(/[?&]sid=(\d+)/)?.[1];
  const sn = source.match(/[?&]sn=(\d+)/)?.[1];
  return sid && sn ? { sid, sn } : null;
}

function descriptorTag(resourceMetadata: string | null): string | null {
  return resourceMetadata?.match(/<desc\b[^>]*>[\s\S]*?<\/desc>/i)?.[0] ?? null;
}

function descriptorText(resourceMetadata: string | null): string | null {
  return tagText(resourceMetadata ?? '', 'desc');
}

async function defaultAppleMusicArtistSearch(
  url: URL,
  signal: AbortSignal,
): Promise<AppleMusicArtistSearchResponse> {
  const response = await fetch(url, { signal, headers: { accept: 'application/json' } });
  if (!response.ok) throw new Error(`apple_music_artist_lookup_failed: HTTP ${response.status}`);
  return await response.json() as AppleMusicArtistSearchResponse;
}

function queueTrackNumber(itemId: unknown, index: number): number {
  const parsed = Number(nonEmpty(itemId)?.match(/Q:0\/(\d+)/i)?.[1]);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : index + 1;
}

function normalizedQueueAlbum(value: unknown): string {
  return (nonEmpty(value) ?? '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

function durationSeconds(value: unknown): number {
  const parts = nonEmpty(value)?.split(':').map(Number);
  if (!parts || parts.some(part => !Number.isFinite(part))) return 0;
  return parts.reduce((total, part) => total * 60 + part, 0);
}

function integerOrZero(value: unknown): number {
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : 0;
}

function positiveInteger(value: unknown): number | null {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : null;
}

function nonEmpty(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed || null;
}

function httpURL(value: unknown): string | null {
  const url = nonEmpty(value);
  if (!url) return null;
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:' ? parsed.href : null;
  } catch {
    return null;
  }
}

function absoluteSonosArtworkURL(value: string | null, host: string): string | null {
  if (!value) return null;
  if (value.startsWith('/')) return httpURL(`http://${host}:1400${value}`);
  return httpURL(value);
}
