import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import pino from 'pino';

import { HueAmbienceConfigStore } from './hueConfigStore.js';
import { DEFAULT_STOP_GRACE_MS, HueAmbienceService } from './hueAmbienceService.js';
import type { HueAmbienceFrame } from './hueAmbienceFrames.js';
import type { HueAmbienceRenderer } from './hueFrameRenderer.js';
import type {
  HueAmbienceRuntimeConfig,
  HueEntertainmentClient,
  HueLightClient,
  HueRGBColor,
  HueSnapshot,
} from './hueTypes.js';

test('default stop grace buffers Sonos track-change transport gaps', () => {
  assert.equal(DEFAULT_STOP_GRACE_MS, 4_000);
});

test('manual stop remains paused across snapshots until start replays the latest playback', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
      0,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => service.status().runtimeActive);

    await service.stop();
    assert.equal(service.status().runtimePaused, true);
    assert.equal(service.status().enabled, false);
    assert.equal(service.status().runtimeActive, false);

    const reloadedService = new HueAmbienceService(store, pino({ enabled: false }));
    await reloadedService.load();
    assert.equal(reloadedService.status().runtimePaused, true);
    assert.equal(reloadedService.status().enabled, false);

    service.receiveSnapshot(snapshot('/art-two.jpg'));
    await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(service.status().runtimeActive, false);

    await service.start();
    await waitFor(() => service.status().runtimeActive);
    assert.equal(service.status().runtimePaused, false);
    assert.equal(service.status().enabled, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('saving config immediately reapplies the latest playing Hue ambience snapshot', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => client.updates.length === 1);

    await service.saveConfig({
      ...config,
      toneControl: { brightness: 0.55, saturation: 0.55 },
    });
    await waitFor(() => client.updates.length === 2);

    assert.equal(service.status().runtimeActive, true);
    assert.notDeepEqual(client.updates[0]!.body, client.updates[1]!.body);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('saving dashboard mappings preserves the rest of the Hue runtime config', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const service = new HueAmbienceService(store, pino({ enabled: false }));
    await service.load();

    await service.saveMappings([{
      ...config.mappings[0]!,
      relayGroupID: '192.168.50.30',
      sonosName: 'Kitchen',
    }]);

    assert.equal(store.current?.applicationKey, 'secret-key');
    assert.equal(store.current?.bridge.id, 'bridge-1');
    assert.equal(store.current?.mappings[0]?.relayGroupID, '192.168.50.30');
    assert.equal(service.mappingConfiguration()?.mappings[0]?.sonosName, 'Kitchen');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('album art URI participates in Hue ambience track changes when metadata is empty', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      async snapshot => snapshot.albumArtUri?.includes('two')
        ? [{ r: 0, g: 0, b: 1 }]
        : [{ r: 1, g: 0, b: 0 }],
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => client.updates.length === 1);

    service.receiveSnapshot(snapshot('/art-two.jpg'));
    await waitFor(() => client.updates.length === 2);

    assert.notDeepEqual(client.updates[0]!.body, client.updates[1]!.body);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('paused playback cancels a pending Hue ambience start before it can wake lights', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const pendingPalette = deferred<HueRGBColor[]>();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => pendingPalette.promise,
      1,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => service.status().runtimeActive === true);

    service.receiveSnapshot({ ...snapshot('/art-one.jpg'), isPlaying: false });
    await waitFor(() => client.updates.length === 1);
    assert.deepEqual(client.updates[0]!.body, {
      on: { on: false },
      dynamics: { duration: 1200 },
    });

    pendingPalette.resolve([{ r: 0, g: 0, b: 1 }]);
    await new Promise(resolve => setTimeout(resolve, 20));

    assert.equal(client.updates.length, 1);
    assert.equal(service.status().runtimeActive, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('playing snapshots cancel a pending stop before lights are turned off', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
      25,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => client.updates.length === 1);

    service.receiveSnapshot({ ...snapshot('/art-one.jpg'), isPlaying: false });
    await new Promise(resolve => setTimeout(resolve, 5));
    assert.equal(client.updates.length, 1);

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await new Promise(resolve => setTimeout(resolve, 35));

    assert.equal(client.updates.length, 1);
    assert.equal(service.status().runtimeActive, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('same track resumes pending Hue ambience start before stop grace and still renders', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const pendingPalette = deferred<HueRGBColor[]>();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => pendingPalette.promise,
      50,
    );
    await service.load();

    const playing = snapshot('/art-one.jpg');
    service.receiveSnapshot(playing);
    await waitFor(() => service.status().runtimeActive === true);

    service.receiveSnapshot({ ...playing, isPlaying: false });
    await new Promise(resolve => setTimeout(resolve, 5));

    service.receiveSnapshot(playing);
    pendingPalette.resolve([{ r: 0, g: 0, b: 1 }]);

    await waitFor(() => client.updates.length === 1);
    assert.equal(service.status().runtimeActive, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('same track retries Hue ambience render after initial render failure', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const renderer = new FailingOnceHueAmbienceRenderer();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => new RecordingHueLightClient(),
      () => [{ r: 1, g: 0, b: 0 }],
      1,
      () => renderer,
    );
    await service.load();

    const playing = snapshot('/art-one.jpg');
    service.receiveSnapshot(playing);
    await waitFor(() => renderer.renderAttempts === 1);

    service.receiveSnapshot(playing);
    await waitFor(() => renderer.renderAttempts === 2);

    assert.equal(renderer.renderedFrames.length, 1);
    assert.equal(service.status().renderMode, 'clipFallback');
    assert.equal(service.status().runtimeActive, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('idle snapshots from other Sonos groups do not stop the active Hue ambience group', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
      1,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => client.updates.length === 1);

    service.receiveSnapshot({
      ...snapshot('/other-room.jpg'),
      groupId: '192.168.50.99',
      speakerName: 'Move',
      isPlaying: false,
    });
    await new Promise(resolve => setTimeout(resolve, 20));

    assert.equal(client.updates.length, 1);
    assert.equal(service.status().runtimeActive, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service keeps separate Hue ambience sessions active for different Sonos groups', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(multiGroupConfig());
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      snapshot => snapshot.groupId === '192.168.50.99'
        ? [{ r: 0, g: 0, b: 1 }]
        : [{ r: 1, g: 0, b: 0 }],
      1,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/playroom-art.jpg'));
    await waitFor(() => client.updates.length === 1);

    service.receiveSnapshot({
      ...snapshot('/home-theater-art.jpg'),
      groupId: '192.168.50.99',
      speakerName: 'Home Theater',
    });
    await waitFor(() => client.updates.length === 2);

    const status = service.status() as ReturnType<HueAmbienceService['status']> & {
      activeGroups?: Array<{
        groupId: string;
        speakerName?: string | null;
        activeTargetIds: string[];
      }>;
    };

    assert.deepEqual(client.updates.map(update => update.id), ['light-1', 'light-2']);
    assert.equal(status.runtimeActive, true);
    assert.deepEqual(
      status.activeGroups?.map(group => ({
        groupId: group.groupId,
        speakerName: group.speakerName,
        activeTargetIds: group.activeTargetIds,
      })),
      [
        { groupId: '192.168.50.25', speakerName: 'Office', activeTargetIds: ['room-1'] },
        { groupId: '192.168.50.99', speakerName: 'Home Theater', activeTargetIds: ['room-2'] },
      ],
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('stopping one Sonos group leaves other Hue ambience sessions running', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(multiGroupConfig({ stopBehavior: 'turnOff' }));
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
      1,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/playroom-art.jpg'));
    service.receiveSnapshot({
      ...snapshot('/home-theater-art.jpg'),
      groupId: '192.168.50.99',
      speakerName: 'Home Theater',
    });
    await waitFor(() => client.updates.length === 2);

    service.receiveSnapshot({ ...snapshot('/playroom-art.jpg'), isPlaying: false });
    await waitFor(() => client.updates.some(update => update.id === 'light-1' && isLightOffBody(update.body)));

    const status = service.status() as ReturnType<HueAmbienceService['status']> & {
      activeGroups?: Array<{ groupId: string; activeTargetIds: string[] }>;
    };

    assert.deepEqual(
      status.activeGroups?.map(group => ({
        groupId: group.groupId,
        activeTargetIds: group.activeTargetIds,
      })),
      [{ groupId: '192.168.50.99', activeTargetIds: ['room-2'] }],
    );
    assert.equal(status.runtimeActive, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('non-music playing snapshots do not start Hue ambience or set lastError', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
      1,
    );
    await service.load();

    service.receiveSnapshot({
      ...snapshot('/tv-art.jpg'),
      playbackSourceRaw: 'tv',
      musicAmbienceEligible: false,
    });
    await new Promise(resolve => setTimeout(resolve, 20));

    assert.equal(client.updates.length, 0);
    assert.equal(service.status().runtimeActive, false);
    assert.equal(service.status().lastError, null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('unmapped playing groups do not set lastError', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
      1,
    );
    await service.load();

    service.receiveSnapshot({
      ...snapshot('/unmapped-art.jpg'),
      groupId: '192.168.50.99',
      speakerName: 'Kitchen',
    });
    await new Promise(resolve => setTimeout(resolve, 20));

    assert.equal(client.updates.length, 0);
    assert.equal(service.status().runtimeActive, false);
    assert.equal(service.status().lastError, null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('partial initial render failure turns off pending frame lights when configured', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(twoLightConfig({ stopBehavior: 'turnOff' }));
    const client = new FailOnSecondUpdateHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }, { r: 0, g: 0, b: 1 }],
      1,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/partial-art.jpg'));
    await waitFor(() => client.updates.some(update => isLightOffBody(update.body)));

    assert.deepEqual(
      client.updates.filter(update => isLightOffBody(update.body)).map(update => update.id),
      ['light-1', 'light-2'],
    );
    assert.equal(service.status().runtimeActive, false);
    assert.match(service.status().lastError ?? '', /partial render failed/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service can pause for an external renderer without applying turn-off stop behavior', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => client.updates.length === 1);

    await service.pauseForExternalRenderer();

    assert.equal(client.updates.length, 1);
    assert.equal(service.status().runtimeActive, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service releases active renderer session without applying turn-off stop behavior', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const renderer = new ReleasableHueAmbienceRenderer();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => new RecordingHueLightClient(),
      () => [{ r: 1, g: 0, b: 0 }],
      DEFAULT_STOP_GRACE_MS,
      () => renderer,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => renderer.renderedFrames.length === 1);

    await service.pauseForExternalRenderer();

    assert.equal(renderer.releaseCount, 1);
    assert.equal(renderer.stoppedFrames.length, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service reports streaming-ready mode for entertainment targets through CLIP fallback', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...entertainmentConfig(),
      streamingApplicationId: 'streaming-app-id',
    });
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }, { r: 0, g: 0, b: 1 }],
    );
    await service.load();

    service.receiveSnapshot(snapshot('/entertainment-art.jpg'));
    await waitFor(() => client.updates.length === 1);

    const status = service.status();
    assert.equal(status.renderMode, 'streamingReady');
    assert.equal(status.entertainmentTargetActive, true);
    assert.equal(status.entertainmentMetadataComplete, true);
    assert.deepEqual(status.activeTargetIds, ['ent-1']);
    assert.ok(status.lastFrameAt);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service reports active Hue Entertainment streaming when renderer uses DTLS transport', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...entertainmentConfig(),
      streamingClientKey: '00112233445566778899aabbccddeeff',
    });
    const renderer = new FixedTransportHueAmbienceRenderer('entertainmentStreaming');
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => new RecordingHueLightClient(),
      () => [{ r: 1, g: 0, b: 0 }],
      DEFAULT_STOP_GRACE_MS,
      () => renderer,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/entertainment-art.jpg'));
    await waitFor(() => service.status().renderMode === 'entertainmentStreaming');

    assert.equal(renderer.renderedFrames.length, 1);
    assert.equal(service.status().entertainmentTargetActive, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service keeps flowing Entertainment streaming alive for single-color album palettes', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  let service: HueAmbienceService | null = null;
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...entertainmentConfig(),
      motionStyle: 'flowing',
      flowIntervalSeconds: 2,
      streamingClientKey: '00112233445566778899aabbccddeeff',
    });
    const renderer = new FixedTransportHueAmbienceRenderer('entertainmentStreaming');
    service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => new RecordingHueLightClient(),
      () => [{ r: 0.82, g: 0.08, b: 0.12 }],
      DEFAULT_STOP_GRACE_MS,
      () => renderer,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/single-color-art.jpg'));
    await waitFor(() => renderer.renderedFrames.length >= 3);

    assert.equal(renderer.renderedFrames[0]!.targets[0]!.lights[0]!.colors.length > 1, true);
    assert.notDeepEqual(
      renderer.renderedFrames[0]!.targets[0]!.lights.map(light => light.colors[0]),
      renderer.renderedFrames[2]!.targets[0]!.lights.map(light => light.colors[0]),
    );
  } finally {
    await service?.pauseForExternalRenderer();
    await rm(dir, { recursive: true, force: true });
  }
});

test('service keeps the active Entertainment renderer alive across track changes in the same area', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...entertainmentConfig(),
      streamingClientKey: '00112233445566778899aabbccddeeff',
    });
    const renderers: ReleasableHueAmbienceRenderer[] = [];
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => new RecordingHueLightClient(),
      snapshot => snapshot.albumArtUri?.includes('two')
        ? [{ r: 0, g: 0, b: 1 }]
        : [{ r: 1, g: 0, b: 0 }],
      DEFAULT_STOP_GRACE_MS,
      () => {
        const renderer = new ReleasableHueAmbienceRenderer();
        renderers.push(renderer);
        return renderer;
      },
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => renderers[0]?.renderedFrames.length === 1);

    service.receiveSnapshot(snapshot('/art-two.jpg'));
    await waitFor(() => renderers[0]?.renderedFrames.length === 2);

    assert.equal(renderers.length, 1);
    assert.equal(renderers[0]!.releaseCount, 0);
    assert.equal(renderers[0]!.stoppedFrames.length, 0);
    assert.match(service.status().lastTrackKey ?? '', /art-two/);
    assert.equal(service.status().renderMode, 'entertainmentStreaming');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service lets native Entertainment effects own flowing motion without relay frame loop', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  let service: HueAmbienceService | null = null;
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...entertainmentConfig(),
      motionStyle: 'flowing',
      flowIntervalSeconds: 1,
      streamingClientKey: '00112233445566778899aabbccddeeff',
    });
    const renderer = new FixedTransportHueAmbienceRenderer('entertainmentStreaming', true);
    service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => new RecordingHueLightClient(),
      () => [{ r: 1, g: 0, b: 0 }, { r: 0, g: 0, b: 1 }],
      DEFAULT_STOP_GRACE_MS,
      () => renderer,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/entertainment-art.jpg'));
    await waitFor(() => renderer.renderedFrames.length === 1);
    await new Promise(resolve => setTimeout(resolve, 1200));

    assert.equal(renderer.renderedFrames.length, 1);
  } finally {
    await service?.pauseForExternalRenderer();
    await rm(dir, { recursive: true, force: true });
  }
});

