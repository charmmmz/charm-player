# Apple Music Share to Sonos Design

## Goal

Let a user share an Apple Music item from the Apple Music app to Charm Player,
land on Home when possible, choose the target Sonos speaker or group, and start
playback immediately after that choice.

The feature should feel direct without hiding the target decision. Sharing a
song should not play to an unexpected room just because a previous speaker was
selected in the app.

## User Experience

Apple Music's share sheet shows Charm Player as a share target. When the user
chooses it, the share extension saves the Apple Music link as a pending playback
request and attempts to open the main app with:

```text
sonoswidget://share/apple-music
```

If iOS allows the transition, the main app opens to the Home tab. Home shows a
pending-share banner such as "Choose a speaker for Apple Music" and subtly
animates the speaker and group cards. The user taps the desired target. The app
selects that target, immediately starts the shared item on Sonos, then clears
the pending request and shows a success toast.

If iOS does not open the main app from the share extension, the extension still
saves the pending request and shows a small completion view. The user can try an
Open button, or manually open Charm Player later. On the next app launch or
foreground activation, Charm Player detects the pending request, switches to
Home, and shows the same target-selection guidance.

## Platform Constraint

The automatic transition from a Share Extension to its containing app is
best-effort. Apple documents `NSExtensionContext.open(_:completionHandler:)` as
extension-point dependent, and public guidance explicitly calls out Today and
iMessage extension support rather than ordinary Share Extensions. The feature
must not rely on automatic foregrounding as its only path.

For that reason, the share extension's durable responsibility is to capture and
persist the shared Apple Music URL. Opening the main app is a convenience layer
with a user-visible fallback.

## Share Extension

Add a new iOS Share Extension target, tentatively named
`AppleMusicShareExtension`, with the existing app group:

```text
group.com.charm.SonosWidget
```

Its activation rule should support a single web URL and text payload so Apple
Music links are offered in the share sheet without making the extension appear
for unrelated media-heavy shares.

The extension should:

- Read the first `URL` or text attachment from the extension context.
- Accept only Apple Music URLs, including `music.apple.com` and regional links.
- Store a pending request in App Group `UserDefaults`.
- Attempt to open `sonoswidget://share/apple-music`.
- Show a lightweight success or error view if the extension remains visible.

The extension should not perform Sonos auth, MusicKit catalog lookup, or Sonos
playback. Those belong in the main app where existing managers and credentials
already live.

## Pending Request Model

Store the pending share as a small Codable value in `SharedStorage`:

```swift
struct PendingAppleMusicShare: Codable, Equatable, Sendable {
    let id: UUID
    let urlString: String
    let receivedAt: Date
}
```

Only one pending request is needed for v1. A new share replaces the old pending
request. The main app clears it only after playback succeeds or the user
explicitly dismisses it. Failed playback keeps the request so the user can pick
another speaker or retry after fixing configuration.

## Main App Routing

`SonosWidgetApp` already handles `sonoswidget://` URLs for Sonos OAuth. Extend
URL handling so:

- OAuth callback URLs keep their current path.
- `sonoswidget://share/apple-music` posts or stores an app-level route event.
- The route event tells `ContentView` to select the Home tab and enter
  pending-share mode.

`ContentView` should also check for an existing pending Apple Music share on
launch and foreground activation. This preserves the fallback path when the share
extension could not foreground the app.

Because `TabView` currently uses implicit tabs, introduce an explicit
`Home/Browse/Local Service/Settings` selection binding so code can switch to
Home without rebuilding the tab structure.

## Home Target Selection

`PlayerView` already renders speaker group cards and selects a group through
`manager.selectSpeaker(group.coordinator)`. Pending-share mode should reuse this
interaction:

- Render a compact banner near the top of Home.
- Add a subtle pulse or glow to playable speaker/group cards.
- Change the card tap behavior only while a pending share exists:
  - select the tapped group,
  - start pending-share playback,
  - show progress and temporarily disable repeated starts,
  - clear the pending request on success.

