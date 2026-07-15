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

- Fast Sonos room control from a compact Home dashboard, with speaker cards,
  playback controls, volume, grouping, queue access, artwork, and source state.
- Apple Music feels native: browse library content through MusicKit, send Apple
  Music share links into Charm Player, hand off playback between iPhone and
  Sonos, and show animated album artwork when available.
- Live Activity and Dynamic Island keep now playing visible, with Lock Screen
  controls and optional NAS relay updates that stay fresh after the app is
  suspended.
- Hue Ambience syncs the room to the music, using album colors to drive mapped
  Hue rooms, lights, or Entertainment Areas from the phone or the NAS relay.

## Setup Options

Sonos Cloud sign-in and `nas-relay` are independent. You can use the app without
either one, but they unlock different parts of the experience.

**App only, same Wi-Fi**

- Best for basic local control.
- Available: speaker discovery, play/pause, skip, volume, grouping, queue edits,
  and cached widgets.
- Limited: no Sonos Cloud browsing, no Apple Music-to-Sonos matching, and Live
  Activities may stop refreshing after iOS suspends the app.

**Sonos Cloud signed in**

- Best for full music browsing and handoff.
- Available: Cloud browse/search, linked services, Apple Music matching, Local
  Service playback, and share extension playback.
- Limited: background Live Activity updates still need the relay.

**`nas-relay` only**

- Best for better background behavior at home.
- Available: local control plus relay diagnostics, production APNs updates,
  push-to-start, and background Hue Ambience.
- Limited: no Cloud browse/search or Apple Music matching without Sonos Cloud.

**Sonos Cloud + `nas-relay`**

- Best home/TestFlight setup.
- Available: full browsing, Apple Music transfer, share extension, fresh Live
  Activities, diagnostics, and always-on Hue Ambience.
- Limited: requires both Sonos account setup and a reachable home relay.

### What the relay changes

**Live Activity refresh**

- Without relay: local updates only while the app, widget, or system extension
  can execute; state may go stale after suspension.
- With relay: APNs updates keep the Lock Screen and Dynamic Island current, and
  push-to-start can create a Live Activity after playback starts.

**Animated Apple Music artwork**

- Without relay: uses only artwork the app can resolve locally while it is
  active.
- With relay: resolves Apple Music album URLs or artist/album metadata to
  animated artwork URLs, caches results, and provides a NAS fallback for player
  and album surfaces.

**Artwork fallback**

- Without relay: uses app and shared-container caches.
- With relay: proxies and caches artwork URLs, and accepts app-provided artwork
  hints for later snapshots.

**Hue Ambience**

- Without relay: phone-side control can stop when the app is suspended.
- With relay: NAS-side ambience can keep running for active Sonos groups.

**Diagnostics**

- Without relay: mostly local logs and app-visible state.
- With relay: relay health, APNs readiness, device logs, Hue runtime, and recent
  Sonos snapshots are visible from the NAS path.

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
- LAN MCP control from compatible external agents without hosting an LLM on
  the NAS.
- A built-in LAN dashboard for status, playback, Hue, MCP, Live Activity, and
  recent diagnostics at `http://<nas-host>:8787/dashboard/`.

Quick start:

1. Copy [`.env.stack.example`](.env.stack.example) to `.env`.
2. Set `MCP_API_TOKEN` (also used by the dashboard unless
   `DASHBOARD_TOKEN` is set), the optional internal token, and APNs values.
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
