import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { test } from 'node:test';
import { SonosEvents } from '@svrooij/sonos';
import pino from 'pino';

import {
  albumArtUriFromMetadata,
  isMusicAmbienceEligibleForSnapshot,
  localPlaybackQualityFromPlaybackMetadata,
  playbackSourceFromTrackUri,
  SonosBridge,
  trackMetadataFromMetadata,
} from './sonos.js';

test('album art extraction accepts parsed Sonos Track metadata objects', () => {
  assert.equal(
    albumArtUriFromMetadata({ AlbumArtUri: '/getaa?s=1&u=x-sonos-http%3atrack' }),
    '/getaa?s=1&u=x-sonos-http%3atrack',
  );
});

test('album art extraction accepts raw DIDL strings', () => {
  assert.equal(
    albumArtUriFromMetadata(
      '<DIDL-Lite><item><upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-http%3atrack</upnp:albumArtURI></item></DIDL-Lite>',
    ),
    '/getaa?s=1&u=x-sonos-http%3atrack',
  );
});

test('track metadata extraction accepts raw DIDL strings', () => {
  assert.deepEqual(
    trackMetadataFromMetadata(
      '<DIDL-Lite><item><dc:title>Blue Train</dc:title><dc:creator>John Coltrane</dc:creator><upnp:album>Blue Train</upnp:album><upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-http%3atrack</upnp:albumArtURI></item></DIDL-Lite>',
    ),
    {
      title: 'Blue Train',
      artist: 'John Coltrane',
      album: 'Blue Train',
      albumArtUri: '/getaa?s=1&u=x-sonos-http%3atrack',
    },
  );
});

test('track metadata extraction uses Sonos radio stream content for the current song', () => {
  assert.deepEqual(
    trackMetadataFromMetadata(
      '<DIDL-Lite><item><dc:title>Apple Music Chill</dc:title><dc:creator>Unknown</dc:creator><upnp:album></upnp:album><r:streamContent>TYPE=SNG|TITLE thursday drive|ARTIST Middle Kids|ALBUM Faith Crisis Pt 1</r:streamContent><upnp:albumArtURI>/getaa?s=1&amp;u=x-sonosapi-radio%3astation</upnp:albumArtURI></item></DIDL-Lite>',
    ),
    {
      title: 'thursday drive',
      artist: 'Middle Kids',
      album: 'Faith Crisis Pt 1',
      albumArtUri: '/getaa?s=1&u=x-sonosapi-radio%3astation',
    },
  );
});

test('track metadata extraction accepts parsed Sonos Track metadata objects', () => {
  assert.deepEqual(
    trackMetadataFromMetadata({
      Title: 'Teardrop',
      Artist: 'Massive Attack',
      Album: 'Mezzanine',
      AlbumArtUri: '/getaa?s=1&u=x-sonos-http%3ateardrop',
    }),
    {
      title: 'Teardrop',
      artist: 'Massive Attack',
      album: 'Mezzanine',
      albumArtUri: '/getaa?s=1&u=x-sonos-http%3ateardrop',
    },
  );
});

test('playback source extraction identifies TV input as non-music ambience', () => {
  assert.equal(playbackSourceFromTrackUri('x-sonos-htastream:RINCON_123:spdif'), 'tv');
  assert.equal(isMusicAmbienceEligibleForSnapshot({
    trackTitle: 'TV',
    artist: 'Live audio',
    album: '',
    albumArtUri: null,
    playbackSourceRaw: 'tv',
  }), false);
});

test('music ambience eligibility still allows music metadata without a known source', () => {
  assert.equal(isMusicAmbienceEligibleForSnapshot({
    trackTitle: 'Blue Train',
    artist: 'John Coltrane',
    album: 'Blue Train',
    albumArtUri: null,
    playbackSourceRaw: null,
  }), true);
});

test('bridge refreshes snapshots when the Sonos library emits real event names', () => {
  const bridge = testBridge();
  const events = new EventEmitter();
  const refreshedDevices: string[] = [];
  const device = { Name: 'Office', Events: events };

  (bridge as unknown as { refreshSnapshot: (device: unknown) => Promise<void> }).refreshSnapshot = async refreshed => {
    refreshedDevices.push((refreshed as { Name: string }).Name);
  };
  (bridge as unknown as { attachDeviceListeners: (device: unknown) => void }).attachDeviceListeners(device);

  events.emit(SonosEvents.AVTransport, {});
  events.emit(SonosEvents.CurrentTrackUri, 'x-rincon-queue:RINCON_1#0');
  events.emit(SonosEvents.CurrentTrackMetadata, { Title: 'Blue Train' });
  events.emit(SonosEvents.CurrentTransportState, 'PLAYING');
  events.emit(SonosEvents.CurrentTransportStateSimple, 'PLAYING');
  events.emit(SonosEvents.PlaybackStopped);
  events.emit(SonosEvents.GroupName, 'Office');

  assert.deepEqual(refreshedDevices, [
    'Office',
    'Office',
    'Office',
    'Office',
    'Office',
    'Office',
    'Office',
  ]);
});

