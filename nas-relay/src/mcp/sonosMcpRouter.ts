import { timingSafeEqual } from 'node:crypto';
import { Router, type NextFunction, type Request, type Response } from 'express';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import type { Logger } from 'pino';
import * as z from 'zod/v4';

import type { SonosGroupSnapshot } from '../types.js';
import { snapshotJson } from '../sonos/relaySnapshotJson.js';

export interface SonosMcpController {
  allSnapshots(): SonosGroupSnapshot[];
  current(groupId: string): SonosGroupSnapshot | undefined;
  pullFreshSnapshot(groupId: string): Promise<SonosGroupSnapshot | undefined>;
  play(groupId: string): Promise<void>;
  pause(groupId: string): Promise<void>;
  next(groupId: string): Promise<void>;
  previous(groupId: string): Promise<void>;
  setGroupVolume(groupId: string, volume: number): Promise<void>;
  setSoundbarNightMode(groupId: string, enabled: boolean): Promise<void>;
  setSoundbarSpeechEnhancementRawLevel(groupId: string, rawLevel: number): Promise<void>;
}

export interface SonosMcpOptions {
  token: string;
  allowedOrigins: string[];
  maxVolume: number;
}

export function sonosMcpOptionsFromEnv(env: NodeJS.ProcessEnv = process.env): SonosMcpOptions {
  return {
    token: env.MCP_API_TOKEN?.trim() ?? '',
    allowedOrigins: (env.MCP_ALLOWED_ORIGINS ?? '')
      .split(',')
      .map(value => value.trim())
      .filter(Boolean),
    maxVolume: parseMaxVolume(env.MCP_MAX_VOLUME),
  };
}

export function createSonosMcpRouter(
  sonos: SonosMcpController,
  log: Logger,
  options: SonosMcpOptions = sonosMcpOptionsFromEnv(),
): Router {
  const router = Router();
  const mcpLog = log.child({ module: 'mcp' });
  const checkOrigin = createOriginMiddleware(options.allowedOrigins);

  router.options('/', checkOrigin, (_req, res) => {
    res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, Mcp-Protocol-Version');
    res.setHeader('Access-Control-Max-Age', '600');
    res.status(204).end();
  });

  router.post('/', checkOrigin, createBearerAuthMiddleware(options.token), async (req, res) => {
    const server = createSonosMcpServer(sonos, mcpLog, options.maxVolume);
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });

    res.on('close', () => {
      void transport.close();
      void server.close();
    });

    try {
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (error) {
      mcpLog.error({ err: error, remoteAddress: req.ip }, 'MCP request failed');
      if (!res.headersSent) {
        res.status(500).json(mcpHttpError(-32603, 'Internal MCP server error'));
      }
    }
  });

  router.get('/', checkOrigin, createBearerAuthMiddleware(options.token), (_req, res) => {
    res.status(405).json(mcpHttpError(-32000, 'This LAN MCP endpoint uses stateless POST requests.'));
  });

  router.delete('/', checkOrigin, createBearerAuthMiddleware(options.token), (_req, res) => {
    res.status(405).json(mcpHttpError(-32000, 'This LAN MCP endpoint does not create sessions.'));
  });

  return router;
}

export function resolveMcpTarget(
  target: string,
  snapshots: SonosGroupSnapshot[],
): SonosGroupSnapshot {
  const normalizedTarget = normalizeTarget(target);
  if (!normalizedTarget) throw new Error('target is required');

  const idMatch = snapshots.find(snapshot => normalizeTarget(snapshot.groupId) === normalizedTarget);
  if (idMatch) return idMatch;

  const exactNameMatches = snapshots.filter(
    snapshot => normalizeTarget(snapshot.speakerName) === normalizedTarget,
  );
  if (exactNameMatches.length === 1) return exactNameMatches[0]!;
  if (exactNameMatches.length > 1) throw ambiguousTarget(target, exactNameMatches);

  const partialNameMatches = snapshots.filter(snapshot =>
    normalizeTarget(snapshot.speakerName).includes(normalizedTarget),
  );
  if (partialNameMatches.length === 1) return partialNameMatches[0]!;
  if (partialNameMatches.length > 1) throw ambiguousTarget(target, partialNameMatches);

  const available = snapshots.map(snapshot => snapshot.speakerName).sort().join(', ');
  throw new Error(
    available
      ? `Unknown Sonos target "${target}". Available rooms: ${available}`
      : `Unknown Sonos target "${target}". No Sonos groups are currently discovered.`,
  );
}

