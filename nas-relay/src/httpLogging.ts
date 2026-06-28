export type HttpAutoLogRequest = {
  url?: string | undefined;
};

const HEALTH_PATH = '/api/health';
const ARTWORK_PATH = '/api/artwork';
const HUE_AMBIENCE_CONFIG_PATH = '/api/hue-ambience/config';
const HUE_AMBIENCE_STATUS_PATH = '/api/hue-ambience/status';
const LIVE_ACTIVITY_PREFERENCES_PATH = '/api/live-activity-preferences';
const REGISTER_ACTIVITY_PATH = '/api/register-activity';
const REGISTER_PUSH_TO_START_PATH = '/api/register-push-to-start';
const DEVICE_LOGS_PATH = '/api/device-logs';
const DEVICE_LOGS_RECENT_PATH = '/api/device-logs/recent';
const DEVICE_LOGS_STREAM_PATH = '/api/device-logs/stream';

export function shouldIgnoreHttpAutoLog(req: HttpAutoLogRequest): boolean {
  const path = pathFromUrl(req.url);
  return path === HEALTH_PATH
    || path === ARTWORK_PATH
    || path === HUE_AMBIENCE_CONFIG_PATH
    || path === HUE_AMBIENCE_STATUS_PATH
    || path === LIVE_ACTIVITY_PREFERENCES_PATH
    || path === REGISTER_ACTIVITY_PATH
    || path === REGISTER_PUSH_TO_START_PATH
    || path === DEVICE_LOGS_PATH
    || path === DEVICE_LOGS_RECENT_PATH
    || path === DEVICE_LOGS_STREAM_PATH;
}

function pathFromUrl(url: string | undefined): string {
  return url?.split('?', 1)[0] ?? '';
}
