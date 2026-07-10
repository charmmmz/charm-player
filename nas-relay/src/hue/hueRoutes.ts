import { Router } from 'express';
import type { Logger } from 'pino';

import type { HueAmbienceService } from './hueAmbienceService.js';
import type { HueAmbienceRuntimeConfig } from './hueTypes.js';

export function createHueAmbienceRouter(service: HueAmbienceService, log: Logger): Router {
  const router = Router();

  router.get('/hue-ambience/status', (_req, res) => {
    res.json({ ok: true, status: service.status() });
  });

  router.put('/hue-ambience/config', async (req, res) => {
    const config = req.body as Partial<HueAmbienceRuntimeConfig>;
    const error = validateConfig(config);
    if (error) {
      res.status(400).json({ ok: false, error });
      return;
    }

    try {
      await service.saveConfig(config as HueAmbienceRuntimeConfig);
      res.json({ ok: true, status: service.status() });
    } catch (err) {
      log.warn({ err }, 'failed to save Hue ambience config');
      res.status(500).json({ ok: false, error: String(err) });
    }
  });

  router.delete('/hue-ambience/config', async (_req, res) => {
    try {
      await service.clearConfig();
      res.json({ ok: true, status: service.status() });
    } catch (err) {
      log.warn({ err }, 'failed to clear Hue ambience config');
      res.status(500).json({ ok: false, error: String(err) });
    }
  });

  return router;
}

function validateConfig(config: Partial<HueAmbienceRuntimeConfig>): string | null {
  if (!config || typeof config !== 'object') return 'config body required';
  if (!config.bridge?.id || !config.bridge.ipAddress) return 'bridge required';
  if (!config.applicationKey) return 'applicationKey required';
  if (!config.resources || !Array.isArray(config.resources.lights) || !Array.isArray(config.resources.areas)) {
    return 'resources required';
  }
  if (!Array.isArray(config.mappings)) return 'mappings required';
  return null;
}
