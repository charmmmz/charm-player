import { Bonjour, type Service, type ServiceConfig } from 'bonjour-service';
import { hostname } from 'node:os';
import type { Logger } from 'pino';

export function relayBonjourServiceConfig(port: number, host = hostname()): ServiceConfig {
  return {
    name: 'Charm Sonos Relay',
    type: 'charmrelay',
    protocol: 'tcp',
    host: localBonjourHost(host),
    port,
    txt: {
      path: '/api/health',
      version: '1',
    },
  };
}

export interface RelayBonjourAdvertisement {
  stop(): void;
}

export function publishRelayBonjour(port: number, log: Logger): RelayBonjourAdvertisement {
  const bonjour = new Bonjour();
  let service: Service | null = null;
  try {
    const config = relayBonjourServiceConfig(port);
    service = bonjour.publish(config);
    log.info(
      { service: '_charmrelay._tcp', host: config.host, port },
      'published relay Bonjour service',
    );
  } catch (err) {
    log.warn({ err, service: '_charmrelay._tcp', port }, 'failed to publish relay Bonjour service');
  }

  return {
    stop() {
      try {
        service?.stop();
        bonjour.destroy();
      } catch (err) {
        log.debug({ err }, 'failed to stop relay Bonjour service cleanly');
      }
    },
  };
}

function localBonjourHost(rawHost: string): string {
  const trimmed = rawHost.trim();
  const withoutRootDot = trimmed.endsWith('.') ? trimmed.slice(0, -1) : trimmed;
  if (!withoutRootDot) return 'localhost.local';
  if (withoutRootDot.endsWith('.local')) return withoutRootDot;
  if (withoutRootDot.includes('.')) return withoutRootDot;
  return `${withoutRootDot}.local`;
}
