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
