# Charm Player repository instructions

## Git publishing

- Keep Forgejo and GitHub on the same commit history.
- The `origin` push target must publish to both GitHub and Forgejo, with GitHub
  first so a Forgejo connectivity failure does not prevent the GitHub push.
- Keep a separate `github` remote for explicit fetches and comparisons.
- After every push, verify the target branch SHA independently on GitHub and
  Forgejo before reporting synchronization.
- Do not use one-way README synchronization or create host-specific commits.

## Container images

- Treat `nas-relay/package.json` as the nas-relay version source of truth.
- GitHub publishes the complete `linux/amd64` and `linux/arm64` stable GHCR
  image only from an explicit `nas-relay-v*` tag matching the package version.
- Pull requests and manual GitHub runs may validate the image build but must not
  publish it.
- Forgejo publishes the fast self-hosted `edge` and Git SHA channels from
  ordinary `main` builds. Release tags may publish the matching stable version
  and `latest` to the Forgejo and Aliyun registries.
- Verify release tags resolve to the same commit on GitHub and Forgejo.
- Do not create or push a release tag unless the user explicitly requests a
  release.