function createSonosMcpServer(
  sonos: SonosMcpController,
  log: Logger,
  maxVolume: number,
): McpServer {
  const server = new McpServer(
    { name: 'charm-sonos-lan', version: '0.1.0' },
    {
      instructions:
        'Control the user\'s Sonos system on their trusted LAN. Call sonos_list_groups before using a room for the first time. Prefer room names as target values; groupId is also accepted. Never invent room names or groupIds.',
    },
  );

  const target = z.string().trim().min(1).describe(
    'Sonos room name returned by sonos_list_groups, or its coordinator groupId.',
  );
  const readOnly = {
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false,
  } as const;
  const control = {
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: false,
  } as const;

  server.registerTool(
    'sonos_list_groups',
    {
      title: 'List Sonos groups',
      description: 'List currently discovered Sonos groups and their cached playback state.',
      annotations: readOnly,
    },
    async () => {
      const groups = sonos.allSnapshots().map(snapshotJson);
      return toolResult({ ok: true, groups });
    },
  );

  server.registerTool(
    'sonos_get_state',
    {
      title: 'Get Sonos playback state',
      description: 'Refresh and return playback state for one Sonos group.',
      inputSchema: { target },
      annotations: readOnly,
    },
    async ({ target: requestedTarget }) => {
      const resolved = resolveMcpTarget(requestedTarget, sonos.allSnapshots());
      audit(log, 'sonos_get_state', requestedTarget, resolved.groupId);
      const state = await sonos.pullFreshSnapshot(resolved.groupId);
      if (!state) throw new Error(`Sonos group ${resolved.groupId} disappeared during refresh.`);
      return toolResult({ ok: true, state: snapshotJson(state) });
    },
  );

  registerTargetControl(server, sonos, log, {
    name: 'sonos_play',
    title: 'Play Sonos group',
    description: 'Start or resume playback for one Sonos group.',
    target,
    action: groupId => sonos.play(groupId),
    annotations: control,
  });
  registerTargetControl(server, sonos, log, {
    name: 'sonos_pause',
    title: 'Pause Sonos group',
    description: 'Pause playback for one Sonos group.',
    target,
    action: groupId => sonos.pause(groupId),
    annotations: { ...control, idempotentHint: true },
  });
  registerTargetControl(server, sonos, log, {
    name: 'sonos_next',
    title: 'Skip to next Sonos track',
    description: 'Skip to the next track for one Sonos group.',
    target,
    action: groupId => sonos.next(groupId),
    annotations: control,
  });
  registerTargetControl(server, sonos, log, {
    name: 'sonos_previous',
    title: 'Return to previous Sonos track',
    description: 'Return to the previous track for one Sonos group.',
    target,
    action: groupId => sonos.previous(groupId),
    annotations: control,
  });

  server.registerTool(
    'sonos_set_volume',
    {
      title: 'Set Sonos group volume',
      description: `Set group volume from 0 to ${maxVolume}. The relay rejects higher values.`,
      inputSchema: {
        target,
        volume: z.number().int().min(0).max(maxVolume),
      },
      annotations: { ...control, idempotentHint: true },
    },
    async ({ target: requestedTarget, volume }) => {
      const resolved = resolveMcpTarget(requestedTarget, sonos.allSnapshots());
      audit(log, 'sonos_set_volume', requestedTarget, resolved.groupId, { volume });
      await sonos.setGroupVolume(resolved.groupId, volume);
      return currentStateResult(sonos, resolved.groupId);
    },
  );

  server.registerTool(
    'sonos_set_night_mode',
    {
      title: 'Set Sonos soundbar night mode',
      description: 'Enable or disable Night Sound for a Sonos home-theater group.',
      inputSchema: { target, enabled: z.boolean() },
      annotations: { ...control, idempotentHint: true },
    },
    async ({ target: requestedTarget, enabled }) => {
      const resolved = resolveMcpTarget(requestedTarget, sonos.allSnapshots());
      audit(log, 'sonos_set_night_mode', requestedTarget, resolved.groupId, { enabled });
      await sonos.setSoundbarNightMode(resolved.groupId, enabled);
      return currentStateResult(sonos, resolved.groupId);
    },
  );

  server.registerTool(
    'sonos_set_speech_enhancement',
    {
      title: 'Set Sonos speech enhancement',
      description: 'Set speech enhancement to 0 (off) or level 1 through 4 for a Sonos home-theater group.',
      inputSchema: { target, level: z.number().int().min(0).max(4) },
      annotations: { ...control, idempotentHint: true },
    },
    async ({ target: requestedTarget, level }) => {
      const resolved = resolveMcpTarget(requestedTarget, sonos.allSnapshots());
      audit(log, 'sonos_set_speech_enhancement', requestedTarget, resolved.groupId, { level });
      await sonos.setSoundbarSpeechEnhancementRawLevel(resolved.groupId, level);
      return currentStateResult(sonos, resolved.groupId);
    },
  );

  server.registerResource(
    'sonos-groups',
    'sonos://groups',
    {
      title: 'Current Sonos groups',
      description: 'Cached Sonos group and playback state from the LAN relay.',
      mimeType: 'application/json',
    },
    async uri => ({
      contents: [
        {
          uri: uri.href,
          mimeType: 'application/json',
          text: JSON.stringify({ groups: sonos.allSnapshots().map(snapshotJson) }),
        },
      ],
    }),
  );

  return server;
}

