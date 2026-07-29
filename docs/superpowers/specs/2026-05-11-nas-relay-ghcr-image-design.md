# nas-relay GHCR Image Automation Design

## Goal

Build the `nas-relay` Docker image automatically after relevant changes reach `main`, publish it to GitHub Container Registry, and let the NAS deploy by pulling the published image.

## Architecture

The repository gets a single GitHub Actions workflow at `.github/workflows/nas-relay-image.yml`. It uses Docker Buildx to build `nas-relay/Dockerfile` for `linux/amd64` and `linux/arm64`, then pushes the image to `ghcr.io/charmmmz/charm-player/nas-relay` on non-PR events.

The workflow opts JavaScript actions into the Node 24 runtime with `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` so it stays ahead of GitHub's 2026 Node 20 action-runtime deprecation.

## Triggers

- `push` to `main` when `nas-relay/**` or the workflow changes.
- `pull_request` when `nas-relay/**` or the workflow changes, build-only with no registry push.
- `workflow_dispatch` for manual rebuilds.

## Tags

- `latest` on the default branch.
- Branch/ref tags for branch builds.
- `sha-<short-sha>` for immutable rollbacks.

## NAS Deployment

`nas-relay/docker-compose.yml` references `ghcr.io/charmmmz/charm-player/nas-relay:latest` directly. If the GHCR package is private, the NAS must run `docker login ghcr.io` with a GitHub token that can read packages before pulling.

## Verification

- Validate the workflow YAML parses as YAML.
- Run `docker compose -f nas-relay/docker-compose.yml config`.
- Run `npm run build` in `nas-relay`.
- Run a local Docker build for the `nas-relay` image when Docker is available.
- Keep the Docker runtime on Node 24 Alpine so the APNs dependency engine range is respected.