test('service uses configured album color fallback target for grouped playback', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const base = entertainmentConfig();
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...base,
      resources: {
        lights: [
          ...base.resources.lights,
          {
            id: 'room-light',
            name: 'Room Lamp',
            ownerID: 'room-device',
            supportsColor: true,
            supportsGradient: false,
            supportsEntertainment: true,
            function: 'decorative',
            functionMetadataResolved: true,
          },
        ],
        areas: [
          ...base.resources.areas,
          {
            id: 'room-1',
            name: 'Fallback Room',
            kind: 'room',
            childLightIDs: ['room-light'],
            childDeviceIDs: ['room-device'],
          },
        ],
      },
      mappings: [{
        ...base.mappings[0]!,
        fallbackTarget: { kind: 'room', id: 'room-1' },
      }],
      streamingClientKey: '00112233445566778899aabbccddeeff',
    });
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }, { r: 0, g: 0, b: 1 }],
    );
    await service.load();

    service.receiveSnapshot({ ...snapshot('/grouped-art.jpg'), groupMemberCount: 2 });
    await waitFor(() => client.updates.length === 1);

    assert.deepEqual(client.updates.map(update => update.id), ['room-light']);
    assert.deepEqual(service.status().activeTargetIds, ['room-1']);
    assert.equal(service.status().renderMode, 'clipFallback');
    assert.equal(service.status().entertainmentTargetActive, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service reports incomplete entertainment metadata without selecting unrelated lights', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(entertainmentConfig({ entertainmentChannels: [] }));
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }, { r: 0, g: 0, b: 1 }],
    );
    await service.load();

    service.receiveSnapshot(snapshot('/entertainment-art.jpg'));
    await waitFor(() => client.updates.length === 1);

    assert.equal(service.status().renderMode, 'streamingReady');
    assert.equal(service.status().entertainmentMetadataComplete, false);
    assert.deepEqual(client.updates.map(update => update.id), ['light-1']);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service reports Hue Entertainment streaming as occupied by another streamer', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...entertainmentConfig(),
      streamingApplicationId: 'streaming-app-id',
    });
    const entertainmentClient = new RecordingHueEntertainmentClient({
      data: [
        {
          id: 'ent-1',
          status: 'active',
          active_streamer: { rid: 'other-streamer', rtype: 'auth_v1' },
        },
      ],
    });
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      undefined,
      undefined,
      undefined,
      undefined,
      () => entertainmentClient,
    );
    await service.load();

    const status = await service.entertainmentStatus();

    assert.deepEqual(entertainmentClient.requests, ['/clip/v2/resource/entertainment_configuration']);
    assert.equal(status.configured, true);
    assert.equal(status.bridgeReachable, true);
    assert.equal(status.streaming, 'occupied');
    assert.equal(status.activeStreamer, 'other-streamer');
    assert.equal(status.activeAreaId, 'ent-1');
    assert.equal(status.lastError, null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service reports Hue Entertainment streaming as free or owned by relay', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...entertainmentConfig(),
      streamingApplicationId: 'streaming-app-id',
    });
    const entertainmentClient = new RecordingHueEntertainmentClient({
      data: [
        { id: 'ent-1', status: 'inactive', active_streamer: null },
        {
          id: 'ent-2',
          status: 'active',
          active_streamer: { rid: 'streaming-app-id', rtype: 'auth_v1' },
        },
      ],
    });
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      undefined,
      undefined,
      undefined,
      undefined,
      () => entertainmentClient,
    );
    await service.load();

    assert.equal((await service.entertainmentStatus()).streaming, 'activeByRelay');

    entertainmentClient.response = { data: [{ id: 'ent-1', status: 'inactive' }] };
    const freeStatus = await service.entertainmentStatus();

    assert.equal(freeStatus.streaming, 'free');
    assert.equal(freeStatus.activeStreamer, null);
    assert.equal(freeStatus.activeAreaId, null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service reports Hue Entertainment bridge errors without failing health', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(entertainmentConfig());
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      undefined,
      undefined,
      undefined,
      undefined,
      () => new RecordingHueEntertainmentClient({}, new Error('bridge timed out')),
    );
    await service.load();

    const status = await service.entertainmentStatus();

    assert.equal(status.configured, true);
    assert.equal(status.bridgeReachable, false);
    assert.equal(status.streaming, 'unknown');
    assert.equal(status.lastError, 'bridge timed out');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

