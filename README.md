# Charm for Sonos

> Charm Player is a personal iOS control surface for Sonos: LAN-first playback,
> Apple Music handoff, widgets, Live Activities, Dynamic Island controls, and
> optional NAS-backed APNs updates.

[![iOS 18.6+](https://img.shields.io/badge/iOS-18.6%2B-111111?style=flat-square&logo=apple)](#requirements)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-0A84FF?style=flat-square&logo=swift&logoColor=white)](#tech-stack)
[![TestFlight Ready](https://img.shields.io/badge/TestFlight-Ready-0A84FF?style=flat-square&logo=appstore)](#testflight--release-status)
[![Sonos LAN + Cloud](https://img.shields.io/badge/Sonos-LAN%20%2B%20Cloud-000000?style=flat-square)](#control-model)
[![NAS Relay](https://img.shields.io/badge/NAS%20Relay-Optional-3A7D44?style=flat-square)](#optional-live-activity-relay-nas--home-server)

Charm for Sonos fills a narrow but useful gap: Sonos playback should feel close
to the iOS surfaces people already use. The shipping iOS app is named
**Charm Player**. It gives Sonos systems a Home dashboard, a system-level now
playing presence, Apple Music transfer flows, and optional home-server support
for fresh Lock Screen updates while the app is suspended.

## Current Status

- App target: `com.charm.SonosWidget`
- App display name: `Charm Player`
- Version prepared for TestFlight: `1.0 (1)`
- App Store Connect build export has been validated with production signing.
- Privacy manifests are present for the main app, widget extension, and Apple
  Music share extension.
- Production APNs support is expected through the optional `nas-relay/` service;
  the APNs key belongs on the relay host, not in the iOS bundle.

## At A Glance

| Area | What Charm Player adds |
| --- | --- |
| Home control | Speaker and group cards, transport controls, volume, grouping, queue views, and saved speaker order |
| iOS surfaces | Home Screen widgets, Lock Screen Live Activities, Dynamic Island, and AppIntent controls |
| Apple Music | iPhone-to-Sonos handoff, Sonos-to-iPhone reverse handoff, local library browsing, and share extension playback |
| Network paths | LAN-first Sonos control with Sonos Cloud sign-in for browse/search and fallback paths |
| Hue Ambience | Album-color lighting mapped from Sonos rooms to Hue rooms, lights, or Entertainment Areas |
| Background updates | Optional NAS relay forwards Sonos state to ActivityKit through production APNs |

## Feature Availability By Setup

Sonos Cloud sign-in and `nas-relay` deployment are independent. The app can run
with neither, one, or both:

- **Sonos Cloud sign-in** unlocks account-backed Sonos features: linked music
  services, cloud browse/search, remote-capable fallback control, and Apple
  Music matching for handoff.
- **`nas-relay` deployment** unlocks home-server behavior: APNs Live Activity
  updates while the app is suspended, relay-led push-to-start, relay command
  routing, relay artwork helpers, diagnostics upload, and always-on Hue
  Ambience.

| Capability | No Sonos Cloud | Sonos Cloud signed in | No `nas-relay` | `nas-relay` deployed |
| --- | --- | --- | --- | --- |
| Same-Wi-Fi Sonos discovery and Home controls | Available through LAN/UPnP | Available, with Cloud fallback when needed | Unaffected | Unaffected |
| Play/pause, next/previous, volume, seek | Available on LAN | Available on LAN or Cloud-capable remote path | Unaffected | Relay can also route some Live Activity/widget commands |
| Grouping, ungrouping, queue edits, play mode changes | Available on LAN | Still LAN-only; Cloud mode shows a same-network requirement | Unaffected | Unaffected |
| Sonos Cloud browse/search, favorites, playlists, radio, linked service list | Unavailable or limited to cached/local metadata | Available | Unaffected | Can submit artwork hints to relay when available |
| Apple Music handoff between iPhone and Sonos | Unavailable; matching requires Sonos Cloud and linked Apple Music | Available when Apple Music is linked in the Sonos household | Unaffected | Unaffected |
| Local Service browsing from Apple Music library | Available with Apple Music permission | Available | Unaffected | Optional animated-artwork/relay helpers can improve some artwork paths |
| Playing Local Service items on Sonos | Effectively unavailable for first-time setup; it needs a detected Sonos Apple Music account and local service-ID mapping | Available on LAN after Cloud-linked Apple Music is detected and mapped to local Sonos service ID | Unaffected | Unaffected |
| Apple Music share extension playback | Effectively unavailable until the app has stored a Sonos Apple Music share credential and same-network speaker state | Available after the app has detected the linked Apple Music service and stored the share credential | Unaffected | Unaffected |
| Home Screen widget | Shows shared cached state and can run local AppIntent paths | Same, with better Cloud-backed metadata where available | Works from shared app state | Can use relay command/artwork paths when token and relay are available |
| Live Activity and Dynamic Island | Local updates only while the app or extension can execute | Same | Local ActivityKit updates only; state may go stale after suspension | APNs updates keep state fresh after suspension; push-to-start can create an activity after playback starts |
| Hue Ambience | Phone-side Hue control can run on LAN | Same | Stops depending on the app process and local availability | NAS can keep Hue Ambience running per active Sonos group |
| Diagnostics and remote logs | Local diagnostics only | Same | Local diagnostics only | Relay health, APNs status, device logs, and Hue runtime state become visible from the NAS path |

Recommended configurations:

1. **Basic same-Wi-Fi control:** no Cloud, no relay. Use this for local playback,
   grouping, queue edits, and quick Home controls.
2. **Full in-app music experience:** Sonos Cloud signed in, no relay. Use this
   for browse/search, Apple Music handoff, Local Service playback to Sonos, and
   share extension playback while accepting that Live Activities may become
   stale after suspension.
3. **Best TestFlight/home setup:** Sonos Cloud signed in and `nas-relay`
   deployed with production APNs. This enables the full app surface plus fresh
   Lock Screen updates and always-on Hue Ambience.

## Key Features

### Sonos Control

- Discovers Sonos speakers on the local network with SSDP and supports manual IP
  entry when discovery is not enough.
- Shows Home speaker cards for groups and coordinators, with now playing
  metadata, source badges, album art, audio-quality labels, and TV-audio
  affordances where available.
- Routes playback commands through a shared `SonosControl` layer so LAN commands
  are preferred and Sonos Cloud fallback is used only where an equivalent remote
  operation exists.
- Supports play/pause, skip, previous, seek, shuffle, repeat, group volume,
  speaker volume, queue reads, queue edits, grouping, ungrouping, and Home card
  ordering.

### Apple Music

- Provides a Home-screen `HANDOFF` action that chooses direction from current
  Sonos state: active Sonos playback moves back to iPhone, idle Sonos targets
  receive the current iPhone Apple Music item.
- Resolves Apple Music catalog matches through Sonos Cloud and local matching
  helpers before starting playback, instead of sending weak guesses.
- Rebuilds Apple Music queue context for supported reverse handoff cases when
  Sonos queue items resolve to Apple Music store IDs.
- Adds a Local Service tab for MusicKit-powered songs, albums, artists,
  playlists, stations, recommendations, and recently played content.
- Includes an Apple Music share extension named `Play in Charm Player` for
  sending shared Apple Music links directly to a selected Sonos target.

### Widgets And Live Activities

- Home Screen widget timelines read shared app-group state and expose AppIntent
  controls for common playback actions.
- Live Activity and Dynamic Island layouts show current track state, transport
  controls, volume controls, source hints, group size, and artwork when cached or
  relay-provided data is available.
- The app can start Live Activities locally, and the relay can keep them updated
  over APNs after the app is suspended.

### Hue Ambience

- Settings include a dedicated Hue Ambience area for pairing a Hue Bridge,
  loading rooms/lights, mapping Sonos rooms to Hue targets, and tuning album
  color behavior.
- Phone-side control applies palette changes through Hue CLIP v2.
- Relay-side control can keep ambience running while the app is backgrounded.
- Entertainment Area mappings can use the Hue EDK sidecar path when the relay
  stack is configured for it, with CLIP v2 fallback where appropriate.

### Diagnostics

- Settings include diagnostics and relay status surfaces for troubleshooting
  Sonos state, relay health, APNs readiness, and Hue ambience status.
- The relay exposes health and debug endpoints that make device-log-first
  debugging faster than reaching for local device containers.

## Screenshots

Screenshots are not committed yet. Good App Store/TestFlight capture slots:

- Home dashboard with speaker cards and the mini-player
- Full now playing view with artwork and source badge
- Local Service browsing for Apple Music library content
- Apple Music share extension target picker
- Lock Screen Live Activity and Dynamic Island
- Hue Ambience settings and relay status

## Requirements

- iOS 18.6+
- A Sonos system on the tester's account or local network
- Same-network access for LAN-only features such as grouping, queue mutation,
  local control, and Hue Bridge pairing
- Sonos Cloud developer credentials for sign-in, cloud browse/search, and remote
  fallback paths
- Apple Music permission and an active Apple Music account for handoff, library,
  and share-extension flows
- Apple Developer capabilities for ActivityKit, WidgetKit, App Groups, and APNs
  when testing the relay-backed Live Activity path

## Setup

1. Open `SonosWidget.xcodeproj` in Xcode.
2. Build and run `SonosWidget` on a physical iPhone. Widgets, Live Activities,
   APNs, Apple Music, and Local Network prompts are not fully represented in the
   simulator.
3. Grant Local Network access when prompted.
4. Configure Sonos Cloud sign-in:
   - Register an integration at the [Sonos integration portal](https://integration.sonos.com).
   - Copy `Config/SonosSecrets.example.xcconfig` to `Config/SonosSecrets.xcconfig`.
   - Set `SONOS_OAUTH_CLIENT_ID`, `SONOS_OAUTH_CLIENT_SECRET`, and
     `SONOS_OAUTH_REDIRECT_URI`.
   - In `.xcconfig`, keep URL slashes escaped with `SLASH = /` and
     `https:$(SLASH)$(SLASH)...`; writing `https://...` directly is parsed as a
     comment.
   - Keep `SonosSecrets.xcconfig` private. It is gitignored.
5. Open the app once on the target Wi-Fi so shared storage, relay discovery,
   widget timelines, and ActivityKit token registration can initialize.

> [!NOTE]
> Apple Music handoff depends on Media Library permission, a Sonos Cloud
> session, and Apple Music being linked as a music service in the Sonos
> household.

## TestFlight & Release Status

The first TestFlight build is `1.0 (1)`.

Release-readiness checks performed for the current build:

- Release build succeeded.
- Archive succeeded.
- App Store Connect export succeeded with automatic production signing.
- Final IPA contains privacy manifests in:
  - `SonosWidget.app/PrivacyInfo.xcprivacy`
  - `SonosWidget.app/PlugIns/TheWidgetExtension.appex/PrivacyInfo.xcprivacy`
  - `SonosWidget.app/PlugIns/AppleMusicShareExtension.appex/PrivacyInfo.xcprivacy`
- Main app entitlements export with `aps-environment=production`,
  `get-task-allow=false`, and `beta-reports-active=true`.
- Embedded profiles are App Store distribution profiles for all three bundle
  IDs.

Before each new upload:

1. Bump `CURRENT_PROJECT_VERSION` only when App Store Connect already has a build
   with the same marketing version and build number.
2. Archive using the `SonosWidget` scheme for generic iOS.
3. Export or upload through Xcode Organizer with App Store Connect distribution.
4. Verify TestFlight processing, export compliance, and tester assignment in App
   Store Connect.

## Control Model

Most commands enter through `SonosControl`, which routes to:

- `LAN`: SOAP/UPnP calls to Sonos speakers on the local network through
  `SonosAPI`.
- `Cloud`: Sonos Control API and content APIs through `SonosCloudAPI` after
  OAuth sign-in.

The app prefers LAN because Sonos queue mutation, grouping, and fast state reads
are local-network operations. Cloud fallback is used for remote-capable
operations and for music search/browse metadata. If an operation has no Cloud
equivalent, the app surfaces the same-network requirement instead of pretending
the command succeeded.

## Project Layout

| Path | Role |
| --- | --- |
| `SonosWidget/` | Main SwiftUI app, tabs, Home UI, Local Service, settings, handoff orchestration, Live Activity lifecycle |
| `Shared/` | App-group storage, Sonos LAN/Cloud clients, OAuth, shared models, relay clients, Hue models, artwork helpers |
| `TheWidget/` | WidgetKit timelines, Live Activity layouts, AppIntents, widget entitlements |
| `AppleMusicShareExtension/` | UIKit share extension for Apple Music links and Sonos target selection |
| `nas-relay/` | Node.js relay for Sonos UPnP events, APNs Live Activity pushes, Hue ambience runtime, artwork helpers, CS2 GSI hooks |
| `nas-agent/` | Optional FastAPI agent that calls relay internal Sonos endpoints |
| `docs/implementation-notes/` | Human-readable notes for feature design decisions that survived implementation |
| `docs/superpowers/` | Agent plans and historical execution notes; useful as context, not the primary docs surface |

## Tech Stack

- Swift / SwiftUI / Observation
- ActivityKit for Live Activities and Dynamic Island
- WidgetKit and AppIntents for Home Screen widgets and quick actions
- MediaPlayer and MusicKit for Apple Music handoff and local library flows
- App Groups through `SharedStorage`
- SSDP, UPnP, SOAP, Sonos Cloud OAuth, and Sonos Control APIs
- Hue CLIP v2, optional Hue Entertainment/EDK sidecar relay paths
- Optional Node.js + TypeScript relay with APNs HTTP/2 delivery
- Optional Python/FastAPI NAS agent deployable with the relay through
  `compose.yml`

## Optional: Live Activity Relay (NAS / Home Server)

When the iOS app is suspended, Live Activities only stay fresh if iOS receives
ActivityKit push updates. The `nas-relay/` service subscribes to Sonos UPnP
events on the LAN and forwards now-playing updates to APNs.

- Full relay setup and API details live in [nas-relay/README.md](nas-relay/README.md).
- The relay publishes `_charmrelay._tcp`; the iOS app can usually discover it
  with the Relay URL field left blank.
- Use a manual relay URL only for cross-subnet networks, tunnels, or Bonjour
  discovery failures.
- Without an APNs `.p8` key, the relay runs in dry-run mode and still exposes
  health/discovery status.
- For TestFlight and App Store builds, set relay APNs production mode to true.
  Xcode-installed debug builds use APNs sandbox tokens.

Run the combined relay + agent stack with host networking:

1. Copy [`.env.stack.example`](.env.stack.example) to `.env` at the repo root.
   Do not commit `.env`.
2. Set `INTERNAL_API_TOKEN`, `OPENAI_API_KEY`, `AGENT_USER_TOKEN`, and APNs
   variables as needed.
3. Leave `SONOS_SEED_IP` blank unless multicast discovery is blocked.
4. Run `docker compose up -d --build`.

## Implementation Notes

- [Apple Music HANDOFF](docs/implementation-notes/apple-music-handoff.md)
- [Home speaker ordering](docs/implementation-notes/home-speaker-ordering.md)

When a working plan under `docs/superpowers/plans/` turns into durable project
knowledge, distill it into `docs/implementation-notes/` rather than leaving the
plan as the only readable reference.

## License

This is a personal project. Feel free to reference or learn from the code.
