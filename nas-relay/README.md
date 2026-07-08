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

## Phase 1 scope

- LAN-only HTTP (no auth, no TLS — fine for inside a tailnet / home LAN).
- Relay discovery is automatic on the local subnet: the relay publishes a
  Bonjour service (`_charmrelay._tcp`) and the iOS app can find it without a
  manually entered URL.
- Pushes the basic ContentState fields used by the Lock Screen widget:
  track / artist / album / isPlaying / startedAt / endsAt / groupMemberCount.
- Live Activity push payloads stay metadata-focused; artwork and video are not
  embedded directly in APNs payloads. Separately, the relay exposes a cached
  artwork proxy and Apple Music animated artwork lookup endpoints for app UI
  surfaces while the relay is reachable.
- Hue Ambience config is uploaded from the iOS app. The relay stores the
  Hue app key and assignments in `DATA_DIR/hue-ambience-config.json`, then
  applies album-palette transitions on Sonos play/track changes.
  The iOS Light Motion Speed setting controls the flow interval; set
  `HUE_FLOW_INTERVAL_SECONDS` only when the NAS should override that value.
  Mapped Entertainment Areas use the private Hue EDK sidecar for Hue
  Entertainment streaming effects, with CLIP v2 color rotation as a Music
  Ambience fallback when sync is unavailable.
- Counter-Strike 2 Game State Integration payloads can be posted directly to
  the relay. When Hue Ambience config has CS2 sync enabled and at least one
  mapped Entertainment Area, the relay renders low-latency game lighting from
  the latest local-player state. Competitive and deathmatch use separate
  strategies; competitive spectator/death state falls back to low-brightness
  ambience.

External access (DDNS IPv6 / Cloudflare Tunnel / Tailscale) is intentionally
out of scope here; bring up the LAN path first, then layer on whichever
external transport once Phase 1 is verified.

## Docker Compose deployment

Create a folder for the relay, put this `docker-compose.yml` inside it, then
deploy it with Docker Compose or Portainer.

Use the GitHub Container Registry image by default:

```yaml
services:
  relay:
    image: ghcr.io/charmmmz/charm-for-sonos/nas-relay:latest
    # Mainland China users can replace the image with:
    # image: crpi-wgo31iwe48epi9ov.cn-hangzhou.personal.cr.aliyuncs.com/charmmmz/sonos-nas-relay:latest
    container_name: charm-player-relay
    init: true
    restart: unless-stopped
    network_mode: host
    environment:
      APNS_BUNDLE_ID: com.charm.SonosWidget
      APNS_TEAM_ID: 3MSS7DJGVR
      APNS_KEY_PATH: ${APNS_KEY_PATH:-/app/data/apns.p8}
      APNS_KEY_ID: ${APNS_KEY_ID:-}
      APNS_PRODUCTION: "${APNS_PRODUCTION:-true}"
      ANIMATED_ARTWORK_ENABLED: "${ANIMATED_ARTWORK_ENABLED:-true}"
    volumes:
      - ${NAS_RELAY_DATA_DIR:-./data}:/app/data
```

For a NAS deployment, set `NAS_RELAY_DATA_DIR` to a real host path so relay
state and configuration survive container updates:

```env
# QNAP example
NAS_RELAY_DATA_DIR=/share/Data/nas-relay/data

# Synology example
# NAS_RELAY_DATA_DIR=/volume1/docker/nas-relay/data
```

`/app/data` stores relay state such as ActivityKit tokens, Hue Ambience config,
artwork cache, animated artwork cache, and the optional APNs `.p8` provider key.
Do not bake secrets into the image.

APNs provider keys should only be configured by the app maintainer or by users
who build the iOS app under their own Apple Developer account and bundle ID.
Without `APNS_KEY_ID` and a readable `.p8` file at `APNS_KEY_PATH`, the relay
runs in dry-run mode: Sonos discovery, health checks, local diagnostics, and
non-APNs features still work, but Live Activity push updates are not sent.

## Quick start (QNAP + Portainer)

