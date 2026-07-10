import { Router } from 'express';
import type { Logger } from 'pino';

import {
  DeviceLogService,
  DeviceLogValidationError,
  type DeviceLogBatchInput,
  type DeviceLogEntry,
} from './deviceLogs.js';

export function createDeviceLogRouter(service: DeviceLogService, log: Logger): Router {
  const router = Router();

  router.post('/device-logs', (req, res) => {
    try {
      const entries = service.receive(req.body as DeviceLogBatchInput, { sourceIp: req.ip });
      log.debug({ accepted: entries.length }, 'received device logs');
      res.json({ ok: true, accepted: entries.length });
    } catch (err) {
      if (err instanceof DeviceLogValidationError) {
        res.status(400).json({ ok: false, error: err.message });
        return;
      }
      log.warn({ err }, 'failed to receive device logs');
      res.status(500).json({ ok: false, error: String(err) });
    }
  });

  router.get('/device-logs/recent', (req, res) => {
    const limit = typeof req.query.limit === 'string' ? Number(req.query.limit) : undefined;
    res.json({ ok: true, entries: service.recent(Number.isFinite(limit) ? limit : undefined) });
  });

  router.get('/device-logs/stream', (req, res) => {
    res.status(200);
    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders?.();
    res.write(': connected\n\n');

    const sendEntry = (entry: DeviceLogEntry) => {
      res.write(`event: device-log\ndata: ${JSON.stringify(entry)}\n\n`);
    };

    service.on('entry', sendEntry);
    req.on('close', () => {
      service.off('entry', sendEntry);
    });
  });

  return router;
}
