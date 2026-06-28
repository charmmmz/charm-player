import apn from '@parse/node-apn';
import { promises as fs } from 'node:fs';
import type { Logger } from 'pino';
import type { LiveActivityContentState, LiveActivityStartAttributes } from './types.js';

/// Swift's `Date` Codable default uses NSDate reference epoch (2001-01-01 UTC),
/// NOT Unix epoch. ContentState fields like `startedAt` / `endsAt` must be
/// converted before they go on the wire or the iOS decoder lands on a date
/// in 1970 + offset.
const SWIFT_DATE_EPOCH_OFFSET = 978307200; // (Date.UTC(2001,0,1) / 1000)
export function toSwiftDate(unixSeconds: number): number {
  return unixSeconds - SWIFT_DATE_EPOCH_OFFSET;
}

const DEFAULT_APNS_MAX_ATTEMPTS = 3;
const DEFAULT_APNS_RETRY_DELAYS_MS = [250, 750] as const;

export interface ApnsConfig {
  bundleId: string;
  keyPath: string;
  keyId: string;
  teamId: string;
  production: boolean;
}

export interface ApnsResult {
  sent: number;
  failed: number;
  unregistered: string[]; // tokens APNs reported as gone (410)
}

export interface ApnsStatus {
  mode: 'ready' | 'dry-run';
  environment: 'sandbox' | 'production';
  bundleId: string;
  keyIdConfigured: boolean;
  teamIdConfigured: boolean;
  keyFilePresent: boolean;
  missing: string[];
}

export function apnsStatusFromConfig(config: ApnsConfig, keyFilePresent: boolean): ApnsStatus {
  const keyIdConfigured = config.keyId.trim().length > 0;
  const teamIdConfigured = config.teamId.trim().length > 0;
  const missing: string[] = [];
  if (!keyIdConfigured) missing.push('APNS_KEY_ID');
  if (!teamIdConfigured) missing.push('APNS_TEAM_ID');
  if (!keyFilePresent) missing.push('apns.p8');

  return {
    mode: missing.length === 0 ? 'ready' : 'dry-run',
    environment: config.production ? 'production' : 'sandbox',
    bundleId: config.bundleId,
    keyIdConfigured,
    teamIdConfigured,
    keyFilePresent,
    missing,
  };
}

type LiveActivityEvent = 'start' | 'update' | 'end';
type LiveActivityNote = apn.Notification & {
  pushType: string;
  relevanceScore: number;
  timestamp: number;
  staleDate: number;
  event: LiveActivityEvent;
  attributesType: string;
  attributes: Record<string, unknown>;
  contentState: Record<string, unknown>;
  inputPushToken: number;
};

export function makeLiveActivityStartNotification(
  bundleId: string,
  attributes: LiveActivityStartAttributes,
  contentState: LiveActivityContentState,
  nowUnixSeconds = Math.floor(Date.now() / 1000),
  relevanceScore = 50,
): apn.Notification {
  const note = new apn.Notification() as LiveActivityNote;
  note.topic = `${bundleId}.push-type.liveactivity`;
  note.pushType = 'liveactivity';
  note.expiry = nowUnixSeconds + 3600;
  note.relevanceScore = relevanceScore;
  note.timestamp = nowUnixSeconds;
  note.staleDate = nowUnixSeconds + 8 * 3600;
  note.event = 'start';
  note.attributesType = 'SonosActivityAttributes';
  note.attributes = attributes as unknown as Record<string, unknown>;
  note.contentState = contentState as unknown as Record<string, unknown>;
  note.inputPushToken = 1;
  note.alert = {
    title: contentState.trackTitle,
    body: liveActivityStartAlertBody(attributes, contentState),
  };
  return note;
}

export function liveActivityNotificationPayloadBytes(note: apn.Notification): number {
  return Buffer.byteLength(JSON.stringify({ aps: note.aps }), 'utf8');
}

function liveActivityStartAlertBody(
  attributes: LiveActivityStartAttributes,
  contentState: LiveActivityContentState,
): string {
  const artist = contentState.artist?.trim();
  const speakerName = attributes.speakerName?.trim();
  if (artist && speakerName) return `${artist} on ${speakerName}`;
  return artist || speakerName || 'Now playing';
}

/// Wraps `@parse/node-apn`. When the `.p8` key isn't present yet (Apple
/// Developer enrollment still pending), we go into "dry-run" mode and only
/// log the payload we *would* have sent — useful for validating the data
/// pipeline (Sonos events → ContentState shape) before push actually works.
export class ApnsClient {
  private provider: apn.Provider | null = null;
  private readonly log: Logger;
  private readonly config: ApnsConfig;
  private readonly dryRun: boolean;
  private readonly apnsStatus: ApnsStatus;
  private readonly retryDelaysMs: readonly number[] = DEFAULT_APNS_RETRY_DELAYS_MS;

