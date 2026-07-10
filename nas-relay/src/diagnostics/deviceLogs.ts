import { EventEmitter } from 'node:events';

export type DeviceLogLevel = 'debug' | 'info' | 'error';

export interface DeviceLogEntryInput {
  timestamp?: string;
  category?: string;
  level?: string;
  message?: string;
  line?: string;
}

export interface DeviceLogBatchInput {
  clientId?: string;
  bundleId?: string;
  processName?: string;
  entries?: DeviceLogEntryInput[];
}

export interface DeviceLogReceiveMetadata {
  sourceIp?: string;
}

export interface DeviceLogEntry {
  id: number;
  receivedAt: string;
  clientId?: string;
  bundleId?: string;
  processName?: string;
  sourceIp?: string;
  timestamp?: string;
  category: string;
  level: DeviceLogLevel;
  message: string;
  line: string;
}

export class DeviceLogValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DeviceLogValidationError';
  }
}

export class DeviceLogService extends EventEmitter {
  private readonly recentLimit: number;
  private readonly recentEntries: DeviceLogEntry[] = [];
  private nextId = 1;

  constructor(options: { recentLimit?: number } = {}) {
    super();
    this.recentLimit = Math.max(0, Math.floor(options.recentLimit ?? 2_000));
  }

  receive(batch: DeviceLogBatchInput, metadata: DeviceLogReceiveMetadata = {}): DeviceLogEntry[] {
    if (!Array.isArray(batch?.entries) || batch.entries.length === 0) {
      throw new DeviceLogValidationError('entries must be a non-empty array');
    }

    const common = {
      clientId: optionalText(batch.clientId, 160),
      bundleId: optionalText(batch.bundleId, 160),
      processName: optionalText(batch.processName, 160),
      sourceIp: optionalText(metadata.sourceIp, 160),
    };

    const accepted = batch.entries.slice(0, 100).map(input => this.entryFrom(input, common));
    for (const entry of accepted) {
      this.remember(entry);
      this.emit('entry', entry);
    }
    return accepted;
  }

  recent(limit?: number): DeviceLogEntry[] {
    if (limit === undefined) return [...this.recentEntries];
    const bounded = Math.max(0, Math.floor(limit));
    return this.recentEntries.slice(-bounded);
  }

  private entryFrom(
    input: DeviceLogEntryInput,
    common: Pick<DeviceLogEntry, 'clientId' | 'bundleId' | 'processName' | 'sourceIp'>,
  ): DeviceLogEntry {
    const category = optionalText(input.category, 80) ?? 'Other';
    const level = normalizeLevel(input.level);
    const line = optionalText(input.line, 4_096);
    const message = optionalText(input.message, 4_096) ?? line;
    if (!message) {
      throw new DeviceLogValidationError('entry message or line is required');
    }

    return withoutUndefined({
      id: this.nextId++,
      receivedAt: new Date().toISOString(),
      ...common,
      timestamp: optionalText(input.timestamp, 80),
      category,
      level,
      message,
      line: line ?? renderedLine(category, level, message),
    });
  }

  private remember(entry: DeviceLogEntry): void {
    if (this.recentLimit === 0) return;
    this.recentEntries.push(entry);
    while (this.recentEntries.length > this.recentLimit) {
      this.recentEntries.shift();
    }
  }
}

function normalizeLevel(value: string | undefined): DeviceLogLevel {
  switch (value?.trim().toLowerCase()) {
  case 'debug':
    return 'debug';
  case 'error':
    return 'error';
  default:
    return 'info';
  }
}

function renderedLine(category: string, level: DeviceLogLevel, message: string): string {
  return `[${category}]${level === 'error' ? ' ERROR:' : ''} ${message}`;
}

function optionalText(value: string | undefined, maxLength: number): string | undefined {
  const trimmed = value?.trim();
  if (!trimmed) return undefined;
  return trimmed.length > maxLength ? trimmed.slice(0, maxLength) : trimmed;
}

function withoutUndefined<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined),
  ) as T;
}