test('bridge ignores stale snapshot refreshes that complete after a newer refresh', async () => {
  const bridge = testBridge();
  const staleTransport = deferred<{ CurrentTransportState: string }>();
  const stalePosition = deferred<Record<string, string>>();
  let transportCalls = 0;
  let positionCalls = 0;
  const snapshots: Array<{ isPlaying: boolean; title: string }> = [];
  const device = {
    Host: '192.168.50.25',
    Name: 'Office',
    Uuid: 'office',
    AVTransportService: {
      GetTransportInfo: () => {
        transportCalls += 1;
        return transportCalls === 1
          ? staleTransport.promise
          : Promise.resolve({ CurrentTransportState: 'PAUSED_PLAYBACK' });
      },
      GetPositionInfo: () => {
        positionCalls += 1;
        return positionCalls === 1
          ? Promise.resolve(positionInfo('Paused Song'))
          : stalePosition.promise;
      },
    },
  };

  bridge.on('change', snapshot => {
    snapshots.push({ isPlaying: snapshot.isPlaying, title: snapshot.trackTitle });
  });

  const firstRefresh = (bridge as unknown as { refreshSnapshot: (device: unknown) => Promise<void> }).refreshSnapshot(device);
  const secondRefresh = (bridge as unknown as { refreshSnapshot: (device: unknown) => Promise<void> }).refreshSnapshot(device);
  await secondRefresh;

  staleTransport.resolve({ CurrentTransportState: 'PLAYING' });
  stalePosition.resolve(positionInfo('Stale Playing Song'));
  await firstRefresh;

  assert.deepEqual(snapshots, [{ isPlaying: false, title: 'Paused Song' }]);
  assert.deepEqual(bridge.current('192.168.50.25')?.trackTitle, 'Paused Song');
});

test('bridge suppresses transient paused snapshots immediately after skip commands', async () => {
  const bridge = testBridge();
  let transportState = 'PLAYING';
  let position = positionInfo('Blue Train');
  const snapshots: Array<{ isPlaying: boolean; title: string }> = [];
  const device = playbackDevice({
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'rincon-playroom',
    Next: async () => {
      transportState = 'PAUSED_PLAYBACK';
      position = {
        ...positionInfo('Momentary Transition'),
        RelTime: '00:00:00',
      };
    },
  }, position);
  device.Coordinator = device;
  device.AVTransportService = {
    GetTransportInfo: () => Promise.resolve({ CurrentTransportState: transportState }),
    GetPositionInfo: () => Promise.resolve(position),
  };
  (bridge as unknown as { manager: { devices: unknown[] } }).manager.devices = [device];

  bridge.on('change', snapshot => {
    snapshots.push({ isPlaying: snapshot.isPlaying, title: snapshot.trackTitle });
  });

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<void>;
  }).refreshSnapshot(device);
  await bridge.next('192.168.50.25');

  assert.deepEqual(snapshots, [{ isPlaying: true, title: 'Blue Train' }]);
  assert.equal(bridge.current('192.168.50.25')?.isPlaying, true);
  assert.equal(bridge.current('192.168.50.25')?.trackTitle, 'Blue Train');
});

test('bridge suppresses transient paused snapshots during automatic track transitions', async () => {
  const bridge = testBridge();
  let transportState = 'PLAYING';
  let position = positionInfo('Blue Train');
  const snapshots: Array<{ isPlaying: boolean; title: string }> = [];
  const device = playbackDevice({
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'rincon-playroom',
  }, position);
  device.Coordinator = device;
  device.AVTransportService = {
    GetTransportInfo: () => Promise.resolve({ CurrentTransportState: transportState }),
    GetPositionInfo: () => Promise.resolve(position),
  };

  bridge.on('change', snapshot => {
    snapshots.push({ isPlaying: snapshot.isPlaying, title: snapshot.trackTitle });
  });

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<boolean>;
  }).refreshSnapshot(device);

  transportState = 'PAUSED_PLAYBACK';
  position = {
    ...positionInfo('Momentary Transition'),
    RelTime: '00:00:00',
  };

  const emitted = await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<boolean>;
  }).refreshSnapshot(device);

  assert.equal(emitted, false);
  assert.deepEqual(snapshots, [{ isPlaying: true, title: 'Blue Train' }]);
  assert.equal(bridge.current('192.168.50.25')?.isPlaying, true);
  assert.equal(bridge.current('192.168.50.25')?.trackTitle, 'Blue Train');
});