function registerTargetControl(
  server: McpServer,
  sonos: SonosMcpController,
  log: Logger,
  input: {
    name: string;
    title: string;
    description: string;
    target: z.ZodString;
    action: (groupId: string) => Promise<void>;
    annotations: {
      readOnlyHint: boolean;
      destructiveHint: boolean;
      idempotentHint: boolean;
      openWorldHint: boolean;
    };
  },
): void {
  server.registerTool(
    input.name,
    {
      title: input.title,
      description: input.description,
      inputSchema: { target: input.target },
      annotations: input.annotations,
    },
    async ({ target: requestedTarget }) => {
      const resolved = resolveMcpTarget(requestedTarget, sonos.allSnapshots());
      audit(log, input.name, requestedTarget, resolved.groupId);
      await input.action(resolved.groupId);
      return currentStateResult(sonos, resolved.groupId);
    },
  );
}

function currentStateResult(sonos: SonosMcpController, groupId: string) {
  const state = sonos.current(groupId);
  return toolResult({ ok: true, state: state ? snapshotJson(state) : null });
}

function toolResult(payload: Record<string, unknown>) {
  return {
    content: [{ type: 'text' as const, text: JSON.stringify(payload) }],
    structuredContent: payload,
  };
}

function audit(
  log: Logger,
  tool: string,
  requestedTarget: string,
  groupId: string,
  details: Record<string, unknown> = {},
): void {
  log.info({ source: 'mcp', tool, requestedTarget, groupId, ...details }, 'MCP Sonos tool call');
}

function createOriginMiddleware(allowedOrigins: string[]) {
  const allowed = new Set(allowedOrigins);
  return (req: Request, res: Response, next: NextFunction): void => {
    const origin = req.header('Origin');
    if (!origin) {
      next();
      return;
    }
    if (!allowed.has(origin)) {
      res.status(403).json(mcpHttpError(-32001, 'Origin is not allowed for this LAN MCP endpoint.'));
      return;
    }
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Expose-Headers', 'Mcp-Session-Id');
    res.setHeader('Vary', 'Origin');
    next();
  };
}

function createBearerAuthMiddleware(expectedToken: string) {
  return (req: Request, res: Response, next: NextFunction): void => {
    if (!expectedToken) {
      res.status(503).json(mcpHttpError(-32002, 'MCP is disabled because MCP_API_TOKEN is not configured.'));
      return;
    }
    const authorization = req.header('Authorization') ?? '';
    const sentToken = authorization.startsWith('Bearer ')
      ? authorization.slice('Bearer '.length).trim()
      : '';
    if (!tokensEqual(sentToken, expectedToken)) {
      res.setHeader('WWW-Authenticate', 'Bearer');
      res.status(401).json(mcpHttpError(-32001, 'A valid MCP bearer token is required.'));
      return;
    }
    next();
  };
}

function tokensEqual(sent: string, expected: string): boolean {
  const sentBuffer = Buffer.from(sent);
  const expectedBuffer = Buffer.from(expected);
  return sentBuffer.length === expectedBuffer.length && timingSafeEqual(sentBuffer, expectedBuffer);
}

function parseMaxVolume(raw: string | undefined): number {
  const parsed = Number(raw ?? 70);
  if (!Number.isFinite(parsed)) return 70;
  return Math.max(0, Math.min(100, Math.round(parsed)));
}

function normalizeTarget(value: string): string {
  return value.trim().toLocaleLowerCase('en-US');
}

function ambiguousTarget(target: string, matches: SonosGroupSnapshot[]): Error {
  return new Error(
    `Ambiguous Sonos target "${target}". Matching rooms: ${matches
      .map(snapshot => `${snapshot.speakerName} (${snapshot.groupId})`)
      .join(', ')}`,
  );
}

function mcpHttpError(code: number, message: string): Record<string, unknown> {
  return { jsonrpc: '2.0', error: { code, message }, id: null };
}
