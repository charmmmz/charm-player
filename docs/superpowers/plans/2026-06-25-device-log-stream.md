# Device Log Stream Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real-time iPhone and widget diagnostic logs to `nas-relay`.

**Architecture:** Keep local diagnostics unchanged, mirror each `SonosLog` line to the configured relay on a best-effort async path, and expose recent plus streamed logs from the relay. The relay owns buffering and stream fan-out; Swift owns lightweight request encoding and fire-and-forget sending.

**Tech Stack:** Swift, XCTest, Express, Node.js `EventEmitter`, TypeScript `node:test`, Server-Sent Events.

---

### Task 1: Relay Log Buffer and Routes

**Files:**
- Create: `nas-relay/src/deviceLogs.ts`
- Create: `nas-relay/src/deviceLogRoutes.ts`
- Create: `nas-relay/src/deviceLogRoutes.test.ts`
- Modify: `nas-relay/src/index.ts`
- Modify: `nas-relay/src/httpLogging.ts`

- [ ] **Step 1: Write failing tests**

Add tests that POST two device log entries, read them from `/api/device-logs/recent`, verify buffer bounding, and verify `/api/device-logs/stream` emits newly posted entries.

- [ ] **Step 2: Run the relay test**

Run: `npm test -- deviceLogRoutes.test.ts`
Expected: FAIL because `deviceLogRoutes.ts` does not exist yet.

- [ ] **Step 3: Implement relay service and routes**

Create a bounded in-memory service with `receive`, `recent`, and `EventEmitter` support. Add Express routes for POST, recent GET, and SSE stream. Register the router in `index.ts` and suppress HTTP auto logging for the device log endpoints.

- [ ] **Step 4: Run relay tests**

Run: `npm test -- deviceLogRoutes.test.ts`
Expected: PASS.

### Task 2: Swift Remote Log Client

**Files:**
- Modify: `Shared/RelayClient.swift`
- Modify: `Shared/SonosLog.swift`
- Modify: `SonosWidgetTests/RelayManagerTests.swift`

- [ ] **Step 1: Write failing Swift tests**

Add tests for `RelayClient.DeviceLogBody` JSON encoding and `RelayClient.deviceLogsURL(baseURL:)` path construction.

- [ ] **Step 2: Run the Swift test**

Run only the new XCTest method.
Expected: FAIL because the new body and URL helper do not exist yet.

- [ ] **Step 3: Implement Swift request types and sender**

Add `DeviceLogEntryBody`, `DeviceLogBody`, `deviceLogsURL`, and `postDeviceLogs`. Use `noProxySession` and a short timeout.

- [ ] **Step 4: Connect `SonosLog`**

After local file enqueue, send one remote log entry with category, level, timestamp, line, bundle id, and shared client id. Use throttling only through a serial delivery queue; never log send failures.

- [ ] **Step 5: Run Swift tests**

Run: Xcode `SonosWidgetTests/RelayManagerTests`
Expected: PASS.

### Task 3: Verification and Deploy

**Files:**
- Existing relay and app files only.

- [ ] **Step 1: Build relay**

Run: `npm run build`
Expected: PASS.

- [ ] **Step 2: Deploy relay to NAS**

Build and copy the relay `dist` output to the running NAS container, restart if needed, then verify `/api/health`.

- [ ] **Step 3: Deploy iOS app to phone**

Run the existing physical-device deploy script for scheme `SonosWidget`.
Expected: install and launch succeeds.

- [ ] **Step 4: Verify live stream**

Run `curl -N http://127.0.0.1:8787/api/device-logs/stream` on the NAS and trigger an app/widget log. Expected: streamed `device-log` events appear without manual phone export.
