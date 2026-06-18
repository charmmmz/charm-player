import assert from 'node:assert/strict';
import { test } from 'node:test';

import { apnsStatusFromConfig, type ApnsConfig } from './apns.js';

const baseConfig: ApnsConfig = {
  bundleId: 'com.charm.SonosWidget',
  keyPath: '/app/data/apns.p8',
  keyId: 'ABCDEF1234',
  teamId: '3MSS7DJGVR',
  production: true,
};

test('APNs status is ready when key metadata and key file are present', () => {
  assert.deepEqual(apnsStatusFromConfig(baseConfig, true), {
    mode: 'ready',
    environment: 'production',
    bundleId: 'com.charm.SonosWidget',
    keyIdConfigured: true,
    teamIdConfigured: true,
    keyFilePresent: true,
    missing: [],
  });
});

test('APNs status is dry-run and reports missing key inputs', () => {
  assert.deepEqual(apnsStatusFromConfig({
    ...baseConfig,
    keyId: '',
    teamId: '',
    production: false,
  }, false), {
    mode: 'dry-run',
    environment: 'sandbox',
    bundleId: 'com.charm.SonosWidget',
    keyIdConfigured: false,
    teamIdConfigured: false,
    keyFilePresent: false,
    missing: ['APNS_KEY_ID', 'APNS_TEAM_ID', 'apns.p8'],
  });
});

