# Charm for Sonos

> **Charm Player** is a private iPhone companion for Sonos. It focuses on the
> places where Sonos control should be faster: Home, Apple Music handoff,
> widgets, Lock Screen, Dynamic Island, and optional NAS-backed background
> updates.

[![iOS 18.6+](https://img.shields.io/badge/iOS-18.6%2B-111111?style=flat-square&logo=apple)](#requirements)
[![TestFlight Ready](https://img.shields.io/badge/TestFlight-Ready-0A84FF?style=flat-square&logo=appstore)](#testflight)
[![Sonos Cloud Optional](https://img.shields.io/badge/Sonos%20Cloud-Optional-0A84FF?style=flat-square)](#setup-options)
[![NAS Relay Optional](https://img.shields.io/badge/NAS%20Relay-Optional-3A7D44?style=flat-square)](#optional-nas-relay)

Charm Player is built for a home Sonos setup where the phone should feel like a
real controller, not just a place to open another app. It keeps common actions
close, makes Apple Music handoff deliberate, and can use a home relay when iOS
would otherwise suspend the app.

## Highlights

- Fast Sonos room control from a compact Home dashboard.
- Speaker cards with artwork, source, playback state, volume, and grouping.
- Apple Music handoff between iPhone and Sonos.
- `Play in Charm Player` share action for Apple Music links.
- Home Screen widgets for quick status and actions.
- Live Activity and Dynamic Island controls for now playing.
- Optional NAS relay for fresher background updates, animated artwork helpers,
  and remote diagnostics.
- Optional Hue Ambience that reacts to the current album artwork.

## Setup Options

Sonos Cloud sign-in and `nas-relay` are independent. You can use the app without
either one, but they unlock different parts of the experience.

| Setup | Best for | Available | Limited |
| --- | --- | --- | --- |
| App only, same Wi-Fi | Basic local control | Discover speakers, play/pause, skip, volume, grouping, queue edits, cached widgets | No Sonos Cloud browsing, no Apple Music-to-Sonos matching, Live Activities may stop refreshing after iOS suspends the app |
| Sonos Cloud signed in | Full music browsing and handoff | Cloud browse/search, linked services, Apple Music matching, Local Service playback, share extension playback | Background Live Activity updates still need the relay |
| `nas-relay` only | Better background behavior at home | Local control plus relay diagnostics, production APNs updates, push-to-start, background Hue Ambience | No Cloud browse/search or Apple Music matching without Sonos Cloud |
| Sonos Cloud + `nas-relay` | Best home/TestFlight setup | Full browsing, Apple Music transfer, share extension, fresh Live Activities, diagnostics, always-on Hue Ambience | Requires both Sonos account setup and a reachable home relay |

### What the relay changes

| Capability | Without `nas-relay` | With `nas-relay` |
| --- | --- | --- |
| Live Activity refresh | Local updates only while the app, widget, or system extension can execute; state may go stale after suspension | APNs updates keep the Lock Screen and Dynamic Island current, and push-to-start can create a Live Activity after playback starts |
| Animated Apple Music artwork | Uses only artwork the app can resolve locally while it is active | Relay can resolve Apple Music album URLs or artist/album metadata to animated artwork URLs, cache results, and provide a NAS fallback for player and album surfaces |
| Artwork fallback | Uses app and shared-container caches | Relay can proxy/cache artwork URLs and accept app-provided artwork hints for later snapshots |
| Hue Ambience | Phone-side control can stop when the app is suspended | NAS-side ambience can keep running for active Sonos groups |
| Diagnostics | Mostly local logs and app-visible state | Relay health, APNs readiness, device logs, Hue runtime, and recent Sonos snapshots are visible from the NAS path |

In short:

- Sign in to Sonos Cloud if you want music browsing, linked service playback, or
  Apple Music handoff to Sonos.
- Deploy `nas-relay` if you want Live Activities and Hue Ambience to keep
  updating while Charm Player is not open, or if you want relay-backed animated
  artwork lookup and diagnostics.
- Use both if you want the complete experience.

## Core Flows

### Control Sonos

Charm Player discovers Sonos speakers on the local network and presents them as
room and group cards. The main controls cover playback, volume, grouping,
ungrouping, queue browsing, queue edits, and saved room order.

### Move Apple Music

The `HANDOFF` action chooses the useful direction automatically:

- If Sonos is playing, bring playback back to the iPhone.
- If Sonos is idle or paused, send the current iPhone Apple Music item to Sonos.

Apple Music browsing and the share extension are designed around the same idea:
find music on the phone, then send it to the right Sonos room when the Sonos
account and Apple Music service can be matched.

### Keep iOS Surfaces Fresh

Widgets, Live Activities, and Dynamic Island controls make the current room
available outside the main app. Without the relay they use the latest app-known
state. With `nas-relay`, the home server can continue forwarding updates through
APNs after the app is suspended.

### Light the Room

Hue Ambience can map Sonos rooms to Hue rooms, lights, or Entertainment Areas.
Phone-side ambience works while the app is active. Relay-side ambience can keep
running in the background at home.

## Requirements

- iOS 18.6 or later.
- A Sonos system on the same network for local control.
- Local Network permission on iPhone.
- Optional: Sonos Cloud sign-in for browsing, linked services, and Apple Music
  handoff.
- Optional: Apple Music permission and an active Apple Music account for Apple
  Music flows.
- Optional: `nas-relay` for background Live Activity updates, animated artwork
  lookup, diagnostics, and background Hue Ambience.

## First Run

1. Install Charm Player from TestFlight or a trusted local build.
2. Open the app once while connected to the same Wi-Fi as the Sonos system.
3. Grant Local Network permission.
4. Confirm the Home dashboard shows the expected rooms.
5. Sign in to Sonos Cloud if you want browsing, Apple Music handoff, Local
   Service playback, or share extension playback.
6. Configure `nas-relay` only if you want background Live Activity updates,
   push-to-start, animated artwork lookup, relay diagnostics, or background Hue
   Ambience.

## Optional NAS Relay

`nas-relay` is a home-server companion. It listens to Sonos state on the LAN and
forwards selected updates to the iPhone through APNs.

Use it when you want:

- Live Activities to stay current while Charm Player is not open.
- Relay-led push-to-start for Live Activities.
- Relay-backed animated Apple Music artwork lookup and caching.
- Background Hue Ambience.
- Relay health, APNs status, and remote diagnostic logs.

Quick start:

1. Copy [`.env.stack.example`](.env.stack.example) to `.env`.
2. Set the internal token, optional agent token, and APNs values.
3. Leave `SONOS_SEED_IP` blank unless multicast discovery is blocked.
4. Run `docker compose up -d --build`.

Full relay setup lives in [nas-relay/README.md](nas-relay/README.md).

For TestFlight and App Store builds, the relay should use production APNs. Local
debug builds installed from Xcode use APNs sandbox tokens.

## TestFlight

Current first TestFlight build: `1.0 (1)`.

What to test:

- First launch, Local Network permission, and room discovery.
- Playback controls: play/pause, skip, seek, volume, shuffle, repeat.
- Grouping, ungrouping, queue viewing, and queue edits.
- Sonos Cloud sign-in, browse/search, and linked service playback.
- Apple Music handoff from iPhone to Sonos and back.
- `Play in Charm Player` from Apple Music share sheet.
- Widgets, Live Activity, Dynamic Island, and relay-backed refreshes.
- Hue Ambience mapping and background behavior if the relay is configured.

Before uploading another TestFlight build, increase the build number if App
Store Connect already has the same version/build pair.

## Private Project Note

This README is written for testers, daily use, and operating the private home
setup. Internal maintainer notes are kept separately and are not the focus of
this document.
