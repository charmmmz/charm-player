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
const MAX_CONTEXT_DEPTH = 8;
const MAX_CONTEXT_KEYS = 100;
const MAX_ARRAY_ITEMS = 100;

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
    const context = contexts.length > 0 ? mergeRecords(contexts) : undefined;
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
      context: entry.context ? redactRecord(entry.context) : undefined,
    }));
  }
}

function redactRecord(value: Record<string, unknown>): Record<string, unknown> {
  return redactObject(value, new WeakSet<object>(), 0);
}

function redactValue(value: unknown, seen: WeakSet<object>, depth: number): unknown {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number') return Number.isFinite(value) ? value : String(value);
  if (typeof value === 'bigint') return value.toString();
  if (typeof value === 'symbol') return String(value);
  if (typeof value === 'function') return `[function ${value.name || 'anonymous'}]`;
  if (typeof value === 'undefined') return null;
  if (value instanceof Error) {
    return { name: value.name, message: value.message };
  }
  if (value instanceof Date) return Number.isNaN(value.valueOf()) ? 'Invalid Date' : value.toISOString();
  if (Buffer.isBuffer(value)) return `[binary ${value.length} bytes]`;
  if (ArrayBuffer.isView(value)) return `[binary ${value.byteLength} bytes]`;
  if (depth >= MAX_CONTEXT_DEPTH) return '[max-depth]';
  if (Array.isArray(value)) {
    if (seen.has(value)) return '[circular]';
    seen.add(value);
    const entries = value.slice(0, MAX_ARRAY_ITEMS).map(entry => redactValue(entry, seen, depth + 1));
    if (value.length > MAX_ARRAY_ITEMS) entries.push(`[truncated ${value.length - MAX_ARRAY_ITEMS} items]`);
    return entries;
  }
  if (!isRecord(value)) return value;
  if (seen.has(value)) return '[circular]';
  return redactObject(value, seen, depth);
}

function redactObject(
  value: Record<string, unknown>,
  seen: WeakSet<object>,
  depth: number,
): Record<string, unknown> {
  if (seen.has(value)) return { circular: '[circular]' };
  seen.add(value);

  const keys = safeKeys(value);
  const output: Record<string, unknown> = {};
  for (const key of keys.slice(0, MAX_CONTEXT_KEYS)) {
    if (SENSITIVE_KEY.test(key)) {
      output[key] = '[redacted]';
      continue;
    }
    output[key] = redactValue(safeOwnValue(value, key), seen, depth + 1);
  }
  if (keys.length > MAX_CONTEXT_KEYS) {
    output._truncated = `${keys.length - MAX_CONTEXT_KEYS} keys`;
  }
  return output;
}

function mergeRecords(values: Record<string, unknown>[]): Record<string, unknown> {
  const merged: Record<string, unknown> = {};
  for (const value of values) {
    for (const key of safeKeys(value)) {
      merged[key] = SENSITIVE_KEY.test(key) ? '[redacted]' : safeOwnValue(value, key);
    }
  }
  return merged;
}

function safeKeys(value: Record<string, unknown>): string[] {
  try {
    return Object.keys(value);
  } catch {
    return [];
  }
}

function safeOwnValue(value: Record<string, unknown>, key: string): unknown {
  try {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor) return Reflect.get(value, key);
    return 'value' in descriptor ? descriptor.value : '[getter]';
  } catch {
    return '[unavailable]';
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
