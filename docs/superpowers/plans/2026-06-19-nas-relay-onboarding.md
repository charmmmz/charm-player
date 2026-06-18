# NAS Relay Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the NAS relay and iOS app discover each other automatically, with Sonos seed IP and APNs values reduced to optional configuration.

**Architecture:** The Node relay starts Sonos with either a provided seed IP or SSDP discovery, exposes discovery/APNs metadata in `/api/health`, and advertises `_charmrelay._tcp` on the LAN. The iOS app browses that Bonjour service only when no manual relay URL is set, probes candidates with the existing health client, and keeps manual configuration as the override.

**Tech Stack:** TypeScript/Node/Express, `@svrooij/sonos`, Bonjour/mDNS advertisement, Swift Network.framework, SwiftUI Settings.

---

### Task 1: Relay Sonos Discovery And Health Metadata

**Files:**
- Modify: `nas-relay/src/sonos.ts`
- Modify: `nas-relay/src/index.ts`
- Test: `nas-relay/src/sonos.test.ts`

- [x] Write failing tests for `SonosBridge.start()` choosing automatic discovery when no seed IP is provided and seed discovery when a seed IP is present.
- [x] Run `npm test -- src/sonos.test.ts` from `nas-relay` and confirm the new tests fail because `start()` currently requires a seed argument.
- [x] Implement `SonosBridge.start(seedIp?: string)` using `InitializeWithDiscovery(timeout)` when no seed is provided, and expose `discoveryMode`/`discoveryStatus`.
- [x] Update `/api/health` to include `sonos.discoveryMode`, `sonos.discoveryStatus`, and `sonos.discoveryError`.
- [x] Run `npm test -- src/sonos.test.ts` from `nas-relay` and confirm the tests pass.

### Task 2: Relay APNs Health Metadata

**Files:**
- Modify: `nas-relay/src/apns.ts`
- Modify: `nas-relay/src/index.ts`
- Test: `nas-relay/src/apns.test.ts`

- [x] Write failing tests for APNs status reporting: ready when provider is configured, dry-run when key metadata or key file is missing.
- [x] Run `npm test -- src/apns.test.ts` from `nas-relay` and confirm the tests fail because no status API exists.
- [x] Add an `ApnsClient.status()` method that returns mode, environment, bundle ID, key ID presence, team ID presence, and key file presence.
- [x] Include `apns` metadata in `/api/health`.
- [x] Run `npm test -- src/apns.test.ts` from `nas-relay` and confirm the tests pass.

### Task 3: Relay Bonjour Advertisement

**Files:**
- Modify: `nas-relay/package.json`
- Modify: `nas-relay/package-lock.json`
- Create: `nas-relay/src/bonjour.ts`
- Modify: `nas-relay/src/index.ts`
- Test: `nas-relay/src/bonjour.test.ts`

- [x] Add a test for creating the relay Bonjour advertisement with service type `_charmrelay._tcp`, relay port, and health path TXT metadata.
- [x] Run `npm test -- src/bonjour.test.ts` and confirm it fails because the module does not exist.
- [x] Add a small Bonjour publisher wrapper and start it after Express listens.
- [x] Ensure publisher shutdown is best effort and does not block relay startup if mDNS fails.
- [x] Run `npm test -- src/bonjour.test.ts`.

### Task 4: iOS Relay Auto-Discovery

**Files:**
- Create: `Shared/RelayDiscovery.swift`
- Modify: `Shared/RelayClient.swift`
- Modify: `Shared/RelayManager.swift`
- Modify: `SonosWidget/Info.plist`
- Test: `SonosWidgetTests/RelayDiscoveryTests.swift`

- [x] Add pure helper tests for choosing manual URL over discovered URL and building HTTP relay URLs from host/port.
- [x] Run the iOS test target and confirm the new tests fail because the helper does not exist.
- [x] Implement `RelayDiscovery` with Network.framework Bonjour browsing for `_charmrelay._tcp`.
- [x] Update `RelayManager` to start discovery when `urlString` is empty, probe candidates, and keep manual URL as the override.
- [x] Add `_charmrelay._tcp` to `NSBonjourServices`.
- [x] Run the iOS tests.

### Task 5: Settings And Docs

**Files:**
- Modify: `SonosWidget/SettingsView.swift`
- Modify: `nas-relay/.env.example`
- Modify: `.env.stack.example`
- Modify: `nas-relay/docker-compose.yml`
- Modify: `nas-relay/README.md`
- Modify: `README.md`

- [x] Update Settings text so blank relay URL means auto-discovery.
- [x] Display APNs status and environment from relay health.
- [x] Remove `SONOS_SEED_IP` from required examples and document it as optional fallback.
- [x] Add APNs minimum setup docs: put `.p8` in `/app/data/apns.p8`, set `APNS_KEY_ID` if not baked in, and set `APNS_PRODUCTION=true` for TestFlight.
- [x] Run relay tests and available iOS build/tests.
