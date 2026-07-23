const VOLATILE_PRESENTATION_KEYS = new Set([
  'positionSeconds',
  'sampledAt',
  'generatedAt',
  'uptimeSeconds',
]);

export function presentationSignature(value) {
  return JSON.stringify(value, (key, current) => (
    VOLATILE_PRESENTATION_KEYS.has(key) ? undefined : current
  ));
}