test('bridge still emits real pauses for the current track', async () => {
  const bridge = testBridge();
  let transportState = 'PLAYING';
  let position = {
    ...positionInfo('Blue Train'),
    RelTime: '00:00:12',
  };
  const snapshots: Array<{ isPlaying: boolean; title: string }> = [];
  const device = playbackDevice({
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'rincon-playroom',
  }, position);
  device.Coordinator = device;
  device.AVTransportService = {
    GetTransportInfo: () => Promise.resolve({ CurrentTransportState: transportState }),
    GetPositionInfo: () => Promise.resolve(position),
  };

  bridge.on('change', snapshot => {
    snapshots.push({ isPlaying: snapshot.isPlaying, title: snapshot.trackTitle });
  });

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<boolean>;
  }).refreshSnapshot(device);

  transportState = 'PAUSED_PLAYBACK';
  position = {
    ...positionInfo('Blue Train'),
    RelTime: '00:00:12',
  };

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<boolean>;
  }).refreshSnapshot(device);

  assert.deepEqual(snapshots, [
    { isPlaying: true, title: 'Blue Train' },
    { isPlaying: false, title: 'Blue Train' },
  ]);
  assert.equal(bridge.current('192.168.50.25')?.isPlaying, false);
});

test('bridge labels periodic snapshot refreshes for Live Activity calibration pushes', async () => {
  const bridge = testBridge();
  let trigger: string | undefined;
  const device = {
    Host: '192.168.50.25',
    Name: 'Office',
    Uuid: 'office',
    AVTransportService: {
      GetTransportInfo: () => Promise.resolve({ CurrentTransportState: 'PLAYING' }),
      GetPositionInfo: () => Promise.resolve(positionInfo('Blue Train')),
    },
  };

  bridge.on('change', (_snapshot, context) => {
    trigger = context?.trigger;
  });

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown, trigger: 'periodic-refresh') => Promise<void>;
  }).refreshSnapshot(device, 'periodic-refresh');

  assert.equal(trigger, 'periodic-refresh');
});

test('bridge keeps previous live radio song when Sonos temporarily reports only generic track metadata', async () => {
  const bridge = testBridge();
  const positions = [
    liveRadioPositionInfo('TYPE=SNG|TITLE Vanille fraise|ARTIST L’Impératrice|ALBUM Single'),
    liveRadioPositionInfo(''),
  ];
  const device = {
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'rincon-playroom',
    CurrentTrack: {
      Title: 'Single',
      Artist: 'Apple Music',
      Album: 'Single',
    },
    AVTransportService: {
      GetTransportInfo: () => Promise.resolve({ CurrentTransportState: 'PLAYING' }),
      GetPositionInfo: () => Promise.resolve(positions.shift() ?? positions[0]),
    },
  };

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<void>;
  }).refreshSnapshot(device);
  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<void>;
  }).refreshSnapshot(device);

  const snapshot = bridge.current('192.168.50.25');
  assert.equal(snapshot?.trackTitle, 'Vanille fraise');
  assert.equal(snapshot?.artist, 'L’Impératrice');
  assert.equal(snapshot?.album, 'Single');
});

test('bridge snapshots audio quality from Sonos track metadata', async () => {
  const bridge = testBridge();
  const device = playbackDevice({
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'rincon-playroom',
  }, losslessPositionInfo());

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<void>;
  }).refreshSnapshot(device);

  const snapshot = bridge.current('192.168.50.25');
  assert.equal(snapshot?.audioQualityLabel, 'Lossless');
});

test('local Control API playback metadata maps lossless and immersive quality labels', () => {
  assert.deepEqual(localPlaybackQualityFromPlaybackMetadata({
    service: { name: 'Apple Music' },
    track: {
      quality: {
        bitDepth: 24,
        sampleRate: 48_000,
        lossless: true,
        immersive: false,
      },
    },
  }), {
    label: 'Hi-Res Lossless',
    serviceName: 'Apple Music',
    lossless: true,
    immersive: false,
    bitDepth: 24,
    sampleRate: 48_000,
  });

  assert.deepEqual(localPlaybackQualityFromPlaybackMetadata({
    service: { name: 'Apple Music' },
    track: {
      quality: {
        bitDepth: 24,
        sampleRate: 48_000,
        lossless: false,
        immersive: true,
      },
    },
  })?.label, 'Dolby Atmos');
});

