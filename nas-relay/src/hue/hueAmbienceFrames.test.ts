import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  buildHueAmbienceFrame,
  entertainmentMetadataComplete,
} from './hueAmbienceFrames.js';
import { rgbToXy } from './huePalette.js';
import type {
  HueAmbienceMotionStyle,
  HueAreaResource,
  HueLightResource,
  HueRGBColor,
  HueResolvedAmbienceTarget,
  HueSnapshot,
} from './hueTypes.js';

const palette: HueRGBColor[] = [
  { r: 1, g: 0, b: 0 },
  { r: 0, g: 1, b: 0 },
  { r: 0, g: 0, b: 1 },
];
const now = new Date('2026-05-12T02:30:00Z');

function target(area: Partial<HueAreaResource> = {}): HueResolvedAmbienceTarget {
  return {
    area: {
      id: 'ent-1',
      name: 'PC Entertainment Area',
      kind: 'entertainmentArea',
      childLightIDs: ['gradient-strip', 'desk-lamp'],
      entertainmentChannels: [
        { id: 'channel-gradient', lightID: 'gradient-strip' },
        { id: 'channel-desk', lightID: 'desk-lamp' },
      ],
      ...area,
    },
    mapping: {
      sonosID: 'playroom',
      sonosName: 'Playroom',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
      fallbackTarget: null,
      includedLightIDs: [],
      excludedLightIDs: [],
      capability: 'liveEntertainment',
    },
    lights: [
      {
        id: 'gradient-strip',
        name: 'Gradient Strip',
        supportsColor: true,
        supportsGradient: true,
        supportsEntertainment: true,
        function: 'decorative',
        functionMetadataResolved: true,
      },
      {
        id: 'desk-lamp',
        name: 'Desk Lamp',
        supportsColor: true,
        supportsGradient: false,
        supportsEntertainment: true,
        function: 'decorative',
        functionMetadataResolved: true,
      },
    ],
  };
}

function roomTarget(): HueResolvedAmbienceTarget {
  return target({
    id: 'room-1',
    name: 'Playroom',
    kind: 'room',
    childLightIDs: ['gradient-strip', 'desk-lamp'],
    entertainmentChannels: undefined,
  });
}

function snapshot(overrides: Partial<HueSnapshot> = {}): HueSnapshot {
  return {
    groupId: '192.168.50.25',
    speakerName: 'Playroom',
    trackTitle: 'Spiral',
    artist: 'Vangelis',
    album: 'Direct',
    isPlaying: true,
    positionSeconds: 0,
    durationSeconds: 180,
    groupMemberCount: 1,
    sampledAt: new Date('2026-05-12T00:00:00Z'),
    ...overrides,
  };
}

test('frame engine distributes a 3-color album palette across two entertainment lights', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    snapshot: snapshot(),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.equal(frame.mode, 'streamingReady');
  assert.equal(frame.transitionSeconds, 4);
  assert.equal(frame.createdAt, now);
  assert.equal(frame.metadataComplete, true);
  assert.equal(frame.targets[0]!.area.id, 'ent-1');
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.light.id), [
    'gradient-strip',
    'desk-lamp',
  ]);
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.colors[0]), [
    palette[0],
    palette[1],
  ]);
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.channelID), [
    'channel-gradient',
    'channel-desk',
  ]);
});

test('frame engine uses entertainment channel position for spatial palette ordering', () => {
  const frame = buildHueAmbienceFrame({
    targets: [
      {
        ...target({
          entertainmentChannels: [
            { id: 'channel-gradient', lightID: 'gradient-strip', position: { x: 1, y: 0, z: 0 } },
            { id: 'channel-desk', lightID: 'desk-lamp', position: { x: 0, y: 0, z: 0 } },
          ],
        }),
      },
    ],
    snapshot: snapshot(),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.deepEqual(frame.targets[0]!.lights.map(light => light.light.id), [
    'gradient-strip',
    'desk-lamp',
  ]);
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.colors[0]), [
    palette[1],
    palette[0],
  ]);
});

test('frame engine advances palette phase from playback progress', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    snapshot: snapshot({ positionSeconds: 120, durationSeconds: 180 }),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.deepEqual(frame.targets[0]!.lights.map(light => light.colors[0]), [
    palette[2],
    palette[0],
  ]);
});

test('frame engine keeps multiple colors for gradients and one color for basic lights', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    snapshot: snapshot(),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.equal(frame.targets[0]!.lights[0]!.light.supportsGradient, true);
  assert.equal(frame.targets[0]!.lights[1]!.light.supportsGradient, false);
  assert.deepEqual(frame.targets[0]!.lights[0]!.colors, palette);
  assert.deepEqual(frame.targets[0]!.lights[1]!.colors, [palette[1]]);
});

