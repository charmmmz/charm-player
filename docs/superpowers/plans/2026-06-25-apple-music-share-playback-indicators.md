# Apple Music Share Playback Indicators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the Apple Music share extension sheet so playback success is left-aligned and speaker cards use waveform state indicators.

**Architecture:** Keep the UIKit share extension structure. Extend the shared indicator model with semantic waveform states, then implement a small presentation-only waveform view inside `SpeakerGroupCard`.

**Tech Stack:** UIKit, XCTest, Xcode build/test.

---

## File Structure

- Modify `Shared/SharePlaybackVisualIndicator.swift` and `AppleMusicShareExtension/SharePlaybackVisualIndicator.swift`: replace the old `.play` symbol semantics with waveform state metadata.
- Modify `SonosWidgetTests/ShareSpeakerPlaybackStatusTests.swift`: add a red/green test for waveform semantics.
- Modify `AppleMusicShareExtension/ShareViewController.swift`: fix status row alignment and replace the right-side play/check icon with a `PlaybackWaveformView`.

### Task 1: Indicator Semantics

**Files:**
- Modify: `Shared/SharePlaybackVisualIndicator.swift`
- Modify: `AppleMusicShareExtension/SharePlaybackVisualIndicator.swift`
- Test: `SonosWidgetTests/ShareSpeakerPlaybackStatusTests.swift`

- [x] **Step 1: Write the failing test**

Change `testPlaybackVisualIndicatorReplacesLoadingWithSuccessSymbol` so it expects `.playingWaveform`, `.restingWaveform`, `.loading`, and `.success` semantics. The new test should assert that loading still shows a spinner, playing animates, resting does not animate, and success keeps the checkmark symbol for the top status row.

- [x] **Step 2: Run the focused test to verify it fails**

Run:

```bash
xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/ShareSpeakerPlaybackStatusTests/testPlaybackVisualIndicatorReplacesLoadingWithSuccessSymbol
```

Expected: compile failure because `.playingWaveform` and `.restingWaveform` do not exist yet.

- [x] **Step 3: Implement indicator semantics**

Add `.playingWaveform` and `.restingWaveform` to both copies of `SharePlaybackVisualIndicator`. Add `showsWaveform` and `animatesWaveform` computed properties. Keep `.success.systemImageName == "checkmark.circle.fill"` for the top status row.

- [x] **Step 4: Run the focused test to verify it passes**

Run the same `xcodebuild test` command. Expected: the focused test passes.

### Task 2: Share Sheet UI

**Files:**
- Modify: `AppleMusicShareExtension/ShareViewController.swift`

- [x] **Step 1: Fix success status alignment**

Make the `statusRow` stack fill horizontally and add a trailing spacer so the icon and label stay grouped on the left.

- [x] **Step 2: Replace card icon button with waveform view**

Remove the right-side `playView` image view from `SpeakerGroupCard`, add `PlaybackWaveformView`, and map card status to these visual states:

- Loading: spinner visible, waveform hidden.
- Successful or currently playing: animated waveform.
- Paused, idle, unknown, or not successful: resting waveform.

- [x] **Step 3: Improve card spacing**

Narrow the right-side indicator container, reduce forced scroll height, and keep the text stack compression-resistant enough that long subtitles get more space than before.

### Task 3: Verification

**Files:**
- Verify: `AppleMusicShareExtension/ShareViewController.swift`
- Verify: `Shared/SharePlaybackVisualIndicator.swift`
- Verify: `AppleMusicShareExtension/SharePlaybackVisualIndicator.swift`
- Verify: `SonosWidgetTests/ShareSpeakerPlaybackStatusTests.swift`

- [x] **Step 1: Run focused tests**

Run:

```bash
xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/ShareSpeakerPlaybackStatusTests
```

Expected: the test class passes.

- [x] **Step 2: Build the app target**

Run:

```bash
xcodebuild build -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: build succeeds.