const config: HueAmbienceRuntimeConfig = {
  enabled: true,
  bridge: { id: 'bridge-1', ipAddress: '192.168.50.216', name: 'Hue Bridge' },
  applicationKey: 'secret-key',
  resources: {
    lights: [
      {
        id: 'light-1',
        name: 'Lamp',
        supportsColor: true,
        supportsGradient: false,
        supportsEntertainment: true,
        function: 'decorative',
        functionMetadataResolved: true,
      },
    ],
    areas: [
      {
        id: 'room-1',
        name: 'Room',
        kind: 'room',
        childLightIDs: ['light-1'],
      },
    ],
  },
  mappings: [
    {
      sonosID: 'office',
      sonosName: 'Office',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'room', id: 'room-1' },
      fallbackTarget: null,
      includedLightIDs: [],
      excludedLightIDs: [],
      capability: 'basic',
    },
  ],
  groupStrategy: 'coordinatorOnly',
  stopBehavior: 'leaveCurrent',
  motionStyle: 'still',
  flowIntervalSeconds: 8,
};

function twoLightConfig(
  overrides: Partial<HueAmbienceRuntimeConfig> = {},
): HueAmbienceRuntimeConfig {
  return {
    ...config,
    ...overrides,
    resources: {
      lights: [
        ...config.resources.lights,
        {
          id: 'light-2',
          name: 'Lamp 2',
          supportsColor: true,
          supportsGradient: false,
          supportsEntertainment: true,
          function: 'decorative',
          functionMetadataResolved: true,
        },
      ],
      areas: [
        {
          ...config.resources.areas[0]!,
          childLightIDs: ['light-1', 'light-2'],
        },
      ],
    },
  };
}

