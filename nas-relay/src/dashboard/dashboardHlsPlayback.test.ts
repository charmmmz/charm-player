import assert from 'node:assert/strict';
import { test } from 'node:test';

import { selectAnimatedArtworkPlayback } from '../../public/dashboard/hlsPlayback.js';

test('dashboard prefers hls.js when Chromium also claims native HLS support', () => {
  assert.equal(selectAnimatedArtworkPlayback(true, true), 'hls-js');
});

test('dashboard falls back to native HLS when hls.js is unavailable', () => {
  assert.equal(selectAnimatedArtworkPlayback(false, true), 'native');
});

test('dashboard rejects HLS when neither playback path is supported', () => {
  assert.equal(selectAnimatedArtworkPlayback(false, false), 'unsupported');
});
