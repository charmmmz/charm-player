import { Bonjour, type Service, type ServiceConfig } from 'bonjour-service';
import type { Logger } from 'pino';

export function relayBonjourServiceConfig(port: number): ServiceConfig {
  return {
    name: 'Charm Sonos Relay',
    type: 'charmrelay',
    protocol: 'tcp',
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
    service = bonjour.publish(relayBonjourServiceConfig(port));
    log.info(
      { service: '_charmrelay._tcp', port },
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

