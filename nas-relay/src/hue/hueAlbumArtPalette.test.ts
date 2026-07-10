import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PNG } from 'pngjs';

import { extractPaletteFromColors, paletteForSnapshot, paletteFromAlbumArtBuffer } from './hueAlbumArtPalette.js';
import type { HueRGBColor } from './hueTypes.js';

const blue: HueRGBColor = { r: 0.02, g: 0.08, b: 0.92 };
const yellow: HueRGBColor = { r: 0.96, g: 0.82, b: 0.05 };

test('album art palette extraction keeps distinct useful cover colors', () => {
  const palette = extractPaletteFromColors([
    ...Array(18).fill(blue),
    ...Array(12).fill(yellow),
    ...Array(5).fill({ r: 0.02, g: 0.02, b: 0.02 }),
  ]);

  assert.ok(palette.length >= 2);
  assert.ok(palette.some(isModeratedBlue));
  assert.ok(palette.some(isModeratedYellow));
});

test('album art palette moderates overly saturated cover colors for ambience', () => {
  const palette = extractPaletteFromColors(Array(20).fill({ r: 1, g: 0, b: 0 }));

  assert.equal(palette.length, 1);
  const red = palette[0]!;
  assert.ok(red.r > red.g);
  assert.ok(red.r > red.b);
  assert.ok(red.r < 0.8);
  assert.ok(red.g > 0.1);
  assert.ok(red.b > 0.1);
});

test('dark album art limits bright neon accents for ambience', () => {
  const palette = extractPaletteFromColors([
    ...Array(70).fill({ r: 0.03, g: 0.03, b: 0.04 }),
    ...Array(12).fill({ r: 1, g: 0, b: 0 }),
    ...Array(10).fill({ r: 0, g: 0.9, b: 1 }),
    ...Array(9).fill({ r: 1, g: 0.8, b: 0 }),
    ...Array(8).fill({ r: 1, g: 0, b: 0.9 }),
    ...Array(7).fill({ r: 0, g: 1, b: 0.2 }),
  ]);

  assert.ok(palette.length > 0);
  assert.ok(palette.length <= 4);
  assert.ok(palette.every(color => Math.max(color.r, color.g, color.b) <= 0.58));
  assert.ok(palette.some(color => color.r > color.g && color.r > color.b));
  assert.ok(palette.some(color => color.b > color.r || color.g > color.r));
});

test('dark album art keeps neon accents saturated instead of pastel', () => {
  const palette = extractPaletteFromColors([
    ...Array(72).fill({ r: 0.02, g: 0.02, b: 0.03 }),
    ...Array(14).fill({ r: 1, g: 0, b: 0 }),
    ...Array(13).fill({ r: 0, g: 0.9, b: 1 }),
    ...Array(10).fill({ r: 1, g: 0.78, b: 0 }),
  ]);

  assert.ok(palette.length >= 2, `palette: ${JSON.stringify(palette)}`);
  assert.ok(
    palette.every(color => Math.max(color.r, color.g, color.b) <= 0.62),
    `palette: ${JSON.stringify(palette)}`,
  );
  assert.ok(
    palette.every(color => saturation(color) >= 0.65),
    `palette: ${JSON.stringify(palette)}`,
  );

  const red = palette.find(color => color.r > color.g && color.r > color.b);
  assert.ok(red, `palette: ${JSON.stringify(palette)}`);
  assert.ok(red.g < 0.12 && red.b < 0.12, `red: ${JSON.stringify(red)}`);

  const cool = palette.find(color => color.b > color.r && color.g > color.r);
  assert.ok(cool, `palette: ${JSON.stringify(palette)}`);
  assert.ok(cool.r < 0.12, `cool: ${JSON.stringify(cool)}`);
});

test('snapshot palette prefers fetched album art colors over stable metadata colors', async () => {
  const palette = await paletteForSnapshot(
    {
      groupId: '192.168.50.25',
      speakerName: 'Office',
      trackTitle: 'Any Song',
      artist: 'Any Artist',
      album: 'Any Album',
      albumArtUri: 'http://192.168.50.25:1400/getaa?s=1',
      isPlaying: true,
      positionSeconds: 0,
      durationSeconds: 180,
      groupMemberCount: 1,
      sampledAt: new Date('2026-05-11T00:00:00Z'),
    },
    {
      fetchAlbumArt: async () => Buffer.from('fake-art'),
      extractPalette: async () => [blue, yellow],
    },
  );

  assert.equal(palette.length, 2);
  assert.ok(isModeratedBlue(palette[0]!));
  assert.ok(isModeratedYellow(palette[1]!));
});

test('album art palette extraction decodes PNG artwork bytes', () => {
  const palette = paletteFromAlbumArtBuffer(makeStripedPng([blue, yellow]));

  assert.ok(palette.some(isModeratedBlue));
  assert.ok(palette.some(isModeratedYellow));
});

test('black and white album art falls back to a neutral cover color', () => {
  const palette = paletteFromAlbumArtBuffer(makeStripedPng([
    { r: 0.08, g: 0.08, b: 0.08 },
    { r: 0.82, g: 0.82, b: 0.82 },
  ]));

  assert.equal(palette.length, 1);
  const neutral = palette[0]!;
  assert.ok(Math.abs(neutral.r - neutral.g) < 0.02);
  assert.ok(Math.abs(neutral.g - neutral.b) < 0.02);
  assert.ok(neutral.r >= 0.25);
  assert.ok(neutral.r <= 0.8);
});

function makeStripedPng(colors: HueRGBColor[]): Buffer {
  const width = colors.length * 8;
  const height = 8;
  const png = new PNG({ width, height });

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const color = colors[Math.floor(x / 8)]!;
      const index = (y * width + x) * 4;
      png.data[index] = Math.round(color.r * 255);
      png.data[index + 1] = Math.round(color.g * 255);
      png.data[index + 2] = Math.round(color.b * 255);
      png.data[index + 3] = 255;
    }
  }

  return PNG.sync.write(png);
}

function isModeratedBlue(color: HueRGBColor): boolean {
  return color.b > color.r
    && color.b > color.g
    && color.b > 0.5
    && color.b < 0.75
    && color.r > 0.1;
}

function isModeratedYellow(color: HueRGBColor): boolean {
  return color.r > color.b
    && color.g > color.b
    && color.r > 0.55
    && color.r < 0.75
    && color.b > 0.1;
}

function saturation(color: HueRGBColor): number {
  const maxComponent = Math.max(color.r, color.g, color.b);
  const minComponent = Math.min(color.r, color.g, color.b);
  if (maxComponent <= 0) return 0;
  return (maxComponent - minComponent) / maxComponent;
}
