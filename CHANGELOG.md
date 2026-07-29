# Changelog

All notable changes to Charm Player and its relay will be documented in this
file.

The format is based on [Keep a Changelog 1.1.0], and versioned components follow
[Semantic Versioning 2.0.0].

## [Unreleased]

### Changed

- Repository publishing now keeps Forgejo and GitHub on the same commit history:
  Forgejo remains the fast `edge`/SHA image channel, while GitHub publishes the
  complete multi-platform stable image only from matching `nas-relay-v*` tags.
- Charm Player repository, deployment, and package references now use the
  `charm-player` name, including the
  `ghcr.io/charmmmz/charm-player/nas-relay` image path.
- Removed the one-way Forgejo-to-GitHub README sync that could create
  host-specific commits and branch divergence.

### Fixed

- Now Playing no longer repeats bit-depth and sample-rate text when Sonos
  reports technical audio parameters without a descriptive quality badge.

## [0.1.0] - 2026-07-26

### Added

- Relay playback snapshots now preserve structured Sonos audio-quality details,
  including lossless and immersive flags, bit depth, and sample rate, while
  remaining compatible with older label-only relays.

### Changed

- TV playback now appears as a live Remote Media Session without artwork,
  progress, or unsupported playback commands, while retaining group device and
  volume controls.
- The nas-relay container now publishes `edge` and Git SHA snapshots from
  ordinary `main` builds. Only a `nas-relay-v*` Git tag matching the relay
  package version publishes the stable version and moves `latest`.
- GitHub validates pull-request and manual image builds without publishing them;
  Forgejo remains the fast `main` development-image channel.
- Forgejo no longer pushes its default single-platform build to GHCR, preventing
  it from replacing the multi-platform image produced by GitHub; it continues
  publishing the Forgejo and Aliyun registry copies.

### Fixed

- TV Remote Media Sessions retain the negotiated HDMI/eARC audio format through
  momentary silence and end only for a true no-input state.

[Unreleased]: https://github.com/charmmmz/charm-player/compare/nas-relay-v0.1.0...HEAD
[0.1.0]: https://github.com/charmmmz/charm-player/releases/tag/nas-relay-v0.1.0
[Keep a Changelog 1.1.0]: https://keepachangelog.com/en/1.1.0/
[Semantic Versioning 2.0.0]: https://semver.org/spec/v2.0.0.html