The animation should be restrained and fit the current dark, glassy Home style.
It should not obscure drag-to-group behavior or volume controls. The existing
handoff button remains available, but pending-share playback has its own loading
state so users understand the shared item is being started.

## Apple Music Link Resolution

Prefer deterministic catalog ID playback when possible:

1. Parse Apple Music URLs for item type and catalog ID.
2. Build a `LocalServiceAppleMusicPlayable` for supported types:
   - song
   - album
   - playlist
   - artist if the URL is a supported Apple Music artist URL
3. Call the existing `SearchManager.playLocalAppleMusic(_:manager:)` path.

If the URL contains a song ID nested inside an album URL, use the song ID as the
playback target for v1. Playing the full album context from a share can be added
later if needed, but v1 should match the user's stated intent: "this song I want
to play."

If deterministic parsing fails, fall back to a MusicKit catalog lookup or search
only when the URL contains enough metadata to do so safely. Weak guesses should
fail with a clear message instead of playing the wrong song.

## Playback Behavior

After the user chooses a target:

1. Select the tapped speaker/group through `SonosManager.selectSpeaker`.
2. Ensure service probing and local Apple Music service mapping are ready.
3. Start the parsed Apple Music playable through `SearchManager`.
4. Refresh Sonos state so Home and the mini-player update.
5. Clear the pending request and show a toast such as "Playing on Living Room."

For v1, this flow is LAN-first because `playLocalAppleMusic` requires the local
Sonos service ID mapping. If the selected target is only reachable through Sonos
Cloud remote mode, show the existing local-service mapping/cloud-mode error and
keep the pending request. A later enhancement can add a Cloud playback path for
shared catalog IDs.

## Error Handling

Expected user-facing errors:

- The shared item is not an Apple Music link.
- The Apple Music link type is not supported.
- No Sonos speaker or group is configured.
- Apple Music is not linked to this Sonos household.
- The local Apple Music service mapping is unavailable.
- The selected target is in remote/cloud mode where local-service playback is
  unsupported.
- Sonos could not start playback.

Errors in the share extension should be short and local to link capture. Errors
in the main app should use Home toast/banner patterns and keep the pending item
available until the user cancels or playback succeeds.

## Components

| Component | Responsibility |
| --- | --- |
| `AppleMusicShareExtension` | Receive Apple Music URLs from the share sheet, persist pending request, best-effort open the app. |
| `SharedStorage` | Store and clear `PendingAppleMusicShare` in the app group. |
| `AppleMusicShareLinkParser` | Parse Apple Music URLs into supported catalog playback targets. |
| `ContentView` | Own explicit tab selection and route pending shares to Home. |
| `SonosWidgetApp` | Distinguish OAuth URLs from share route URLs. |
| `PlayerView` | Render pending-share guidance, animate target cards, and start playback after target selection. |
| `SearchManager` | Reuse local Apple Music playback orchestration. |

## Testing

Automated coverage should include:

- Apple Music URL parser tests for song, album with song parameter, playlist,
  artist, regional URL, and unsupported domains.
- `SharedStorage` pending request encode/decode/clear behavior.
- Main app route handling so `sonoswidget://share/apple-music` selects Home
  without breaking OAuth callback handling.
- Pending playback clears the request on success and preserves it on failure.

Manual checks should use a physical iPhone:

- Share a song from Apple Music and verify Charm Player appears in the share
  sheet.
- Confirm best-effort automatic opening when iOS permits it.
- Confirm the fallback completion view when the app does not open.
- Open the app manually after fallback and verify Home guidance appears.
- Choose different Sonos groups and verify playback starts on the tapped target.
- Verify the pending banner can be dismissed.

## Non-Goals

- Automatically playing to the previously selected speaker without user choice.
- Supporting non-Apple-Music links in v1.
- Capturing or rebroadcasting audio from the iPhone.
- Full Apple Music queue transfer from a shared link.
- Relying on private or unsupported APIs as the only launch path.
