# cs2-hue-sync Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create an independent `cs2-hue-sync` project and remove CS2/EDK sidecar coupling from Charm Player.

**Architecture:** `cs2-hue-sync` is a Node/TypeScript server with a bundled EDK worker process copied from the current sidecar. Charm Player keeps Music Hue Ambience on CLIP v2 and no longer owns CS2 state, lighting, or sidecar deployment.

**Tech Stack:** Node 20, TypeScript, Express, Pino, native Hue EDK worker, Docker Compose, SwiftUI cleanup in Charm Player.

---

### Task 1: Create Independent Project Skeleton

**Files:**
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/package.json`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/tsconfig.json`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/src/index.ts`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/src/health.test.ts`

- [ ] Write a failing health route test for `/api/health`.
- [ ] Implement the minimal Express app and startup module.
- [ ] Run `npm test` in `/Users/charm/Documents/workspace/cs2-hue-sync`.

### Task 2: Move CS2 GSI State and Routes

**Files:**
- Copy/adapt: `nas-relay/src/cs2GameState.ts`
- Copy/adapt: `nas-relay/src/cs2Routes.ts`
- Copy/adapt: `nas-relay/src/cs2Types.ts`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/src/cs2GameState.test.ts`

- [ ] Port the existing CS2 game state route tests and verify they fail before code is copied.
- [ ] Copy the CS2 state service, types, and router.
- [ ] Run the CS2 route tests until they pass.

### Task 3: Bundle EDK Worker

**Files:**
- Copy/adapt: `/Users/charm/Documents/workspace/HueEdkSidecar/src`
- Copy/adapt: `/Users/charm/Documents/workspace/HueEdkSidecar/native`
- Copy/adapt: `/Users/charm/Documents/workspace/HueEdkSidecar/scripts`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/src/edkWorkerClient.ts`

- [ ] Add a test proving server health includes worker health when the worker endpoint responds.
- [ ] Copy the worker implementation into the new project.
- [ ] Implement the server-side worker client.
- [ ] Run tests.

### Task 4: Move CS2 Lighting Rules

**Files:**
- Copy/adapt: `nas-relay/src/cs2Lighting.ts`
- Copy/adapt: Hue frame/rendering primitives required by CS2
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/src/cs2Lighting.test.ts`

- [ ] Port a focused subset of existing CS2 lighting tests for ambient, flash, kill, planted bomb, and worker command behavior.
- [ ] Copy the existing lighting rule engine and Hue EDK renderer plumbing.
- [ ] Wire game state events to lighting decisions in the new server.
- [ ] Run tests.

### Task 5: Add Dashboard

**Files:**
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/src/dashboard.ts`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/public/index.html`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/public/app.js`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/public/styles.css`

- [ ] Add a test proving `/` serves the dashboard shell.
- [ ] Implement a compact dashboard that reads `/api/health`, `/api/cs2/status`, and `/api/cs2/debug/recent`.
- [ ] Run tests and inspect the dashboard locally if the server starts.

### Task 6: Add Deployment Files

**Files:**
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/Dockerfile`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/docker-compose.yml`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/.env.example`
- Create: `/Users/charm/Documents/workspace/cs2-hue-sync/README.md`

- [ ] Add compose config for `server` and `edk-worker`.
- [ ] Document CS2 GSI endpoint and Hue setup config.
- [ ] Verify `docker compose config` succeeds.

### Task 7: Clean Charm Player

**Files:**
- Modify: `/Users/charm/Documents/workspace/SonosWidget/nas-relay/src/index.ts`
- Modify: `/Users/charm/Documents/workspace/SonosWidget/nas-relay/src/httpLogging.ts`
- Modify: `/Users/charm/Documents/workspace/SonosWidget/nas-relay/docker-compose.yml`
- Modify: `/Users/charm/Documents/workspace/SonosWidget/nas-relay/.env.example`
- Modify: `/Users/charm/Documents/workspace/SonosWidget/Shared/*.swift`
- Modify: `/Users/charm/Documents/workspace/SonosWidget/SonosWidget/*.swift`

- [ ] Remove CS2 service wiring and health payloads.
- [ ] Remove iOS CS2 settings/status UI and persisted CS2 settings.
- [ ] Remove sidecar compose service and EDK environment variables.
- [ ] Run nas-relay tests/build and the relevant Swift build if available.