  private constructor(config: ApnsConfig, status: ApnsStatus, log: Logger) {
    this.config = config;
    this.apnsStatus = status;
    this.dryRun = status.mode === 'dry-run';
    this.log = log.child({ module: 'apns' });
  }

  static async create(config: ApnsConfig, log: Logger): Promise<ApnsClient> {
    const childLog = log.child({ module: 'apns' });
    const keyFilePresent = await fileExists(config.keyPath);
    const status = apnsStatusFromConfig(config, keyFilePresent);

    if (status.missing.length > 0) {
      childLog.warn(
        { missing: status.missing, keyPath: config.keyPath },
        'APNs configuration incomplete — running in DRY-RUN mode (logs payloads only).',
      );
      return new ApnsClient(config, status, log);
    }

    const client = new ApnsClient(config, status, log);
    client.provider = new apn.Provider({
      token: {
        key: config.keyPath,
        keyId: config.keyId,
        teamId: config.teamId,
      },
      production: config.production,
    });
    childLog.info(
      { production: config.production, bundleId: config.bundleId },
      'APNs provider ready',
    );
    return client;
  }

  status(): ApnsStatus {
    return this.apnsStatus;
  }

  /// Push an `update` event to a list of Live Activity push tokens.
  async pushUpdate(
    tokens: string[],
    contentState: LiveActivityContentState,
    relevanceScore = 50,
  ): Promise<ApnsResult> {
    return this.push(tokens, 'update', contentState, relevanceScore);
  }

  /// Push an `end` event so iOS removes the Live Activity from Lock Screen.
  async pushEnd(tokens: string[], contentState: LiveActivityContentState): Promise<ApnsResult> {
    return this.push(tokens, 'end', contentState, 0);
  }

  /// Push a `start` event to ActivityKit push-to-start tokens.
  async pushStart(
    tokens: string[],
    attributes: LiveActivityStartAttributes,
    contentState: LiveActivityContentState,
    relevanceScore = 50,
  ): Promise<ApnsResult> {
    const note = makeLiveActivityStartNotification(
      this.config.bundleId,
      attributes,
      contentState,
      Math.floor(Date.now() / 1000),
      relevanceScore,
    );
    return this.sendLiveActivityNotification(tokens, note, 'start', contentState);
  }

  private async push(
    tokens: string[],
    event: 'update' | 'end',
    contentState: LiveActivityContentState,
    relevanceScore: number,
  ): Promise<ApnsResult> {
    // The Live Activity-specific fields (pushType, relevanceScore, timestamp,
    // staleDate, event, contentState) exist on the Notification prototype at
    // runtime but the shipped .d.ts hasn't been updated to declare them yet,
    // so we widen the type once with a local interface and assign through it.
    const note = new apn.Notification() as LiveActivityNote;
    note.topic = `${this.config.bundleId}.push-type.liveactivity`;
    note.pushType = 'liveactivity';
    note.expiry = Math.floor(Date.now() / 1000) + 3600;
    note.relevanceScore = relevanceScore;
    note.timestamp = Math.floor(Date.now() / 1000);
    // Live Activities Apple-suggested 8 hour stale; iOS auto-ends at 12h.
    note.staleDate = Math.floor(Date.now() / 1000) + 8 * 3600;
    note.event = event;
    note.contentState = contentState as unknown as Record<string, unknown>;

    return this.sendLiveActivityNotification(tokens, note, event, contentState);
  }

