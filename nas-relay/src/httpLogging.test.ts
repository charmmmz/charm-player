import assert from 'node:assert/strict';
import { test } from 'node:test';

import { shouldIgnoreHttpAutoLog } from './httpLogging.js';

test('ignores high-frequency CS2 gamestate posts from HTTP auto logging', () => {
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/cs2/gamestate' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/cs2/gamestate?tick=1' }), true);
});

test('ignores noisy health checks but keeps other HTTP auto logs enabled', () => {
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/health' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/health?etag=1' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/cs2/status' }), false);
  assert.equal(shouldIgnoreHttpAutoLog({ url: undefined }), false);
});