1. **Copy `.env.example` → `.env`**. Leave `SONOS_SEED_IP` empty for SSDP
   auto-discovery. Leave `APNS_KEY_ID` blank for now; the relay starts in
   *dry-run* mode until a `.p8` key is mounted. Set `NAS_RELAY_IMAGE` to the
   image you publish on Docker Hub, Aliyun, Forgejo, or another registry.
2. **Deploy via Portainer** — Stacks → Add stack, paste the contents of
   `docker-compose.yml`, attach `.env` under "Environment variables", deploy.
   If the selected image is private, log in to that registry on the NAS first.
   For public Docker Hub or Aliyun images, no registry login is required for
   normal pulls.
3. **Verify**:
   ```bash
   curl http://<qnap-ip>:8787/api/health
   ```
   Should return JSON with `sonos.discoveryStatus: "ready"` and at least one
   entry under `groups[]`. The first sample takes a few seconds while the relay
   enumerates speakers. If your network blocks multicast discovery, set
   `SONOS_SEED_IP` to any always-on speaker IP and restart the stack.
   If you deploy the Hue EDK sidecar separately, check it on the NAS itself:
   ```bash
   curl http://127.0.0.1:8788/health
   ```
   The sidecar usually binds to loopback, so this check is not expected to work
   from another LAN device. If no sidecar is running, the relay can still run
   normal Sonos, APNs, diagnostics, and non-sidecar Hue paths.
4. **Open the iOS app settings**. Leave the Relay URL field blank. The app
   browses for `_charmrelay._tcp` and uses the first healthy relay it finds.
   Enter a manual URL only for cross-subnet networks, tunnels, or Bonjour
   discovery failures.
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
3. Drop the `.p8` into the mounted volume:
   ```bash
   ssh admin@<qnap>
   cp ~/AuthKey_ABCDEF1234.p8 /share/Data/nas-relay/data/apns.p8
   chmod 600 /share/Data/nas-relay/data/apns.p8
   ```
4. Update `.env`:
   ```
   APNS_KEY_ID=ABCDEF1234
   APNS_TEAM_ID=3MSS7DJGVR
   APNS_PRODUCTION=false   # Xcode debug/sandbox APNs
   ```
5. Restart the stack. Relay log will print `APNs provider ready` instead of
   `running in DRY-RUN mode`. `/api/health` also reports `apns.mode: "ready"`
   when the key is usable, or `apns.mode: "dry-run"` with missing fields when
   setup is incomplete.

Set `APNS_PRODUCTION=true` for TestFlight or App Store builds. Keep it
`false` for Xcode-installed debug builds because those use APNs sandbox
tokens.

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
| GET    | `/api/artwork`                        | query: `url=<http-or-https-artwork-url>`                        | Cached artwork proxy for iOS player/group art fallback   |
| GET    | `/api/animated-artwork/url`           | query: `url=<apple-music-album-url>&country=<storefront?>`      | Resolves cached Apple Music animated artwork by album URL |
| GET    | `/api/animated-artwork/search`        | query: `artist=<artist>&album=<album>&country=<storefront?>`    | Resolves cached Apple Music animated artwork by metadata |
| POST   | `/api/artwork-hints`                  | `{ hints: [{ title, artist, album, artworkUrl, ... }] }`        | Stores app-known CDN artwork hints for relay snapshots   |
| POST   | `/api/register-push-to-start`         | `{ groupId, token, clientId?, speakerName?, liveActivityStyleRaw? }` | Stores iOS ActivityKit push-to-start tokens              |
| POST   | `/api/register-activity`              | `{ groupId, token, attributes? }`                               | Called by iOS on every push-token rotation               |
| DELETE | `/api/register-activity/:token`       | path: `:token`                                                  | Called by iOS when the Live Activity ends                |
| GET    | `/api/hue-ambience/status`            | —                                                               | Hue runtime status without exposing the Hue app key      |
| PUT    | `/api/hue-ambience/config`            | complete config uploaded by iOS                                 | Stores Bridge key, resources, assignments, and settings  |
| DELETE | `/api/hue-ambience/config`            | —                                                               | Removes stored Hue config and stops active ambience      |
| POST   | `/api/cs2/gamestate`                  | Valve CS2 Game State Integration JSON                           | Receives and caches the latest CS2 state per SteamID     |
| GET    | `/api/cs2/status`                     | —                                                               | Summarized latest CS2 state for each connected SteamID   |
| GET    | `/api/cs2/debug/recent`               | —                                                               | Recent raw CS2 payload samples for field inspection      |
| DELETE | `/api/cs2/debug/recent`               | —                                                               | Clears recent CS2 debug samples                          |
| GET    | `/api/cs2/debug/stream`               | —                                                               | SSE stream of raw CS2 payload samples as they arrive     |

