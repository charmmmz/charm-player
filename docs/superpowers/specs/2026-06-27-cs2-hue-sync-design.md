# cs2-hue-sync Design

## Goal

Split Counter-Strike 2 lighting out of Charm Player into a fully independent project named `cs2-hue-sync`.

## Product Boundary

Charm Player owns Sonos, Live Activity, and Music Hue Ambience. Music Hue Ambience uses Hue CLIP v2 color rotation and does not depend on Hue Entertainment streaming or an EDK sidecar.

`cs2-hue-sync` owns all CS2 concerns: Valve Game State Integration ingestion, CS2 lighting decisions, Hue Bridge setup for an Entertainment Area, Hue Entertainment streaming, EDK native effects, diagnostics, and a browser dashboard.

## Runtime Shape

`cs2-hue-sync` is one project and one compose stack with two processes:

- `server`: Node/TypeScript HTTP server. It accepts CS2 GSI posts, stores current state, serves dashboard assets, exposes JSON/SSE APIs, persists Hue config, and converts game state into lighting decisions.
- `edk-worker`: internal Hue EDK HTTP worker copied from the current sidecar implementation. It owns the native EDK worker process, Hue Entertainment session lifecycle, and native effects.

The server talks to the worker over a private HTTP URL. Users deploy only `cs2-hue-sync`; they do not deploy Charm Player or a separate sidecar for CS2.

## Web Dashboard

The first dashboard shows:

- service health and worker health
- configured Hue Bridge and selected Entertainment Area
- current CS2 provider, player, map, round, bomb, and weapon state
- current lighting mode, active area, transport, and fallback reason
- recent raw GSI samples and diagnostic lighting decisions

Setup actions are API-first in this pass. The UI can display config and provide copyable endpoint details; full browser pairing UX can be added after the split is stable.

## Charm Player Cleanup

Charm Player removes:

- CS2 GSI route and service wiring
- CS2 lighting service
- CS2 settings/status from iOS UI and relay health models
- sidecar service and EDK environment variables from `nas-relay/docker-compose.yml`

Charm Player keeps Hue Bridge pairing and CLIP v2 Music Ambience.

## Migration Principle

The first implementation should preserve existing CS2 lighting behavior by moving the tested code rather than rewriting the effect rules. Naming cleanup can follow once `cs2-hue-sync` is independently deployable and verified.
