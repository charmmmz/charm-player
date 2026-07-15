import assert from 'node:assert/strict';
import { test } from 'node:test';

import { RelayLogBuffer } from './relayLogs.js';

test('relay log buffer bounds entries and recursively redacts credential-shaped keys', () => {
  const logs = new RelayLogBuffer(2);
  logs.capture(30, [{ module: 'mcp', token: 'secret-a' }, 'first']);
  logs.capture(40, [{ nested: { applicationKey: 'secret-b', safe: 'value' } }, 'second']);
  logs.capture(50, [{ authorization: 'Bearer secret-c' }, 'third']);

  const recent = logs.recent(10);
  assert.equal(recent.length, 2);
  assert.equal(recent[0]?.level, 'warn');
  assert.deepEqual(recent[0]?.context, {
    nested: { applicationKey: '[redacted]', safe: 'value' },
  });
  assert.deepEqual(recent[1]?.context, { authorization: '[redacted]' });
});

test('relay log buffer returns JSON-safe copies for request-like contexts', () => {
  const logs = new RelayLogBuffer();
  const requestLike: Record<string, unknown> = {
    handler: Array.prototype.push,
    sequence: 42n,
    marker: Symbol('request'),
  };
  requestLike.self = requestLike;
  Object.defineProperty(requestLike, 'socket', {
    enumerable: true,
    get() {
      throw new Error('socket getter should not run');
    },
  });

  assert.doesNotThrow(() => logs.capture(30, [requestLike, 'request completed']));
  const recent = logs.recent();
  assert.doesNotThrow(() => JSON.stringify(recent));
  assert.deepEqual(recent[0]?.context, {
    handler: '[function push]',
    sequence: '42',
    marker: 'Symbol(request)',
    self: {
      handler: '[function push]',
      sequence: '42',
      marker: 'Symbol(request)',
      self: '[circular]',
      socket: '[getter]',
    },
    socket: '[getter]',
  });
});
