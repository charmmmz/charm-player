import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  buildAppleMusicArtistStationPlayback,
  buildCurrentTrackResourceMetadata,
  buildFavoriteCreateElements,
  favoriteForCurrentURI,
  favoritePlaybackSource,
  favoriteUsesDirectTransport,
  parseSonosFavorites,
  resolveAppleMusicArtistId,
  serviceDescriptorForCurrentURI,
  sonosQueueAlbumKey,
  sonosQueueView,
} from './sonosLibrary.js';

const favoriteResult = '&lt;DIDL-Lite&gt;'
  + '&lt;item id=&quot;FV:2/104&quot; parentID=&quot;FV:2&quot;&gt;'
  + '&lt;dc:title&gt;After Hours&lt;/dc:title&gt;'
  + '&lt;res protocolInfo=&quot;x-rincon-cpcontainer:*:*:*&quot;&gt;x-rincon-cpcontainer:1004206calbum%3a1499378108?sid=204&amp;amp;flags=8300&amp;amp;sn=2&lt;/res&gt;'
  + '&lt;upnp:albumArtURI&gt;/getaa?cover=1&lt;/upnp:albumArtURI&gt;'
  + '&lt;r:type&gt;instantPlay&lt;/r:type&gt;&lt;r:description&gt;After Hours&lt;/r:description&gt;'
  + '&lt;r:resMD&gt;&amp;lt;DIDL-Lite&amp;gt;&amp;lt;item id=&amp;quot;1004206calbum%3a1499378108&amp;quot;&amp;gt;&amp;lt;desc id=&amp;quot;cdudn&amp;quot;&amp;gt;SA_RINCON52231_X_#Svc52231-account-Token&amp;lt;/desc&amp;gt;&amp;lt;/item&amp;gt;&amp;lt;/DIDL-Lite&amp;gt;&lt;/r:resMD&gt;'
  + '&lt;/item&gt;'
  + '&lt;item id=&quot;FV:2/105&quot; parentID=&quot;FV:2&quot;&gt;&lt;dc:title&gt;Artist shortcut&lt;/dc:title&gt;&lt;res&gt;&lt;/res&gt;&lt;r:type&gt;shortcut&lt;/r:type&gt;&lt;/item&gt;'
  + '&lt;item id=&quot;FV:2/106&quot; parentID=&quot;FV:2&quot;&gt;&lt;dc:title&gt;John Mayer&lt;/dc:title&gt;&lt;res&gt;&lt;/res&gt;&lt;upnp:albumArtURI&gt;/getaa?artist=1&lt;/upnp:albumArtURI&gt;&lt;r:type&gt;shortcut&lt;/r:type&gt;&lt;r:description&gt;Apple Music&lt;/r:description&gt;'
  + '&lt;r:resMD&gt;&amp;lt;DIDL-Lite&amp;gt;&amp;lt;item id=&amp;quot;10052064artist%3A472054&amp;quot;&amp;gt;&amp;lt;upnp:class&amp;gt;object.container.person.musicArtist&amp;lt;/upnp:class&amp;gt;&amp;lt;desc id=&amp;quot;cdudn&amp;quot;&amp;gt;SA_RINCON52231_X_#Svc52231-account-Token&amp;lt;/desc&amp;gt;&amp;lt;/item&amp;gt;&amp;lt;/DIDL-Lite&amp;gt;&lt;/r:resMD&gt;&lt;/item&gt;'
  + '&lt;/DIDL-Lite&gt;';

test('parses Sonos Favorites with playable resource metadata and absolute artwork', () => {
  const favorites = parseSonosFavorites(favoriteResult, '192.168.50.20');
  assert.equal(favorites.length, 3);
  assert.deepEqual(favorites[0], {
    id: 'FV:2/104',
    title: 'After Hours',
    description: 'After Hours',
    type: 'instantPlay',
    category: 'album',
    playbackKind: 'direct',
    artistStationId: null,
    albumArtUri: 'http://192.168.50.20:1400/getaa?cover=1',
    uri: 'x-rincon-cpcontainer:1004206calbum%3a1499378108?sid=204&flags=8300&sn=2',
    resourceMetadata: '<DIDL-Lite><item id="1004206calbum%3a1499378108"><desc id="cdudn">SA_RINCON52231_X_#Svc52231-account-Token</desc></item></DIDL-Lite>',
    playbackSourceRaw: 'appleMusic',
    playable: true,
  });
  assert.equal(favorites[1]?.playable, false);
  assert.deepEqual({
    category: favorites[2]?.category,
    playbackKind: favorites[2]?.playbackKind,
    artistStationId: favorites[2]?.artistStationId,
    playable: favorites[2]?.playable,
  }, {
    category: 'artist',
    playbackKind: 'artistStation',
    artistStationId: '472054',
    playable: true,
  });
});