test('flowing frame engine renders gradient lights as deep spatial segments', () => {
  const frame = spatialFrame('flowing');
  const gradient = frame.targets[0]!.lights.find(light => light.light.id === 'wall-gradient');
  assert.ok(gradient);

  assert.equal(gradient.colors.length, 3);
  assert.notDeepEqual(gradient.colors[0], gradient.colors[1]);
  assert.notDeepEqual(gradient.colors[1], gradient.colors[2]);
  assert.ok(
    gradient.colors.every(color => maxComponent(color) <= 0.46),
    `gradient colors too bright: ${JSON.stringify(gradient.colors)}`,
  );
  assert.ok(
    gradient.colors.every(color => saturation(color) <= 0.52),
    `gradient colors too saturated: ${JSON.stringify(gradient.colors)}`,
  );
});

test('still frame engine lets decorative overhead lights participate as colored accents', () => {
  const frame = spatialFrame('still');
  const overhead = frame.targets[0]!.lights.find(light => light.light.id === 'main-light');
  const accent = frame.targets[0]!.lights.find(light => light.light.id === 'floor-light');
  assert.ok(overhead);
  assert.ok(accent);

  assert.equal(overhead.colors.length, 1);
  assert.equal(accent.colors.length, 1);
  assert.ok(
    maxComponent(overhead.colors[0]!) >= 0.24,
    `decorative overhead should receive visible color: ${JSON.stringify(overhead.colors[0])}`,
  );
  assert.ok(
    saturation(overhead.colors[0]!) >= 0.35,
    `decorative overhead should stay chromatic: ${JSON.stringify(overhead.colors[0])}`,
  );
});

test('decorative overhead lights stay chromatic for pale album palettes instead of drifting to white', () => {
  const frame = buildHueAmbienceFrame({
    targets: [spatialRoomTarget()],
    snapshot: snapshot({ positionSeconds: 0, durationSeconds: 180 }),
    palette: [{ r: 0.95, g: 0.89, b: 0.81 }],
    reason: 'steady',
    phase: 0,
    transitionSeconds: 8,
    motionStyle: 'flowing',
    now,
  });
  const overhead = frame.targets[0]!.lights.find(light => light.light.id === 'main-light');
  assert.ok(overhead);

  const color = overhead.colors[0]!;
  const xy = rgbToXy(color);
  const distanceFromWhite = Math.hypot(xy.x - 0.3127, xy.y - 0.329);
  assert.ok(maxComponent(color) <= 0.44, `decorative overhead too bright: ${JSON.stringify(color)}`);
  assert.ok(
    distanceFromWhite >= 0.06,
    `decorative overhead too close to white: ${JSON.stringify({ color, xy, distanceFromWhite })}`,
  );
});

test('tone control dims and desaturates spatial frames without allowing harsh output', () => {
  const defaultFrame = spatialFrame('flowing');
  const dimmedFrame = buildHueAmbienceFrame({
    targets: [spatialRoomTarget()],
    snapshot: snapshot({ positionSeconds: 42, durationSeconds: 180 }),
    palette: [
      { r: 1, g: 0, b: 0 },
      { r: 0, g: 0.92, b: 1 },
      { r: 1, g: 0.82, b: 0 },
    ],
    reason: 'steady',
    phase: 0.5,
    transitionSeconds: 8,
    motionStyle: 'flowing',
    toneControl: { brightness: 0.55, saturation: 0.55 },
    now,
  });
  const pushedFrame = buildHueAmbienceFrame({
    targets: [spatialRoomTarget()],
    snapshot: snapshot({ positionSeconds: 42, durationSeconds: 180 }),
    palette: [
      { r: 1, g: 0, b: 0 },
      { r: 0, g: 0.92, b: 1 },
      { r: 1, g: 0.82, b: 0 },
    ],
    reason: 'steady',
    phase: 0.5,
    transitionSeconds: 8,
    motionStyle: 'flowing',
    toneControl: { brightness: 9, saturation: 9 },
    now,
  });

  const defaultAccent = defaultFrame.targets[0]!.lights.find(light => light.light.id === 'floor-light')!.colors[0]!;
  const dimmedAccent = dimmedFrame.targets[0]!.lights.find(light => light.light.id === 'floor-light')!.colors[0]!;
  const pushedAccent = pushedFrame.targets[0]!.lights.find(light => light.light.id === 'floor-light')!.colors[0]!;

  assert.ok(maxComponent(dimmedAccent) < maxComponent(defaultAccent));
  assert.ok(saturation(dimmedAccent) < saturation(defaultAccent));
  assert.ok(maxComponent(pushedAccent) <= 0.53, `pushed output too bright: ${JSON.stringify(pushedAccent)}`);
  assert.ok(saturation(pushedAccent) <= 0.54, `pushed output too saturated: ${JSON.stringify(pushedAccent)}`);
});