function multiGroupConfig(
  overrides: Partial<HueAmbienceRuntimeConfig> = {},
): HueAmbienceRuntimeConfig {
  return {
    ...config,
    ...overrides,
    resources: {
      lights: [
        ...config.resources.lights,
        {
          id: 'light-2',
          name: 'Lamp 2',
          supportsColor: true,
          supportsGradient: false,
          supportsEntertainment: true,
          function: 'decorative',
          functionMetadataResolved: true,
        },
      ],
      areas: [
        ...config.resources.areas,
        {
          id: 'room-2',
          name: 'Home Theater',
          kind: 'room',
          childLightIDs: ['light-2'],
        },
      ],
    },
    mappings: [
      ...config.mappings,
      {
        sonosID: 'home-theater',
        sonosName: 'Home Theater',
        relayGroupID: '192.168.50.99',
        preferredTarget: { kind: 'room', id: 'room-2' },
        fallbackTarget: null,
        includedLightIDs: [],
        excludedLightIDs: [],
        capability: 'basic',
      },
    ],
  };
}

function entertainmentConfig(
  areaOverrides: Partial<HueAmbienceRuntimeConfig['resources']['areas'][number]> = {},
): HueAmbienceRuntimeConfig {
  return {
    ...config,
    resources: {
      lights: [
        {
          id: 'light-1',
          name: 'Gradient Lamp',
          supportsColor: true,
          supportsGradient: true,
          supportsEntertainment: true,
          function: 'decorative',
          functionMetadataResolved: true,
        },
        {
          id: 'light-unrelated',
          name: 'Unrelated Lamp',
          supportsColor: true,
          supportsGradient: false,
          supportsEntertainment: false,
          function: 'decorative',
          functionMetadataResolved: true,
        },
      ],
      areas: [
        {
          id: 'ent-1',
          name: 'Entertainment Area',
          kind: 'entertainmentArea',
          childLightIDs: ['light-1'],
          entertainmentChannels: [{ id: '0', lightID: 'light-1', serviceID: 'svc-1' }],
          ...areaOverrides,
        },
      ],
    },
    mappings: [
      {
        sonosID: 'office',
        sonosName: 'Office',
        relayGroupID: '192.168.50.25',
        preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
        fallbackTarget: null,
        includedLightIDs: [],
        excludedLightIDs: [],
        capability: 'liveEntertainment',
      },
    ],
  };
}