test('resolves favorite streaming services from iOS-compatible metadata hints', () => {
  assert.equal(favoritePlaybackSource(null, '<desc>SA_RINCON3079_X_#Svc3079-1-Token</desc>', null), 'spotify');
  assert.equal(favoritePlaybackSource(null, null, 'Amazon Music · Charm'), 'amazonMusic');
  assert.equal(favoritePlaybackSource(null, null, '网易云音乐'), 'neteaseMusic');
  assert.equal(favoritePlaybackSource('x-sonos-http:song:1.mp4?sid=204&sn=2', null, null), 'appleMusic');
});

test('only streams stations directly and sends catalog favorites through the Sonos queue', () => {
  const album = parseSonosFavorites(favoriteResult, '192.168.50.20')[0]!;
  assert.equal(favoriteUsesDirectTransport(album), false);
  assert.equal(favoriteUsesDirectTransport({
    ...album,
    category: 'station',
    uri: 'x-sonosapi-hls:hls%3ara.1740614260?sid=204&flags=8232&sn=2',
  }), true);
});

test('builds an Apple Music artist station using the matching Sonos service account', () => {
  const favorites = parseSonosFavorites(favoriteResult, '192.168.50.20');
  const station = buildAppleMusicArtistStationPlayback(favorites[2]!, favorites);
  assert.equal(station?.uri, 'x-sonosapi-radio:radio%3ara.472054?sid=204&flags=8300&sn=2');
  assert.equal(station?.title, 'John Mayer Radio');
  assert.match(station?.metadata ?? '', /id="000c206cradio%3ara\.472054"/);
  assert.match(station?.metadata ?? '', /object\.item\.audioItem\.audioBroadcast\.#programRadio/);
  assert.match(station?.metadata ?? '', /SA_RINCON52231_X_#Svc52231-account-Token/);
});

test('keeps Apple Music library artists playable and resolves their catalog artist id by exact name', async () => {
  const result = '&lt;DIDL-Lite&gt;&lt;item id=&quot;FV:2/200&quot;&gt;'
    + '&lt;dc:title&gt;James Blunt&lt;/dc:title&gt;&lt;res&gt;&lt;/res&gt;&lt;r:type&gt;shortcut&lt;/r:type&gt;&lt;r:description&gt;Apple Music&lt;/r:description&gt;'
    + '&lt;r:resMD&gt;&amp;lt;DIDL-Lite&amp;gt;&amp;lt;item id=&amp;quot;10052064libraryartist%3Ar.rSrGJ2g&amp;quot;&amp;gt;&amp;lt;upnp:class&amp;gt;object.container.person.musicArtist&amp;lt;/upnp:class&amp;gt;&amp;lt;/item&amp;gt;&amp;lt;/DIDL-Lite&amp;gt;&lt;/r:resMD&gt;'
    + '&lt;/item&gt;&lt;/DIDL-Lite&gt;';
  const artist = parseSonosFavorites(result, '192.168.50.20')[0];
  assert.equal(artist?.playbackKind, 'artistStation');
  assert.equal(artist?.artistStationId, null);
  assert.equal(artist?.playable, true);

  const id = await resolveAppleMusicArtistId('James Blunt', async url => {
    assert.equal(url.searchParams.get('entity'), 'musicArtist');
    return { results: [
      { wrapperType: 'artist', artistId: 123, artistName: 'James Blake' },
      { wrapperType: 'artist', artistId: 27496674, artistName: 'James Blunt' },
    ] };
  });
  assert.equal(id, '27496674');
});

test('matches favorites and service descriptors without duplicating the current URI', () => {
  const favorites = parseSonosFavorites(favoriteResult, '192.168.50.20');
  assert.equal(favoriteForCurrentURI(
    favorites,
    'x-rincon-cpcontainer:1004206calbum%3A1499378108?sid=204&flags=8232&sn=2',
  )?.id, 'FV:2/104');
  assert.equal(
    serviceDescriptorForCurrentURI(favorites, 'x-sonos-http:song:1568819888.mp4?sid=204&flags=8232&sn=2'),
    '<desc id="cdudn">SA_RINCON52231_X_#Svc52231-account-Token</desc>',
  );
});

test('builds a current-track favorite with iOS-compatible track id and nested DIDL', () => {
  const xml = buildFavoriteCreateElements({
    title: 'Carry Me Away',
    artist: 'John Mayer',
    album: 'Sob Rock',
    albumArtUri: 'https://example.com/sob-rock.jpg',
    uri: 'x-sonos-http:song:1568819888.mp4?sid=204&flags=8232&sn=2',
    serviceDescriptor: '<desc id="cdudn">SA_RINCON52231_X_#Svc52231-account-Token</desc>',
  });
  assert.match(xml, /<r:type>instantPlay<\/r:type>/);
  assert.match(xml, /x-sonos-http:song:1568819888\.mp4\?sid=204&amp;flags=8232&amp;sn=2/);
  assert.match(xml, /10032028song%3a1568819888/);
  assert.match(xml, /&lt;desc id=&quot;cdudn&quot;&gt;SA_RINCON52231/);
});

test('builds iOS-compatible Apple Music librarytrack metadata ids', () => {
  const metadata = buildCurrentTrackResourceMetadata({
    title: 'Things You Don\'t Say',
    artist: 'Real Action & JONES',
    album: 'Things You Don\'t Say - Single',
    albumArtUri: 'http://192.168.50.249:1400/getaa?track=1',
    uri: 'x-sonos-http:librarytrack%3ai.B0VzPbptxlqoaX7.mp4?sid=204&flags=8232&sn=2',
    serviceDescriptor: '<desc id="cdudn">SA_RINCON52231_X_#Svc52231-2-Token</desc>',
  });

  assert.match(metadata, /id="10032028librarytrack%3ai\.B0VzPbptxlqoaX7"/);
  assert.match(metadata, /object\.item\.audioItem\.musicTrack/);
});

test('maps the Sonos queue and preserves the current 1-based track number', () => {
  const queue = sonosQueueView('192.168.50.20', [{
    ItemId: 'Q:0/9',
    Title: 'Carry Me Away',
    Artist: 'John Mayer',
    Album: 'Sob Rock',
    AlbumArtUri: 'http://192.168.50.20:1400/getaa?cover=1',
    TrackUri: 'x-sonos-http:song:1568819888.mp4',
    Duration: '0:02:39',
  }], 42, 9);
  assert.equal(queue.updateId, 42);
  assert.equal(queue.currentTrackNumber, 9);
  assert.equal(queue.items[0]?.trackNumber, 9);
  assert.equal(queue.items[0]?.durationSeconds, 159);
  assert.equal(queue.items[0]?.sonosAlbumArtUri, 'http://192.168.50.20:1400/getaa?cover=1');
  assert.equal(queue.items[0]?.artworkSource, 'sonos');
});

test('groups queue artwork by service and album instead of track artist or getaa URL', () => {
  const first = sonosQueueAlbumKey({
    id: 'Q:0/1',
    album: 'CASE STUDY 01',
    uri: 'x-sonos-http:song:1.mp4?sid=204&flags=8232&sn=2',
  });
  const featuredArtistTrack = sonosQueueAlbumKey({
    id: 'Q:0/2',
    album: 'Case Study 01',
    uri: 'x-sonos-http:song:2.mp4?sid=204&flags=8232&sn=2',
  });
  assert.equal(first, featuredArtistTrack);
  assert.notEqual(first, sonosQueueAlbumKey({
    id: 'Q:0/3',
    album: 'NEVER ENOUGH',
    uri: 'x-sonos-http:song:3.mp4?sid=204&flags=8232&sn=2',
  }));
});
