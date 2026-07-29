# nas-relay GHCR Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Actions automation that builds and publishes the `nas-relay` Docker image to GHCR for NAS deployment.

**Architecture:** A single workflow owns Docker Buildx setup, metadata/tag generation, GHCR login, and multi-platform image build/push. The NAS compose file consumes the published image instead of building from local source.

**Tech Stack:** GitHub Actions, Docker Buildx, GitHub Container Registry, Docker Compose, Node.js/TypeScript.

---

### Task 1: Add GitHub Actions image workflow

**Files:**
- Create: `.github/workflows/nas-relay-image.yml`

- [ ] **Step 1: Verify the workflow does not exist yet**

Run: `test -f .github/workflows/nas-relay-image.yml`
Expected: FAIL with exit code 1.

- [ ] **Step 2: Create the workflow**

Create `.github/workflows/nas-relay-image.yml` with triggers for `push` to `main`, `pull_request`, and `workflow_dispatch`. Use Docker setup actions, `docker/metadata-action@v5`, and `docker/build-push-action@v6`. Push only when the event is not `pull_request`.

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 - <<'PY'
import pathlib, yaml
yaml.safe_load(pathlib.Path(".github/workflows/nas-relay-image.yml").read_text())
PY`
Expected: PASS with exit code 0.

### Task 2: Point NAS compose at the published image

**Files:**
- Modify: `nas-relay/docker-compose.yml`
- Modify: `nas-relay/README.md`

- [ ] **Step 1: Verify compose is not using GHCR yet**

Run: `grep -q 'ghcr.io/charmmmz/charm-player/nas-relay' nas-relay/docker-compose.yml`
Expected: FAIL with exit code 1.

- [ ] **Step 2: Update compose**

Replace the local `build: .` service setup with `image: ghcr.io/charmmmz/charm-player/nas-relay:latest`. Update the comment to use `docker compose pull && docker compose up -d`.

- [ ] **Step 3: Update README**

Document that Portainer pulls `ghcr.io/charmmmz/charm-player/nas-relay:latest` and that private packages require `docker login ghcr.io` with a GitHub token that can read packages.

- [ ] **Step 4: Validate compose config**

Run: `docker compose -f nas-relay/docker-compose.yml config`
Expected: PASS with exit code 0.

### Task 3: Verify relay build behavior

**Files:**
- Existing: `nas-relay/package.json`
- Modify: `nas-relay/Dockerfile`

- [ ] **Step 1: Run TypeScript build**

Run: `npm run build`
Working directory: `nas-relay`
Expected: PASS with exit code 0.

- [ ] **Step 2: Keep the Docker base image compatible with dependencies**

Use `docker.m.daocloud.io/library/node:24-alpine` for both build and runtime stages because `@parse/node-apn@8.1.0` supports Node 20, 22, and 24.

- [ ] **Step 3: Run local Docker image build**

Run: `docker build -t nas-relay-ghcr-test ./nas-relay`
Expected: PASS with exit code 0 when Docker is available.
