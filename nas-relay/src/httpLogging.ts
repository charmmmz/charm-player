export type HttpAutoLogRequest = {
  url?: string | undefined;
};

const CS2_GAMESTATE_PATH = '/api/cs2/gamestate';
const HEALTH_PATH = '/api/health';

export function shouldIgnoreHttpAutoLog(req: HttpAutoLogRequest): boolean {
  const path = pathFromUrl(req.url);
  return path === CS2_GAMESTATE_PATH || path === HEALTH_PATH;
}

function pathFromUrl(url: string | undefined): string {
  return url?.split('?', 1)[0] ?? '';
}