### Counter-Strike 2 Game State Integration

Create this file on the gaming PC:

```
C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg\gamestate_integration_charm.cfg
```

Use the relay host or NAS IP in the `uri`:

```text
"Charm Sonos Relay"
{
 "uri" "http://<relay-ip-or-hostname>:8787/api/cs2/gamestate"
 "timeout" "5.0"
 "buffer" "0.1"
 "throttle" "0.1"
 "heartbeat" "5.0"
 "data"
 {
   "provider" "1"
   "map" "1"
   "round" "1"
   "player_id" "1"
   "player_state" "1"
   "player_match_stats" "1"
 }
}
```

After launching CS2 and joining a match, verify ingestion:

```bash
curl http://<relay-ip-or-hostname>:8787/api/cs2/status
```

You should see a `providers[]` entry with the provider SteamID, player name,
team, health, flash/burning values, bomb state, and map name.

For field research, clear existing samples and then listen to the live debug
stream while performing one action at a time in game:

```bash
curl -X DELETE http://<relay-ip-or-hostname>:8787/api/cs2/debug/recent
curl -N http://<relay-ip-or-hostname>:8787/api/cs2/debug/stream
```

Each `event: state` message contains the raw Valve GSI payload plus relay
metadata such as the provider SteamID, receive time, and request source IP.

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

`groupId` is whatever string the iOS app assigns to a Sonos coordinator —
it doesn't have to match Sonos's internal `RINCON_…` UUID, the only
requirement is that the same value is used both in `register-activity`
and inside the relay (it does today via the bridge's `groupName ?? uuid`).

## Layout

```
nas-relay/
├── docker-compose.yml      # Portainer stack
├── Dockerfile              # multi-stage Node 24 alpine build
├── .env.example
├── package.json / tsconfig.json
├── data/                   # mounted volume — tokens.json, apns.p8 live here
└── src/
    ├── index.ts            # Express + wire-up
    ├── artworkRoutes.ts    # /api/artwork cached artwork proxy
    ├── animatedArtworkRoutes.ts # /api/animated-artwork/*
    ├── animatedAppleMusicArtwork.ts # Apple Music animated artwork resolver/cache
    ├── cs2GameState.ts     # CS2 GSI state cache and event emitter
    ├── cs2Routes.ts        # /api/cs2/*
    ├── cs2Types.ts         # CS2 GSI payload models
    ├── bonjour.ts          # mDNS/Bonjour advertisement for iOS relay discovery
    ├── hueAmbienceService.ts # Sonos snapshots → Hue ambience runtime
    ├── hueClient.ts        # Hue CLIP v2 client
    ├── hueConfigStore.ts   # disk-backed Hue config
    ├── huePalette.ts       # deterministic fallback palettes
    ├── hueRenderer.ts      # basic/gradient light update bodies
    ├── hueRoutes.ts        # /api/hue-ambience/*
    ├── hueTypes.ts         # Hue config/resource models
    ├── internalSonosRoutes.ts  # /internal/sonos/* for Python agent
    ├── sonos.ts            # @svrooij/sonos bridge
    ├── apns.ts             # @parse/node-apn wrapper + dry-run
    ├── tokenStore.ts       # disk-backed token registry
    └── types.ts            # mirrors iOS ContentState shape
```

## Future phases

- Phase 2 polish: external access (Tailscale / DDNS IPv6), token rotation
  edge cases, direct album-art embedding in APNs payloads, multi-group iOS UI.
- Auth: shared-secret header on register/unregister once we leave the LAN.
- Observability: Prometheus `/metrics` if it ever feels needed.