test('frame engine emits one entertainment frame per gradient channel', () => {
  const frame = buildHueAmbienceFrame({
    targets: [
      {
        ...target({
          childLightIDs: ['gradient-strip'],
          entertainmentChannels: [
            { id: '0', lightID: 'gradient-strip', position: { x: -1, y: 0, z: 0 } },
            { id: '1', lightID: 'gradient-strip', position: { x: 0, y: 0, z: 0 } },
            { id: '2', lightID: 'gradient-strip', position: { x: 1, y: 0, z: 0 } },
          ],
        }),
        lights: [target().lights[0]!],
      },
    ],
    snapshot: snapshot(),
    palette: [{ r: 0.05, g: 0.18, b: 0.44 }],
    reason: 'steady',
    phase: 0,
    transitionSeconds: 0.28,
    now,
  });

  assert.deepEqual(frame.targets[0]!.lights.map(light => light.channelID), ['0', '1', '2']);
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.light.id), [
    'gradient-strip',
    'gradient-strip',
    'gradient-strip',
  ]);
  assert.deepEqual(
    frame.targets[0]!.lights.map(light => light.colors[0]),
    [
      { r: 0.05, g: 0.18, b: 0.44 },
      { r: 0.05, g: 0.18, b: 0.44 },
      { r: 0.05, g: 0.18, b: 0.44 },
    ],
  );
});

test('frame engine metadata ignores non-entertainment targets when entertainment targets are complete', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target(), roomTarget()],
    snapshot: snapshot(),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.equal(frame.mode, 'streamingReady');
  assert.equal(frame.metadataComplete, true);
});

test('frame engine metadata is false when no entertainment targets are present', () => {
  const frame = buildHueAmbienceFrame({
    targets: [roomTarget()],
    snapshot: snapshot(),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.equal(frame.mode, 'clipFallback');
  assert.equal(frame.metadataComplete, false);
});

test('frame engine falls back to white when palette is empty', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    snapshot: snapshot(),
    palette: [],
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.deepEqual(frame.targets[0]!.lights[0]!.colors, [{ r: 1, g: 1, b: 1 }]);
  assert.deepEqual(frame.targets[0]!.lights[1]!.colors, [{ r: 1, g: 1, b: 1 }]);
});

test('frame engine normalizes exact track-end progress offset inside palette range', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    snapshot: snapshot({ positionSeconds: 180, durationSeconds: 180 }),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.equal(frame.progressOffset, 0);
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.colors[0]), [
    palette[0],
    palette[1],
  ]);
});

test('entertainment metadata requires complete channel metadata for entertainment targets only', () => {
  assert.equal(entertainmentMetadataComplete(target().area), true);
  assert.equal(entertainmentMetadataComplete(target({
    entertainmentChannels: [{ id: 'channel-gradient', lightID: 'gradient-strip' }],
  }).area), false);
  assert.equal(entertainmentMetadataComplete(target({ kind: 'room' }).area), false);
});

function spatialFrame(motionStyle: HueAmbienceMotionStyle) {
  return buildHueAmbienceFrame({
    targets: [spatialRoomTarget()],
    snapshot: snapshot({ positionSeconds: 42, durationSeconds: 180 }),
    palette: [
      { r: 1, g: 0, b: 0 },
      { r: 0, g: 0.92, b: 1 },
      { r: 1, g: 0.82, b: 0 },
    ],
    reason: 'steady',
    phase: 0.5,
    transitionSeconds: 8,
    motionStyle,
    now,
  });
}

function spatialRoomTarget(): HueResolvedAmbienceTarget {
  const wallGradient = spatialLight({
    id: 'wall-gradient',
    name: '洗墙灯',
    supportsGradient: true,
  });
  const floorLight = spatialLight({
    id: 'floor-light',
    name: '落地灯',
  });
  const mainLight = spatialLight({
    id: 'main-light',
    name: '主灯-1',
  });

  return {
    area: {
      id: 'room-1',
      name: 'Home Theater',
      kind: 'room',
      childLightIDs: ['wall-gradient', 'floor-light', 'main-light'],
      entertainmentChannels: [
        { id: '0', lightID: 'wall-gradient', position: { x: -1, y: 0, z: -0.4 } },
        { id: '1', lightID: 'wall-gradient', position: { x: 0, y: 0, z: 0 } },
        { id: '2', lightID: 'wall-gradient', position: { x: 1, y: 0, z: 0.4 } },
        { id: '3', lightID: 'floor-light', position: { x: -0.8, y: -0.2, z: 0.6 } },
        { id: '4', lightID: 'main-light', position: { x: 0, y: 1, z: 1 } },
      ],
    },
    mapping: {
      sonosID: 'home-theater',
      sonosName: 'Home Theater',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'room', id: 'room-1' },
      fallbackTarget: null,
      includedLightIDs: [],
      excludedLightIDs: [],
      capability: 'gradientReady',
    },
    lights: [wallGradient, floorLight, mainLight],
  };
}

function spatialLight(overrides: Partial<HueLightResource> & Pick<HueLightResource, 'id' | 'name'>): HueLightResource {
  return {
    supportsColor: true,
    supportsGradient: false,
    supportsEntertainment: true,
    function: 'decorative',
    functionMetadataResolved: true,
    ...overrides,
  };
}

function maxComponent(color: HueRGBColor): number {
  return Math.max(color.r, color.g, color.b);
}

function saturation(color: HueRGBColor): number {
  const max = maxComponent(color);
  const min = Math.min(color.r, color.g, color.b);
  if (max <= 0) return 0;
  return (max - min) / max;
}
