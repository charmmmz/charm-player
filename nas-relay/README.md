# Sonos Live Activity Relay

A small Node.js + TypeScript service that subscribes to Sonos UPnP events on
your LAN, pushes the corresponding Live Activity updates to the Charm for
Sonos iOS app via Apple's APNs HTTP/2 endpoint, resolves Apple Music animated
artwork for app surfaces, and can run Hue Ambience while the iPhone app is
suspended.

The point: keep the iPhone Lock Screen Live Activity fresh **without** the
iOS app needing to run in the background. UPnP eventing means we don't poll
Sonos — the speakers themselves push state changes (track / play / pause /
group changes) to the relay within ~100 ms, the relay forwards them through
APNs, and the Live Activity updates within another ~1–3 s.

## What it does

- LAN-only HTTP (no general HTTP auth or TLS, so keep it inside a trusted home
  LAN or tailnet).
- Relay discovery is automatic on the local subnet: the relay publishes a
  Bonjour service (`_charmrelay._tcp`) and the iOS app can find it without a
  manually entered URL.
- Pushes the basic ContentState fields used by the Lock Screen widget:
  track / artist / album / isPlaying / startedAt / endsAt / groupMemberCount.
- Live Activity push payloads stay metadata-focused; artwork and video are not
  embedded directly in APNs payloads. Separately, the relay exposes Apple
  Music animated artwork lookup endpoints for app UI surfaces while the relay
  is reachable.
- Hue Ambience config is uploaded from the iOS app. The relay stores the
  Hue app key and assignments in `DATA_DIR/hue-ambience-config.json`, then
  applies album-palette transitions on Sonos play/track changes.
  The iOS Light Motion Speed setting controls the flow interval; set
  `HUE_FLOW_INTERVAL_SECONDS` only when the NAS should override that value.
  Mapped Entertainment Areas can use the relay's built-in Hue Entertainment
  DTLS streaming, with CLIP v2 color rotation as a Music Ambience fallback
  when streaming is unavailable.

External access (DDNS IPv6 / Cloudflare Tunnel / Tailscale) is intentionally
out of scope here. Bring up the LAN path first, then add an external transport
only if your deployment needs one.

## Docker Compose deployment

Create a folder for the relay, put this `docker-compose.yml` inside it, then
deploy it with Docker Compose or Portainer. This stack runs two relays:

- `relay`: TestFlight/App Store production APNs on port `8787`.
- `relay-debug`: Xcode-installed sandbox APNs on port `8789`.

Use the GitHub Container Registry image by default. Mainland China users can
replace each `image:` line with the Aliyun ACR line shown in the comments.

```yaml
services:
  relay:
    image: ghcr.io/charmmmz/charm-for-sonos/nas-relay:latest
    # Mainland China image:
    # image: crpi-wgo31iwe48epi9ov.cn-hangzhou.personal.cr.aliyuncs.com/charmmmz/sonos-nas-relay:latest
    pull_policy: always
    container_name: sonos-live-activity-relay
    init: true
    restart: unless-stopped
    network_mode: host
    environment:
      LOG_LEVEL: info
      APNS_BUNDLE_ID: com.charm.SonosWidget
      APNS_TEAM_ID: 3MSS7DJGVR
      APNS_KEY_PATH: /app/data/AuthKey_4K6LLXCPPN.p8
      APNS_KEY_ID: 4K6LLXCPPN
      APNS_PRODUCTION: "true"
      ANIMATED_ARTWORK_ENABLED: "${ANIMATED_ARTWORK_ENABLED:-true}"
    volumes:
      - ${NAS_RELAY_DATA_DIR:-./data}:/app/data

  relay-debug:
    image: ghcr.io/charmmmz/charm-for-sonos/nas-relay:latest
    # Mainland China image:
    # image: crpi-wgo31iwe48epi9ov.cn-hangzhou.personal.cr.aliyuncs.com/charmmmz/sonos-nas-relay:latest
    pull_policy: always
    container_name: sonos-live-activity-relay-debug
    init: true
    restart: unless-stopped
    network_mode: host
    environment:
      LOG_LEVEL: debug
      RELAY_PORT: "8789"
      APNS_BUNDLE_ID: com.charm.SonosWidget
      APNS_TEAM_ID: 3MSS7DJGVR
      APNS_KEY_PATH: /app/data/AuthKey_M8FQR2H6DD.p8
      APNS_KEY_ID: M8FQR2H6DD
      APNS_PRODUCTION: "false"
      ANIMATED_ARTWORK_ENABLED: "${ANIMATED_ARTWORK_ENABLED:-true}"
    volumes:
      - ${NAS_RELAY_DEBUG_DATA_DIR:-./data-debug}:/app/data
```

