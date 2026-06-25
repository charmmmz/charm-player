# Apple Music Share Playback Indicators Design

## Goal

Refine the Apple Music share extension playback sheet so success feedback is left-aligned and speaker cards communicate playback state with a compact waveform instead of a play button.

## Scope

- Left-align the success status row so the checkmark and "Playing on <speaker>" text stay together.
- Replace the speaker-card right-side play/check icon with a waveform status indicator.
- Keep the whole speaker card as the tap target for starting playback.
- Animate the waveform when a speaker is actively playing.
- Show a static low-amplitude waveform for paused, idle, or unknown states.
- Preserve the existing spinner while a playback request is in progress.
- Give the successful target a selected-card treatment with a green waveform and existing accent border.
- Improve card spacing so long now-playing subtitles keep more horizontal room.
- Slightly reduce the empty vertical feel by letting the speaker list occupy less forced height.

## Architecture

The share extension remains UIKit-based. `SharePlaybackVisualIndicator` continues to describe high-level status semantics for tests and the top status row. `SpeakerGroupCard` owns the visual waveform view because the view is presentation-only and does not change playback behavior.

## Testing

- Update the existing indicator unit test so playback state uses semantic waveform cases instead of a play icon.
- Build the app target to catch UIKit compile errors in the share extension sources.
- Run the existing share playback status test file.

## Out Of Scope

- Adding pause/resume controls.
- Changing Sonos playback routing or Apple Music resolution.
- Reworking the share extension into SwiftUI.