function snapshot(albumArtUri: string): HueSnapshot {
  return {
    groupId: '192.168.50.25',
    speakerName: 'Office',
    trackTitle: '',
    artist: '',
    album: '',
    albumArtUri,
    isPlaying: true,
    positionSeconds: 0,
    durationSeconds: 180,
    groupMemberCount: 1,
    sampledAt: new Date('2026-05-11T00:00:00Z'),
  };
}

class RecordingHueLightClient implements HueLightClient {
  updates: Array<{ id: string; body: unknown }> = [];

  async updateLight(id: string, body: unknown): Promise<void> {
    this.updates.push({ id, body });
  }
}

class RecordingHueEntertainmentClient implements HueEntertainmentClient {
  requests: string[] = [];

  constructor(
    public response: unknown,
    private readonly error?: Error,
  ) {}

  async get<T>(path: string): Promise<T> {
    this.requests.push(path);
    if (this.error) {
      throw this.error;
    }
    return this.response as T;
  }
}

class FailOnSecondUpdateHueLightClient extends RecordingHueLightClient {
  private attemptCount = 0;

  override async updateLight(id: string, body: unknown): Promise<void> {
    this.attemptCount += 1;
    if (this.attemptCount === 2) {
      throw new Error('partial render failed');
    }
    await super.updateLight(id, body);
  }
}

