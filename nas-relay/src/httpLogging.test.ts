import assert from 'node:assert/strict';
import { test } from 'node:test';

import { shouldIgnoreHttpAutoLog } from './httpLogging.js';

test('ignores noisy health checks but keeps other HTTP auto logs enabled', () => {
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/health' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/health?etag=1' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/unknown' }), false);
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

test('ignores frequent sync and registration endpoints from HTTP auto logging', () => {
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/register-activity' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/register-push-to-start' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/hue-ambience/status' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/hue-ambience/config' }), true);
  assert.equal(shouldIgnoreHttpAutoLog({ url: '/api/live-activity-command' }), false);
});