test('bridge prefers local Control API playback quality over generic track metadata', async () => {
  const calls: Array<{ host: string; playerId: string }> = [];
  const bridge = new SonosBridge(pino({ enabled: false }), {
    localControl: {
      playbackQuality: async ({ host, playerId }) => {
        calls.push({ host, playerId });
        return {
          label: 'Hi-Res Lossless',
          serviceName: 'Apple Music',
          lossless: true,
          immersive: false,
          bitDepth: 24,
          sampleRate: 48_000,
        };
      },
    },
  });
  const device = playbackDevice({
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'RINCON_804AF2200FD601400',
  }, genericAppleMusicPositionInfo());

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<void>;
  }).refreshSnapshot(device);

  assert.deepEqual(calls, [{
    host: '192.168.50.25',
    playerId: 'RINCON_804AF2200FD601400',
  }]);
  const snapshot = bridge.current('192.168.50.25');
  assert.equal(snapshot?.audioQualityLabel, 'Hi-Res Lossless');
});

test('local Control API playback quality maps immersive tracks to Dolby Atmos', async () => {
  const bridge = new SonosBridge(pino({ enabled: false }), {
    localControl: {
      playbackQuality: async () => ({
        label: 'Dolby Atmos',
        serviceName: 'Apple Music',
        lossless: false,
        immersive: true,
        bitDepth: 24,
        sampleRate: 48_000,
      }),
    },
  });
  const device = playbackDevice({
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'RINCON_804AF2200FD601400',
  }, genericAppleMusicPositionInfo());

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<void>;
  }).refreshSnapshot(device);

  const snapshot = bridge.current('192.168.50.25');
  assert.equal(snapshot?.audioQualityLabel, 'Dolby Atmos');
});

test('bridge logs local Control API quality diagnostics when no label is available', async () => {
  const { logger, lines } = captureLogger();
  const bridge = new SonosBridge(logger, {
    localControl: {
      playbackQuality: async () => null,
    },
  });
  const device = playbackDevice({
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'RINCON_804AF2200FD601400',
  }, genericAppleMusicPositionInfo());

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<void>;
  }).refreshSnapshot(device);

  assert.equal(lines.some(line =>
    line.includes('"action":"local-control-quality"')
    && line.includes('"status":"missing"')
    && line.includes('"host":"192.168.50.25"')
  ), true);
});

test('bridge snapshots grouped playback with the coordinator visible member count', async () => {
  const bridge = testBridge();
  const coordinator = playbackDevice({
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'rincon-playroom',
  });
  coordinator.Coordinator = coordinator;
  const member = playbackDevice({
    Host: '192.168.50.26',
    Name: 'Kitchen',
    Uuid: 'rincon-kitchen',
    Coordinator: coordinator,
  });
  (bridge as unknown as { manager: { devices: unknown[] } }).manager.devices = [coordinator, member];

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<void>;
  }).refreshSnapshot(coordinator);

  const snapshot = bridge.current('192.168.50.25');
  assert.equal(snapshot?.speakerName, 'Playroom');
  assert.equal(snapshot?.groupMemberCount, 2);
});

test('bridge prefers parsed ZoneGroup members over stale coordinator relationships', async () => {
  const bridge = testBridge();
  const coordinator = playbackDevice({
    Host: '192.168.50.25',
    Name: 'Playroom',
    Uuid: 'rincon-playroom',
  });
  coordinator.Coordinator = coordinator;

  const kitchen = playbackDevice({
    Host: '192.168.50.26',
    Name: 'Kitchen',
    Uuid: 'rincon-kitchen',
    Coordinator: coordinator,
  });
  const move = playbackDevice({
    Host: '192.168.50.27',
    Name: 'Move',
    Uuid: 'rincon-move',
    Coordinator: coordinator,
  });

  (bridge as unknown as { manager: { devices: unknown[]; zoneService: unknown } }).manager.devices = [
    coordinator,
    kitchen,
    move,
  ];
  (bridge as unknown as { manager: { zoneService: unknown } }).manager.zoneService = {
    GetParsedZoneGroupState: () => Promise.resolve([
      zoneGroup(coordinator),
      zoneGroup(kitchen),
      zoneGroup(move),
    ]),
  };

  await (bridge as unknown as {
    refreshSnapshot: (device: unknown) => Promise<void>;
  }).refreshSnapshot(coordinator);

  const snapshot = bridge.current('192.168.50.25');
  assert.equal(snapshot?.speakerName, 'Playroom');
  assert.equal(snapshot?.groupMemberCount, 1);
});