For a NAS deployment, set the data directory variables to real host paths so
relay state and configuration survive container updates:

```env
# QNAP example
NAS_RELAY_DATA_DIR=/share/Data/nas-relay/data
NAS_RELAY_DEBUG_DATA_DIR=/share/Data/nas-relay-debug/data

# Synology example
# NAS_RELAY_DATA_DIR=/volume1/docker/nas-relay/data
# NAS_RELAY_DEBUG_DATA_DIR=/volume1/docker/nas-relay-debug/data
```

`/app/data` stores relay state such as ActivityKit tokens, Hue Ambience config,
the animated artwork cache, and the optional APNs `.p8` provider key. Do not
bake secrets into the image.

APNs provider keys should only be configured by the app maintainer or by users
who build the iOS app under their own Apple Developer account and bundle ID.
Without `APNS_KEY_ID` and a readable `.p8` file at `APNS_KEY_PATH`, the relay
runs in dry-run mode: Sonos discovery, health checks, local diagnostics, and
non-APNs features still work, but Live Activity push updates are not sent.

## Quick start (NAS + Portainer)

1. **Prepare the data directories.** Put the production and sandbox APNs
   `.p8` files in their respective mounted directories. Set
   `NAS_RELAY_DATA_DIR` and `NAS_RELAY_DEBUG_DATA_DIR` in Portainer or a local
   `.env` file when the defaults are not suitable for your NAS.
2. **Deploy via Portainer** — Stacks → Add stack, paste the Compose block above,
   choose either the GitHub or Aliyun image lines, then deploy. If the selected
   image is private, log in to that registry on the NAS first.
3. **Verify**:
   ```bash
   curl http://<nas-ip>:8787/api/health
   curl http://<nas-ip>:8789/api/health
   ```
   Each enabled relay should return JSON with `sonos.discoveryStatus: "ready"`
   and at least one entry under `groups[]`. The first sample takes a few seconds
   while the relay enumerates speakers. If your network blocks multicast
   discovery, set
   `SONOS_SEED_IP` to any always-on speaker IP and restart the stack.
4. **Select the matching relay in the iOS app.** TestFlight/App Store builds
   use `http://<nas-ip>:8787`; Xcode debug builds use
   `http://<nas-ip>:8789`. When both containers are running, set the Relay URL
   manually because Bonjour advertises both `_charmrelay._tcp` services and
   cannot choose the APNs environment for you. With only one relay running,
   automatic discovery is sufficient.
5. **Watch logs** (Portainer → Containers → relay → Logs). Play / pause
   / change track on Sonos and you should see lines like:
   ```
   [DRY-RUN] would push Live Activity update { trackTitle: …, isPlaying: true, … }
   ```
   This means everything is wired up correctly except APNs itself.

## Going live (after Apple Developer account is in)

1. Apple Developer Portal → Certificates → Keys → Create a new "Apple Push
   Notifications service (APNs)" key. Download the `.p8` file (one-time —
   you cannot re-download).
2. Note the **Key ID** (10-char string shown next to the key). `APNS_TEAM_ID`
   already defaults to `3MSS7DJGVR` for this app; change it only if you build
   under a different Apple Developer team.
