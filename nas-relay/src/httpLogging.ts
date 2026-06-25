export type HttpAutoLogRequest = {
  url?: string | undefined;
};

const CS2_GAMESTATE_PATH = '/api/cs2/gamestate';
const HEALTH_PATH = '/api/health';
const ARTWORK_PATH = '/api/artwork';
const LIVE_ACTIVITY_PREFERENCES_PATH = '/api/live-activity-preferences';
const DEVICE_LOGS_PATH = '/api/device-logs';
const DEVICE_LOGS_RECENT_PATH = '/api/device-logs/recent';
const DEVICE_LOGS_STREAM_PATH = '/api/device-logs/stream';

export function shouldIgnoreHttpAutoLog(req: HttpAutoLogRequest): boolean {
  const path = pathFromUrl(req.url);
  return path === CS2_GAMESTATE_PATH
    || path === HEALTH_PATH
    || path === ARTWORK_PATH
    || path === LIVE_ACTIVITY_PREFERENCES_PATH
    || path === DEVICE_LOGS_PATH
    || path === DEVICE_LOGS_RECENT_PATH
    || path === DEVICE_LOGS_STREAM_PATH;
}

function pathFromUrl(url: string | undefined): string {
  return url?.split('?', 1)[0] ?? '';
}
