import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  ALBUM_THEME_TRANSITION_MS,
  albumTransitionIdentity,
  shouldAnimateAlbumThemeTransition,
} from '../../public/dashboard/albumThemeTransition.js';

test('dashboard uses a relaxed album-theme transition duration', () => {
  assert.equal(ALBUM_THEME_TRANSITION_MS, 1400);
});

test('dashboard only animates when an existing player changes theme', () => {
  assert.equal(shouldAnimateAlbumThemeTransition('', 'new-theme'), false);
  assert.equal(shouldAnimateAlbumThemeTransition('same-theme', 'same-theme'), false);
  assert.equal(shouldAnimateAlbumThemeTransition('old-theme', 'new-theme'), true);
  assert.equal(shouldAnimateAlbumThemeTransition('old-theme', 'new-theme', true), false);
});

test('dashboard keeps the same transition identity for consecutive tracks on one album', () => {
  const first = albumTransitionIdentity({
    playbackSourceRaw: 'appleMusic',
    album: 'CASE STUDY 01',
    artist: 'Daniel Caesar',
    albumArtUri: 'http://speaker:1400/getaa?track=1',
  });
  const second = albumTransitionIdentity({
    playbackSourceRaw: 'appleMusic',
    album: 'Case Study 01',
    artist: 'Daniel Caesar & Brandy',
    albumArtUri: 'http://speaker:1400/getaa?track=2',
  });
  assert.equal(first, second);
  assert.notEqual(first, albumTransitionIdentity({
    playbackSourceRaw: 'appleMusic',
    album: 'NEVER ENOUGH',
  }));
});