3. Drop the `.p8` into the matching mounted volume:
   ```bash
   ssh admin@<qnap>
   cp ~/AuthKey_ABCDEF1234.p8 /share/Data/nas-relay/data/AuthKey_ABCDEF1234.p8
   chmod 600 /share/Data/nas-relay/data/AuthKey_ABCDEF1234.p8
   ```
4. Update the matching Compose service:
   ```
   APNS_KEY_PATH=/app/data/AuthKey_ABCDEF1234.p8
   APNS_KEY_ID=ABCDEF1234
   APNS_TEAM_ID=3MSS7DJGVR
   APNS_PRODUCTION=true    # TestFlight/App Store production APNs
   ```
5. Restart the stack. Relay log will print `APNs provider ready` instead of
   `running in DRY-RUN mode`. `/api/health` also reports `apns.mode: "ready"`
   when the key is usable, or `apns.mode: "dry-run"` with missing fields when
   setup is incomplete.

Use `APNS_PRODUCTION=true` on the production relay for TestFlight or App Store
builds. Keep it `false` on the debug relay for Xcode-installed builds because
those use APNs sandbox tokens. Keep their data directories separate so tokens
from the two APNs environments are never mixed.

The bundle ID defaults to `com.charm.SonosWidget` (matches your iOS
project); change `APNS_BUNDLE_ID` if you renamed it. The APNs topic is
automatically suffixed with `.push-type.liveactivity`, which is what Apple
requires for Live Activity pushes.

### Live Activity push-to-start

The relay can start the iOS Live Activity when Sonos playback begins. The iOS
app must have run at least once after install so it can upload an ActivityKit
push-to-start token. APNs must be configured with `APNS_KEY_ID`,
`APNS_TEAM_ID`, `APNS_KEY_PATH`, `APNS_PRODUCTION`, and `APNS_BUNDLE_ID`.

Expected flow:

1. Open Charm Player once on the iPhone while the relay is reachable.
2. Confirm `/api/health` reports `apns.mode: "ready"` and
   `liveActivity.startTokenCount > 0`.
3. Start playback on the selected Sonos group without opening the app.
4. The relay sends an APNs `start` push.
5. iOS creates the Live Activity and reports an update token back to
   `/api/register-activity`.

Use a real iPhone for this check. APNs push-to-start cannot be fully validated
in the simulator. Before playback, a healthy response should include:

```json
{
  "apns": { "mode": "ready" },
  "liveActivity": {
    "startTokenCount": 1,
    "updateTokenCount": 0
  }
}
```

Expected relay log sequence after playback starts:

```text
live_activity action=apns-start trigger=sonos-change groupId=<group>
live_activity action=register-request groupId=<group> activityId=<activity>
live_activity action=apns-update trigger=register-initial groupId=<group>
```

The iPhone should show one Live Activity, update its track metadata, and avoid
creating a duplicate when the app is opened later.

### Animated Apple Music artwork

When `ANIMATED_ARTWORK_ENABLED` is not set to `false`, the relay can resolve
Apple Music animated artwork for app UI surfaces:

- `/api/animated-artwork/url` accepts an Apple Music album URL and returns
  available square/tall animated artwork URLs.
- `/api/animated-artwork/search` accepts artist and album metadata, searches for
  the matching Apple Music album, then resolves animated artwork.

Results are cached in `DATA_DIR/animated-artwork-cache.json` so repeated player
and album visits do not repeatedly fetch Apple Music metadata. This feature is
independent of APNs readiness: a dry-run relay can still provide animated
artwork lookup as long as it can reach Apple Music endpoints.

## API

