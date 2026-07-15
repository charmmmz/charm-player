export type RelayLogLevel = 'trace' | 'debug' | 'info' | 'warn' | 'error' | 'fatal';

export interface RelayLogEntry {
  id: number;
  timestamp: string;
  level: RelayLogLevel;
  message: string;
  context?: Record<string, unknown>;
}

const LEVELS: Record<number, RelayLogLevel> = {
  10: 'trace',
  20: 'debug',
  30: 'info',
  40: 'warn',
  50: 'error',
  60: 'fatal',
};

const SENSITIVE_KEY = /(authorization|password|passwd|secret|token|applicationkey|clientkey|privatekey)/i;

/** Small in-memory ring buffer used by the LAN dashboard. It intentionally
 * captures Pino's structured arguments before transport formatting and
 * redacts credentials recursively before retaining anything. */
export class RelayLogBuffer {
  private readonly entries: RelayLogEntry[] = [];
  private nextId = 1;

  constructor(private readonly limit = 1_000) {}

  capture(levelNumber: number, args: unknown[]): void {
    if (this.limit <= 0) return;

    const contexts = args.filter((value): value is Record<string, unknown> => isRecord(value));
    const context = contexts.length > 0 ? Object.assign({}, ...contexts) : undefined;
    const message = [...args].reverse().find(value => typeof value === 'string');
    const entry: RelayLogEntry = {
      id: this.nextId++,
      timestamp: new Date().toISOString(),
      level: LEVELS[levelNumber] ?? 'info',
      message: typeof message === 'string' ? message : 'relay event',
    };
    if (context) entry.context = redactRecord(context);

    this.entries.push(entry);
    while (this.entries.length > this.limit) this.entries.shift();
  }

  recent(limit = 200): RelayLogEntry[] {
    const bounded = Math.max(0, Math.min(this.limit, Math.floor(limit)));
    return this.entries.slice(-bounded).map(entry => ({
      ...entry,
      context: entry.context ? structuredClone(entry.context) : undefined,
    }));
  }
}

function redactRecord(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [
    key,
    SENSITIVE_KEY.test(key) ? '[redacted]' : redactValue(entry, new WeakSet<object>()),
  ]));
}

function redactValue(value: unknown, seen: WeakSet<object>): unknown {
  if (value instanceof Error) {
    return { name: value.name, message: value.message };
  }
  if (Array.isArray(value)) {
    if (seen.has(value)) return '[circular]';
    seen.add(value);
    return value.map(entry => redactValue(entry, seen));
  }
  if (!isRecord(value)) return value;
  if (seen.has(value)) return '[circular]';
  seen.add(value);
  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [
    key,
    SENSITIVE_KEY.test(key) ? '[redacted]' : redactValue(entry, seen),
  ]));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
