import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ITunesArtworkClient } from './itunesArtwork.js';

test('iTunes artwork lookup uses numeric catalog id and upsizes artwork', async () => {
  const requested: URL[] = [];
  const client = new ITunesArtworkClient({
    fetchJson: async url => {
      requested.push(url);
      return {
        resultCount: 1,
        results: [
          {
            wrapperType: 'track',
            trackId: 1440857781,
            artworkUrl100: 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/cover/100x100bb.jpg',
          },
        ],
      };
    },
  });

  const url = await client.lookupArtworkURLString('1440857781', 'us');

  assert.equal(url, 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/cover/600x600bb.jpg');
  assert.equal(requested[0]?.host, 'itunes.apple.com');
  assert.equal(requested[0]?.pathname, '/lookup');
  assert.equal(requested[0]?.searchParams.get('id'), '1440857781');
  assert.equal(requested[0]?.searchParams.get('country'), 'US');
});

test('iTunes artwork lookup skips non-numeric ids without fetching', async () => {
  let fetchCount = 0;
  const client = new ITunesArtworkClient({
    fetchJson: async () => {
      fetchCount += 1;
      return { resultCount: 0, results: [] };
    },
  });

  const url = await client.lookupArtworkURLString('libraryplaylist:p.BaUXlqoaX7', 'US');

  assert.equal(url, null);
  assert.equal(fetchCount, 0);
});

test('iTunes artwork search selects the best exact song match', async () => {
  const requested: URL[] = [];
  const client = new ITunesArtworkClient({
    fetchJson: async url => {
      requested.push(url);
      return {
        resultCount: 2,
        results: [
          {
            wrapperType: 'track',
            trackName: 'Moon',
            artistName: 'Different Artist',
            collectionName: 'Other',
            artworkUrl100: 'https://cdn.example.com/wrong/100x100bb.jpg',
          },
          {
            wrapperType: 'track',
            trackName: 'Moon',
            artistName: 'Daniel Caesar',
            collectionName: 'Freudian',
            artworkUrl100: 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/moon/100x100bb.jpg',
          },
        ],
      };
    },
  });

  const url = await client.searchArtworkURLString({
    kind: 'song',
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    countryCode: 'US',
  });

  assert.equal(url, 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/moon/600x600bb.jpg');
  assert.equal(requested[0]?.pathname, '/search');
  assert.equal(requested[0]?.searchParams.get('media'), 'music');
  assert.equal(requested[0]?.searchParams.get('entity'), 'song');
  assert.equal(requested[0]?.searchParams.get('limit'), '5');
  assert.equal(requested[0]?.searchParams.get('term'), 'Moon Daniel Caesar Freudian');
});

test('iTunes artwork search rejects weak song matches', async () => {
  const client = new ITunesArtworkClient({
    fetchJson: async () => ({
      resultCount: 1,
      results: [
        {
          wrapperType: 'track',
          trackName: 'Moon',
          artistName: 'Different Artist',
          collectionName: 'Other',
          artworkUrl100: 'https://cdn.example.com/wrong/100x100bb.jpg',
        },
      ],
    }),
  });

  const url = await client.searchArtworkURLString({
    kind: 'song',
    title: 'Moon',
    artist: 'Daniel Caesar',
    album: 'Freudian',
    countryCode: 'US',
  });

  assert.equal(url, null);
});

test('iTunes artwork lookup caches successful results', async () => {
  let fetchCount = 0;
  const client = new ITunesArtworkClient({
    fetchJson: async () => {
      fetchCount += 1;
      return {
        resultCount: 1,
        results: [
          {
            wrapperType: 'track',
            trackId: 1440857781,
            artworkUrl100: 'https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/cover/100x100bb.jpg',
          },
        ],
      };
    },
  });

  await client.lookupArtworkURLString('1440857781', 'US');
  await client.lookupArtworkURLString('1440857781', 'US');

  assert.equal(fetchCount, 1);
});

test('iTunes artwork lookup caches misses', async () => {
  let fetchCount = 0;
  const client = new ITunesArtworkClient({
    fetchJson: async () => {
      fetchCount += 1;
      return { resultCount: 0, results: [] };
    },
  });

  assert.equal(await client.lookupArtworkURLString('1440857781', 'US'), null);
  assert.equal(await client.lookupArtworkURLString('1440857781', 'US'), null);

  assert.equal(fetchCount, 1);
});

test('iTunes artwork cache prunes oldest entries at the configured limit', async () => {
  const requestedIDs: string[] = [];
  const client = new ITunesArtworkClient({
    maxCacheEntries: 1,
    fetchJson: async url => {
      const id = url.searchParams.get('id') ?? '';
      requestedIDs.push(id);
      return {
        resultCount: 1,
        results: [
          {
            wrapperType: 'track',
            trackId: Number(id),
            artworkUrl100: `https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/${id}/100x100bb.jpg`,
          },
        ],
      };
    },
  });

  await client.lookupArtworkURLString('111', 'US');
  await client.lookupArtworkURLString('222', 'US');
  await client.lookupArtworkURLString('111', 'US');

  assert.deepEqual(requestedIDs, ['111', '222', '111']);
});
