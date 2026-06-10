# Local Apple Music No-Login Probe

Date: 2026-06-10
Branch: `codex/apple-music-local-smapi`

## Goal

Test whether Apple Music can be searched or played through locally discovered
Sonos bindings without requiring this app to sign in to Sonos Cloud, and without
using MusicKit.

## Probe

Run:

```sh
ruby tools/local_apple_music_probe.rb --speaker 192.168.50.238 --query "john mayer" --limit 3
```

The probe is read-only by default. It only starts playback when explicitly run
with `--play-first`.

## Observed

- `MusicServices.ListAvailableServices` exposes Apple Music locally:
  - local service id: `204`
  - endpoint: `https://sonos-music.apple.com/ws/SonosSoap`
  - auth policy: AppLink, inferred from the service descriptor
- Local Sonos content is enough to infer the household Apple Music binding:
  - account id / `sn`: `2`
  - cloud / SMAPI service id: `52231`
  - username template shape: `X_#Svc52231-[redacted]-Token`
- Direct Apple Music SMAPI `search` fails without a login token:
  - no credentials: `HTTP 500`, `SonosError=999`
  - device header only: `HTTP 500`, `SonosError=999`
- Non-MusicKit catalog lookup works through the public iTunes Search API and can
  produce Sonos track URIs, for example:
  - `x-sonos-http:song%3a184335660.mp4?sid=204&flags=8232&sn=2`

## Interpretation

The true Sonify-style path is probably Apple Music SMAPI search with an AppLink
`loginToken` and private key. The local speaker exposes enough binding metadata
to build Apple Music playback URIs, but not enough in the ordinary UPnP service
list/favorites response to call Apple Music SMAPI search directly.

The practical no-MusicKit fallback to validate next is:

1. Use the iTunes Search API for catalog search.
2. Build Apple Music Sonos URIs with local `sid=204` and locally inferred `sn`.
3. Use locally inferred `SA_RINCON52231_X_#Svc52231-...-Token` DIDL metadata.
4. Verify real playback with `--play-first`.

If playback succeeds, the app can offer a no-Sonos-Cloud-login, no-MusicKit
track-search path for Apple Music tracks. Albums/playlists would need separate
catalog-to-Sonos object mapping tests.
