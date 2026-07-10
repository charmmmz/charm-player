import assert from 'node:assert/strict';
import { test } from 'node:test';

import { expandPaletteForMotion, rotatePalette, stablePaletteForTrack } from './huePalette.js';

test('stable track palette is deterministic and bounded', () => {
  const first = stablePaletteForTrack('Midnight City', 'M83', 'Hurry Up');
  const second = stablePaletteForTrack('Midnight City', 'M83', 'Hurry Up');

  assert.deepEqual(first, second);
  assert.equal(first.length, 5);
  assert.ok(first.every(color => color.r >= 0 && color.r <= 1));
  assert.ok(first.every(color => color.g >= 0 && color.g <= 1));
  assert.ok(first.every(color => color.b >= 0 && color.b <= 1));
});

test('stable track palette changes between tracks', () => {
  assert.notDeepEqual(
    stablePaletteForTrack('Midnight City', 'M83', 'Hurry Up'),
    stablePaletteForTrack('Breathe', 'The Prodigy', 'The Fat of the Land'),
  );
});

test('motion palette expands a single saturated album color without changing hue family wildly', () => {
  const palette = expandPaletteForMotion([{ r: 0.82, g: 0.08, b: 0.12 }]);

  assert.ok(palette.length >= 3);
  assert.deepEqual(palette[0], { r: 0.82, g: 0.08, b: 0.12 });
  assert.ok(palette.every(color => color.r > color.g && color.r > color.b));
});

test('motion palette keeps neutral single-color artwork neutral', () => {
  const palette = expandPaletteForMotion([{ r: 0.42, g: 0.42, b: 0.42 }]);

  assert.ok(palette.length >= 3);
  assert.ok(palette.every(color =>
    Math.abs(color.r - color.g) < 0.02
    && Math.abs(color.g - color.b) < 0.02,
  ));
});

test('palette rotation interpolates fractional offsets for smooth streaming frames', () => {
  const palette = rotatePalette([
    { r: 1, g: 0, b: 0 },
    { r: 0, g: 0, b: 1 },
  ], 0.5);

  assert.deepEqual(palette[0], { r: 0.5, g: 0, b: 0.5 });
  assert.deepEqual(palette[1], { r: 0.5, g: 0, b: 0.5 });
});
