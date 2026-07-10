import { Router } from 'express';

import { snapshotJson } from './relaySnapshotJson.js';
import type { SonosGroupSnapshot } from '../types.js';

export interface PlaybackStateSource {
  current(groupId: string): SonosGroupSnapshot | undefined;
}

export function createPlaybackStateRouter(source: PlaybackStateSource): Router {
  const router = Router();

  router.get('/playback-state', (req, res) => {
    const groupId = typeof req.query.groupId === 'string' ? req.query.groupId.trim() : '';
    if (!groupId) {
      res.status(400).json({ ok: false, error: 'groupId query parameter required' });
      return;
    }

    const snap = source.current(groupId);
    if (!snap) {
      res.status(404).json({ ok: false, error: 'unknown_group', groupId });
      return;
    }

    res.setHeader('Cache-Control', 'no-store');
    res.json({
      ok: true,
      source: 'cached',
      state: snapshotJson(snap),
    });
  });

  return router;
}