| Method | Path                                  | Body / Params                                                   | Description                                              |
|--------|---------------------------------------|-----------------------------------------------------------------|----------------------------------------------------------|
| GET    | `/api/health`                         | —                                                               | Liveness, discovery/APNs status, and current group snapshots |
| GET    | `/api/animated-artwork/url`           | query: `url=<apple-music-album-url>&country=<storefront?>`      | Resolves cached Apple Music animated artwork by album URL |
| GET    | `/api/animated-artwork/search`        | query: `artist=<artist>&album=<album>&country=<storefront?>`    | Resolves cached Apple Music animated artwork by metadata |
| GET    | `/api/playback-state`                 | query: `groupId=<group-id>`                                    | Returns the cached playback snapshot for one group       |
| POST   | `/api/register-push-to-start`         | `{ groupId, token, clientId?, speakerName?, liveActivityStyleRaw? }` | Stores iOS ActivityKit push-to-start tokens              |
| POST   | `/api/register-activity`              | `{ groupId, token, attributes? }`                               | Called by iOS on every push-token rotation               |
| DELETE | `/api/register-activity/:token`       | path: `:token`                                                  | Called by iOS when the Live Activity ends                |
| POST   | `/api/live-activity-preferences`      | selected group, style, and optional resume request              | Updates relay-side Live Activity preferences             |
| POST   | `/api/live-activity-dismissed`        | group, client/activity identity, and optional token             | Records dismissal suppression and removes the token      |
| POST   | `/api/live-activity-command`          | registered token plus playback or soundbar command              | Executes authenticated Live Activity controls on Sonos   |
| GET    | `/api/hue-ambience/status`            | —                                                               | Hue runtime status without exposing the Hue app key      |
| PUT    | `/api/hue-ambience/config`            | complete config uploaded by iOS                                 | Stores Bridge key, resources, assignments, and settings  |
| DELETE | `/api/hue-ambience/config`            | —                                                               | Removes stored Hue config and stops active ambience      |
| POST   | `/api/device-logs`                    | batched diagnostics from the iOS app                            | Receives recent device logs for relay-side debugging     |
| GET    | `/api/device-logs/recent`             | optional query: `limit=<count>`                                 | Returns recent in-memory device logs                     |
| GET    | `/api/device-logs/stream`             | —                                                               | Streams new device logs over SSE                         |

### Internal Sonos API (for `nas-agent`)

All routes require header **`X-Internal-Token: $INTERNAL_API_TOKEN`**. If `INTERNAL_API_TOKEN` is unset, these routes return **503**.

| Method | Path | Body / Params | Description |
|--------|------|---------------|-------------|
| GET | `/internal/sonos/groups` | — | Cached snapshots for all discovered coordinators (`groupId` = coordinator LAN IP). |
| GET | `/internal/sonos/state` | `?groupId=` | Refresh AVTransport snapshot for one group. |
| POST | `/internal/sonos/play` | `{ groupId }` | Play / resume. |
| POST | `/internal/sonos/pause` | `{ groupId }` | Pause. |
| POST | `/internal/sonos/next` | `{ groupId }` | Next track. |
| POST | `/internal/sonos/previous` | `{ groupId }` | Previous track. |
| POST | `/internal/sonos/volume` | `{ groupId, volume }` | Group volume 0–100. |

Use the `groupId` returned by `/internal/sonos/groups` for the other internal
Sonos routes.

## Layout

```
nas-relay/
├── docker-compose.yml      # Generic env-driven stack
├── docker-compose.github.yml # GitHub Container Registry stack
├── docker-compose.aliyun.yml # Aliyun ACR stack
├── Dockerfile              # multi-stage Node 24 alpine build
├── .env.example
├── package.json / tsconfig.json
├── data/                   # local default for persistent relay state
└── src/
    ├── index.ts            # Express + wire-up
    ├── types.ts            # shared relay and ActivityKit payload types
    ├── artwork/            # artwork lookup, cache, routes, and tests
    ├── diagnostics/        # iOS device-log ingestion and streaming
    ├── hue/                # Hue ambience, CLIP, and Entertainment streaming
    ├── live-activity/      # APNs, token stores, start/update policy, and tests
    ├── sonos/              # Sonos bridge, snapshots, playback, and internal API
    └── transport/          # Bonjour advertisement and HTTP log policy
```

## Possible future work

- External access through Tailscale, DDNS IPv6, or another private transport.
- Further ActivityKit token-rotation and multi-device hardening.
- Auth: shared-secret header on register/unregister once we leave the LAN.
- Observability: Prometheus `/metrics` if it ever feels needed.
