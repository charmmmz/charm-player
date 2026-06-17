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

test('ignores frequent Live Activity preference posts from HTTP auto logging', () => {
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/live-activity-preferences' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/live-activity-preferences?source=app' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/live-activity-hints' }), false);
});

test('ignores frequent artwork proxy requests from HTTP auto logging', () => {
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/artwork' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/artwork?url=https%3A%2F%2Fexample.com%2Fcover.jpg' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/artwork-hints' }), false);
});