function positionInfo(title: string): Record<string, string> {
  return {
    RelTime: '00:00:00',
    TrackDuration: '00:03:00',
    TrackURI: 'x-rincon-queue:RINCON_1#0',
    TrackMetaData: `<DIDL-Lite><item><dc:title>${title}</dc:title><dc:creator>Artist</dc:creator><upnp:album>Album</upnp:album><upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-http%3atrack</upnp:albumArtURI></item></DIDL-Lite>`,
  };
}

function liveRadioPositionInfo(streamContent: string): Record<string, string> {
  return {
    RelTime: '00:00:00',
    TrackDuration: '00:00:00',
    TrackURI: 'x-sonosapi-hls:hls%3ara.1740614260?sid=204&flags=8232&sn=2',
    TrackMetaData: '<DIDL-Lite><item>'
      + '<res protocolInfo="sonos.com-http:*:application/x-mpegURL:*">'
      + 'x-sonosapi-hls:hls%3ara.1740614260?sid=204&amp;flags=8232&amp;sn=2'
      + '</res>'
      + `<r:streamContent>${streamContent}</r:streamContent>`
      + '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
      + '</item></DIDL-Lite>',
  };
}

function losslessPositionInfo(): Record<string, string> {
  return {
    ...positionInfo('Blue Train'),
    TrackMetaData: '<DIDL-Lite><item>'
      + '<dc:title>Blue Train</dc:title>'
      + '<dc:creator>John Coltrane</dc:creator>'
      + '<upnp:album>Blue Train</upnp:album>'
      + '<upnp:albumArtURI>/getaa?s=1&amp;u=x-file-cifs%3atrack</upnp:albumArtURI>'
      + '<res protocolInfo="http-get:*:audio/flac:*" sampleFrequency="44100" bitsPerSample="16" nrAudioChannels="2">'
      + 'http://192.168.50.25:1400/track.flac'
      + '</res>'
      + '</item></DIDL-Lite>',
  };
}

function genericAppleMusicPositionInfo(): Record<string, string> {
  return {
    ...positionInfo('Call On Me'),
    TrackURI: 'x-sonos-http:song%3a1839352407.mp4?sid=204&flags=8232&sn=2',
    TrackMetaData: '<DIDL-Lite><item>'
      + '<dc:title>Call On Me</dc:title>'
      + '<dc:creator>Daniel Caesar</dc:creator>'
      + '<upnp:album>Son of Spergy</upnp:album>'
      + '<upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-http%3asong%253a1839352407.mp4%3fsid%3d204%26flags%3d8232%26sn%3d2</upnp:albumArtURI>'
      + '<res protocolInfo="sonos.com-http:*:audio/mp4:*">'
      + 'x-sonos-http:song%3a1839352407.mp4?sid=204&amp;flags=8232&amp;sn=2'
      + '</res>'
      + '</item></DIDL-Lite>',
  };
}

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(innerResolve => {
    resolve = innerResolve;
  });
  return { promise, resolve };
}

function playbackDevice(
  fields: Record<string, unknown>,
  position: Record<string, string> = positionInfo('Blue Train'),
): Record<string, unknown> {
  return {
    AVTransportService: {
      GetTransportInfo: () => Promise.resolve({ CurrentTransportState: 'PLAYING' }),
      GetPositionInfo: () => Promise.resolve(position),
    },
    ...fields,
  };
}

function testBridge(): SonosBridge {
  return new SonosBridge(pino({ enabled: false }), { localControl: null });
}

function captureLogger(): { logger: pino.Logger; lines: string[] } {
  const lines: string[] = [];
  const destination = {
    write: (line: string) => {
      lines.push(line);
    },
  };
  return { logger: pino({ level: 'info' }, destination), lines };
}

function zoneGroup(device: Record<string, unknown>) {
  return {
    groupId: String(device.Uuid),
    name: String(device.Name),
    coordinator: zoneMember(device),
    members: [zoneMember(device)],
  };
}

function zoneMember(device: Record<string, unknown>) {
  return {
    host: String(device.Host),
    port: 1400,
    uuid: String(device.Uuid),
    name: String(device.Name),
    Invisible: false,
  };
}