  private async sendLiveActivityNotification(
    tokens: string[],
    note: apn.Notification,
    event: LiveActivityEvent,
    contentState: LiveActivityContentState,
  ): Promise<ApnsResult> {
    if (tokens.length === 0) return { sent: 0, failed: 0, unregistered: [] };
    const payloadBytes = liveActivityNotificationPayloadBytes(note);

    if (this.dryRun || !this.provider) {
      this.log.info(
        {
          source: 'relay',
          action: 'apns-dry-run',
          event,
          tokens: tokens.length,
          payloadBytes,
          state: summarizeLiveActivityState(contentState),
        },
        'live_activity',
      );
      return { sent: tokens.length, failed: 0, unregistered: [] };
    }

    const result: ApnsResult = { sent: 0, failed: 0, unregistered: [] };
    let pendingTokens = [...tokens];
    for (let attempt = 1; pendingTokens.length > 0 && attempt <= DEFAULT_APNS_MAX_ATTEMPTS; attempt += 1) {
      try {
        this.log[attempt === 1 ? 'debug' : 'info'](
          {
            source: 'relay',
            action: attempt === 1 ? 'apns-payload' : 'apns-retry',
            event,
            attempt,
            tokens: pendingTokens.length,
            payloadBytes,
            state: summarizeLiveActivityState(contentState),
          },
          'live_activity',
        );

        const response = await this.provider.send(note, pendingTokens);
        result.sent += response.sent.length;

        const retryTokens: string[] = [];
        for (const failure of response.failed) {
          // 410 Unregistered = device de-installed app or token rotated;
          // surface so the caller can prune the token store.
          if (failure.status === 410 && failure.device) {
            result.failed += 1;
            result.unregistered.push(failure.device);
            this.log.info(
              { token: failure.device.slice(0, 8) + '…' },
              'APNs reported token Unregistered — pruning',
            );
            continue;
          }

          if (
            attempt < DEFAULT_APNS_MAX_ATTEMPTS
            && failure.device
            && isRetryableApnsFailure(failure)
          ) {
            retryTokens.push(failure.device);
            this.log.warn(
              {
                source: 'relay',
                action: 'apns-retry-scheduled',
                event,
                attempt,
                nextAttempt: attempt + 1,
                token: failure.device.slice(0, 8) + '…',
                reason: apnsFailureReason(failure),
              },
              'live_activity',
            );
            continue;
          }

          result.failed += 1;
          this.log.warn({ failure }, 'APNs push failed');
        }

        pendingTokens = retryTokens;
      } catch (err) {
        if (attempt < DEFAULT_APNS_MAX_ATTEMPTS && isRetryableApnsError(err)) {
          this.log.warn(
            {
              source: 'relay',
              action: 'apns-retry-scheduled',
              event,
              attempt,
              nextAttempt: attempt + 1,
              err,
            },
            'live_activity',
          );
        } else {
          this.log.error({ err }, 'APNs send threw');
          result.failed += pendingTokens.length;
          pendingTokens = [];
        }
      }

      if (pendingTokens.length > 0 && attempt < DEFAULT_APNS_MAX_ATTEMPTS) {
        await sleep(this.apnsRetryDelayMs(attempt));
      }
    }

    this.log.debug(
      {
        source: 'relay',
        action: 'apns-send-result',
        event,
        tokens: tokens.length,
        payloadBytes,
        sent: result.sent,
        failed: result.failed,
        unregistered: result.unregistered.map(token => token.slice(0, 8) + '…'),
        state: summarizeLiveActivityState(contentState),
      },
      'live_activity',
    );
    return result;
  }

  private apnsRetryDelayMs(attempt: number): number {
    const retryDelays = this.retryDelaysMs ?? DEFAULT_APNS_RETRY_DELAYS_MS;
    return retryDelays[Math.min(attempt - 1, retryDelays.length - 1)] ?? 0;
  }

  shutdown(): void {
    this.provider?.shutdown();
  }
}

function isRetryableApnsFailure(failure: unknown): boolean {
  const status = numericValue((failure as { status?: unknown })?.status);
  if (status !== null && status >= 400 && status < 500) return false;
  return retryableApnsText(apnsFailureReason(failure));
}

function isRetryableApnsError(err: unknown): boolean {
  return retryableApnsText(apnsFailureReason({ error: err }));
}

function retryableApnsText(text: string): boolean {
  const value = text.toLowerCase();
  return [
    'timeout',
    'timed out',
    'etimedout',
    'econnreset',
    'econnrefused',
    'socket',
    'network',
  ].some(pattern => value.includes(pattern));
}

function apnsFailureReason(failure: unknown): string {
  const value = failure as {
    error?: unknown;
    response?: unknown;
    reason?: unknown;
    code?: unknown;
    status?: unknown;
  };
  return [
    errorDescription(value?.error),
    objectDescription(value?.response),
    stringValue(value?.reason),
    stringValue(value?.code),
    stringValue(value?.status),
  ].filter(Boolean).join(' ');
}

function errorDescription(error: unknown): string {
  if (!error) return '';
  const value = error as {
    message?: unknown;
    code?: unknown;
    reason?: unknown;
    jse_shortmsg?: unknown;
    stack?: unknown;
  };
  return [
    stringValue(value.message),
    stringValue(value.code),
    stringValue(value.reason),
    stringValue(value.jse_shortmsg),
    stringValue(value.stack),
    typeof error === 'string' ? error : '',
  ].filter(Boolean).join(' ');
}

function objectDescription(value: unknown): string {
  if (!value) return '';
  if (typeof value === 'string') return value;
  if (typeof value !== 'object') return String(value);
  const object = value as { reason?: unknown; error?: unknown; status?: unknown };
  return [
    stringValue(object.reason),
    stringValue(object.error),
    stringValue(object.status),
  ].filter(Boolean).join(' ');
}

function stringValue(value: unknown): string {
  if (value === null || value === undefined) return '';
  return typeof value === 'string' ? value : String(value);
}

function numericValue(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value !== 'string' || value.trim() === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function sleep(ms: number): Promise<void> {
  if (ms <= 0) return Promise.resolve();
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await fs.access(path);
    return true;
  } catch {
    return false;
  }
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
