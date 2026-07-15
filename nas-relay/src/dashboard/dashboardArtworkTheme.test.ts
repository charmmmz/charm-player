import assert from 'node:assert/strict';
import test from 'node:test';

import { themeColorFromSamples } from './dashboardArtworkTheme.js';

test('dashboard artwork theme boosts a colorful cover accent for a dark player background', () => {
  const color = themeColorFromSamples([
    ...Array(20).fill({ r: 0.08, g: 0.12, b: 0.18 }),
    ...Array(4).fill({ r: 0.75, g: 0.18, b: 0.08 }),
  ]);

  assert.ok(color.r > color.g && color.r > color.b);
  assert.ok(Math.max(color.r, color.g, color.b) >= 0.6);
});

test('dashboard artwork theme keeps monochrome covers neutral', () => {
  const color = themeColorFromSamples(Array(30).fill({ r: 0.15, g: 0.15, b: 0.15 }));

  assert.equal(color.r, color.g);
  assert.equal(color.g, color.b);
  assert.ok(color.r >= 0.48 && color.r <= 0.74);
});
