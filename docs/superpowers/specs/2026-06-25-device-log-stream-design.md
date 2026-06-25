# Device Log Stream Design

## Goal

Make iPhone app and widget diagnostics visible from `nas-relay` in near real time, so Live Activity artwork failures can be correlated without manual log export from the phone.

## Design

`SonosLog` keeps its current local behavior: every line is printed and appended to the shared App Group diagnostics file. After the local write is queued, it also sends a best-effort remote copy to the relay URL stored in shared storage. Remote delivery is asynchronous, fire-and-forget, and never writes another diagnostic line on failure.

`nas-relay` accepts batches at `POST /api/device-logs`, keeps a bounded in-memory recent buffer, and exposes both `GET /api/device-logs/recent` and `GET /api/device-logs/stream`. The stream uses Server-Sent Events so `curl -N` can watch phone and widget logs live from the NAS.

## Data

Each phone log event carries a stable app install `clientId`, bundle identifier, category, level, ISO timestamp, and rendered line. The relay assigns a monotonic id and `receivedAt` timestamp. The relay does not persist these logs to disk.

## Failure Behavior

If the relay URL is missing, malformed, offline, or slow, the phone simply drops the remote copy. Local diagnostics remain available and app/widget behavior is unchanged.

## Testing

Relay tests cover accepting batches, exposing recent entries, bounding the buffer, and streaming new events. Swift tests cover request body encoding and URL construction. Manual verification uses `curl` against the relay plus a physical iPhone deploy.
