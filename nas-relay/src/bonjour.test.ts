import assert from 'node:assert/strict';
import { test } from 'node:test';

import { relayBonjourServiceConfig } from './bonjour.js';

test('relay Bonjour service advertises the Charm relay HTTP endpoint', () => {
  assert.deepEqual(relayBonjourServiceConfig(8787), {
    name: 'Charm Sonos Relay',
    type: 'charmrelay',
    protocol: 'tcp',
    port: 8787,
    txt: {
      path: '/api/health',
      version: '1',
    },
  });
});

