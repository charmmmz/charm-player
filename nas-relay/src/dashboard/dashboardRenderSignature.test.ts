import assert from 'node:assert/strict';
import { test } from 'node:test';

import { presentationSignature } from '../../public/dashboard/renderSignature.js';

test('dashboard presentation signature ignores progress-only snapshot updates', () => {
  const first = presentationSignature({
    generatedAt: '2026-07-17T02:00:00Z',
    relay: { uptimeSeconds: 10 },
    group: {
      trackTitle: 'Disillusioned',
      positionSeconds: 12,
      sampledAt: '2026-07-17T02:00:00Z',
      groupVolume: 9,
    },
  });
  const second = presentationSignature({
    generatedAt: '2026-07-17T02:00:05Z',
    relay: { uptimeSeconds: 15 },
    group: {
      trackTitle: 'Disillusioned',
      positionSeconds: 17,
      sampledAt: '2026-07-17T02:00:05Z',
      groupVolume: 9,
    },
  });

  assert.equal(first, second);
});

test('dashboard presentation signature changes for visible playback state', () => {
  const base = {
    group: {
      trackTitle: 'Disillusioned',
      positionSeconds: 12,
      sampledAt: '2026-07-17T02:00:00Z',
      groupVolume: 9,
    },
  };

  assert.notEqual(
    presentationSignature(base),
    presentationSignature({ group: { ...base.group, trackTitle: 'Toronto 2014' } }),
  );
  assert.notEqual(
    presentationSignature(base),
    presentationSignature({ group: { ...base.group, groupVolume: 10 } }),
  );
});
