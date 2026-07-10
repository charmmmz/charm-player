import assert from 'node:assert/strict';
import { test } from 'node:test';

import { relayBonjourServiceConfig } from './bonjour.js';

test('relay Bonjour service advertises the Charm relay HTTP endpoint', () => {
  assert.deepEqual(relayBonjourServiceConfig(8787, 'IMPRESSIVE-NAS'), {
    name: 'Charm Sonos Relay',
    type: 'charmrelay',
    protocol: 'tcp',
    host: 'IMPRESSIVE-NAS.local',
    port: 8787,
    txt: {
      path: '/api/health',
      version: '1',
    },
  });
});

test('relay Bonjour service keeps fully-qualified local hostnames stable', () => {
  assert.equal(relayBonjourServiceConfig(8787, 'IMPRESSIVE-NAS.local').host, 'IMPRESSIVE-NAS.local');
  assert.equal(relayBonjourServiceConfig(8787, 'IMPRESSIVE-NAS.').host, 'IMPRESSIVE-NAS.local');
});