class FailingOnceHueAmbienceRenderer implements HueAmbienceRenderer {
  renderAttempts = 0;
  renderedFrames: HueAmbienceFrame[] = [];
  stoppedFrames: HueAmbienceFrame[] = [];

  async render(frame: HueAmbienceFrame): Promise<{ transport: 'clipFallback' }> {
    this.renderAttempts += 1;
    if (this.renderAttempts === 1) {
      throw new Error('render failed');
    }
    this.renderedFrames.push(frame);
    return { transport: 'clipFallback' };
  }

  async stop(frame: HueAmbienceFrame): Promise<void> {
    this.stoppedFrames.push(frame);
  }
}

class FixedTransportHueAmbienceRenderer implements HueAmbienceRenderer {
  readonly renderedFrames: HueAmbienceFrame[] = [];
  readonly stoppedFrames: HueAmbienceFrame[] = [];

  constructor(
    private readonly transport: 'clipFallback' | 'entertainmentStreaming',
    private readonly nativeEffectActive = false,
  ) {}

  async render(frame: HueAmbienceFrame): Promise<{
    transport: 'clipFallback' | 'entertainmentStreaming';
    nativeEffectActive?: boolean;
  }> {
    this.renderedFrames.push(frame);
    return {
      transport: this.transport,
      ...(this.nativeEffectActive ? { nativeEffectActive: true } : {}),
    };
  }

  async stop(frame: HueAmbienceFrame): Promise<void> {
    this.stoppedFrames.push(frame);
  }
}

class ReleasableHueAmbienceRenderer extends FixedTransportHueAmbienceRenderer {
  releaseCount = 0;

  constructor() {
    super('entertainmentStreaming');
  }

  async release(): Promise<void> {
    this.releaseCount += 1;
  }
}

function isLightOffBody(body: unknown): boolean {
  return typeof body === 'object'
    && body !== null
    && 'on' in body
    && typeof body.on === 'object'
    && body.on !== null
    && 'on' in body.on
    && body.on.on === false;
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 1000;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.equal(predicate(), true);
}

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(innerResolve => {
    resolve = innerResolve;
  });
  return { promise, resolve };
}
