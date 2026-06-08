# Apple Music Share to Sonos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Apple Music share-sheet intake that routes the main app to Home, guides the user to choose a Sonos target, and plays the shared Apple Music item after selection.

**Architecture:** The share extension captures Apple Music URLs and stores one pending request in the App Group. The main app owns route handling, pending state, MusicKit catalog resolution, and Sonos playback through the existing `SearchManager.playLocalAppleMusic` path. Pure URL parsing and pending storage are covered with XCTest; extension foregrounding remains best-effort with a durable manual fallback.

**Tech Stack:** Swift, SwiftUI, UIKit Share Extension, MusicKit, App Group `UserDefaults`, XCTest, Xcode project synchronized groups.

---

## File Structure

- Create `SonosWidget/AppleMusicShareLinkParser.swift`: pure parser from shared Apple Music URL/text to catalog kind and ID.
- Create `SonosWidget/AppleMusicSharePlayableResolver.swift`: MusicKit resolver that turns parsed catalog IDs into `LocalServiceAppleMusicPlayable`.
- Modify `Shared/SharedStorage.swift`: add `PendingAppleMusicShare` storage using the existing app group.
- Create `SonosWidget/AppRoute.swift`: route helper and notification name for `sonoswidget://share/apple-music`.
- Modify `SonosWidget/SonosWidgetApp.swift`: distinguish OAuth callback URLs from share-route URLs.
- Modify `SonosWidget/ContentView.swift`: add explicit tab selection and pending-share routing into Home.
- Modify `SonosWidget/PlayerView.swift`: render pending-share guidance, animate group cards, and start playback after target selection.
- Create `AppleMusicShareExtension/Info.plist`, `AppleMusicShareExtension/AppleMusicShareExtension.entitlements`, and Swift sources for URL capture and best-effort app opening.
- Modify `SonosWidget.xcodeproj/project.pbxproj`: add the Share Extension target, product, app dependency, and embedded appex.
- Create tests in `SonosWidgetTests/AppleMusicShareLinkParserTests.swift` and `SonosWidgetTests/PendingAppleMusicShareStorageTests.swift`.

---

### Task 1: Apple Music Link Parser

**Files:**
- Create: `SonosWidget/AppleMusicShareLinkParser.swift`
- Test: `SonosWidgetTests/AppleMusicShareLinkParserTests.swift`

- [ ] **Step 1: Write failing parser tests**

Add tests for song URLs, album URLs with `i=` song IDs, playlist URLs, artist URLs, unsupported Apple domains, and non-URL shared text.

- [ ] **Step 2: Run parser tests and verify RED**

Run: `xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/AppleMusicShareLinkParserTests`

Expected: compile failure or test failure because `AppleMusicShareLinkParser` does not exist.

- [ ] **Step 3: Implement minimal parser**

Define:

```swift
struct AppleMusicShareLink: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case song
        case album
        case playlist
        case artist
    }

    let kind: Kind
    let catalogID: String
    let originalURLString: String
}

enum AppleMusicShareLinkParser {
    static func parse(_ value: String) -> AppleMusicShareLink?
}
```

The parser accepts `music.apple.com` HTTPS links, extracts the first Apple Music URL from text, prefers numeric `i=` as a song target, and otherwise reads supported path kinds.

- [ ] **Step 4: Run parser tests and verify GREEN**

Run the same parser-only test command. Expected: tests pass.

---

### Task 2: Pending Share Storage and App Route

**Files:**
- Modify: `Shared/SharedStorage.swift`
- Create: `SonosWidget/AppRoute.swift`
- Test: `SonosWidgetTests/PendingAppleMusicShareStorageTests.swift`

- [ ] **Step 1: Write failing storage and route tests**

Add tests that save, read, replace, and clear `PendingAppleMusicShare`, and verify `AppRoute.route(for:)` recognizes `sonoswidget://share/apple-music` while not treating OAuth callbacks as share routes.

- [ ] **Step 2: Run tests and verify RED**

Run: `xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/PendingAppleMusicShareStorageTests`

Expected: compile failure or test failure because storage and route types do not exist.

- [ ] **Step 3: Implement storage and route helpers**

Define:

```swift
struct PendingAppleMusicShare: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let urlString: String
    let receivedAt: Date
}

enum AppRoute: Equatable {
    case appleMusicShare

    static func route(for url: URL) -> AppRoute?
}
```

Add `SharedStorage.pendingAppleMusicShare` and `SharedStorage.clearPendingAppleMusicShare()`.

- [ ] **Step 4: Run storage and route tests and verify GREEN**

Run the same storage-only test command. Expected: tests pass.

---

### Task 3: Main App Routing and Home Pending UI

**Files:**
- Modify: `SonosWidget/SonosWidgetApp.swift`
- Modify: `SonosWidget/ContentView.swift`
- Modify: `SonosWidget/PlayerView.swift`
- Create: `SonosWidget/AppleMusicSharePlayableResolver.swift`

- [ ] **Step 1: Add MusicKit resolver**

Create a resolver that authorizes MusicKit, fetches the parsed song/album/playlist/artist catalog resource by `MusicItemID`, and converts it with existing `LocalServiceAppleMusicPlayable.make(...)` helpers.

- [ ] **Step 2: Route share URLs separately from OAuth**

Update `.onOpenURL` so share routes post a main-thread notification and OAuth URLs continue through `SonosAuth.shared.handleCallback(url:)`.

- [ ] **Step 3: Add explicit tab selection**

Convert `ContentView` to `TabView(selection:)` with a local `AppTab` enum and `Tab(..., value:)` entries. On share-route notification, launch, and foreground, load `SharedStorage.pendingAppleMusicShare`, select Home, and pass the pending binding into `PlayerView`.

- [ ] **Step 4: Add Home pending-share guidance**

Update `PlayerView` to accept `@Binding var pendingAppleMusicShare: PendingAppleMusicShare?`, show a compact banner, highlight speaker cards, and intercept group-card taps only while a pending share exists.

- [ ] **Step 5: Start playback after target selection**

After tapping a highlighted group, call `manager.selectSpeaker(group.coordinator)`, resolve the pending Apple Music link, call `searchManager.playLocalAppleMusic`, clear the pending request on success, and keep it on failure.

- [ ] **Step 6: Build app target**

Run: `xcodebuild build -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17'`

Expected: build succeeds.

---

### Task 4: Share Extension Target

**Files:**
- Create: `AppleMusicShareExtension/Info.plist`
- Create: `AppleMusicShareExtension/AppleMusicShareExtension.entitlements`
- Create: `AppleMusicShareExtension/ShareViewController.swift`
- Create: `AppleMusicShareExtension/AppleMusicShareExtensionStore.swift`
- Modify: `SonosWidget.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add extension files**

Create a UIKit share extension view controller that loads one URL or text payload, extracts the first Apple Music URL, writes the pending request payload into App Group `UserDefaults`, and attempts to open `sonoswidget://share/apple-music`.

- [ ] **Step 2: Add extension Info.plist and entitlements**

Use `com.apple.share-services`, `NSExtensionPrincipalClass`, activation support for one web URL, text support, and the existing app group entitlement.

- [ ] **Step 3: Add Xcode target wiring**

Add `AppleMusicShareExtension.appex`, a new synchronized root group, native target, sources/resources/framework phases, build settings, main-app target dependency, and embed entry in `Embed Foundation Extensions`.

- [ ] **Step 4: Build app target with embedded extension**

Run: `xcodebuild build -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17'`

Expected: build succeeds and embeds `AppleMusicShareExtension.appex`.

---

### Task 5: Verification and Cleanup

**Files:**
- Review all changed files.

- [ ] **Step 1: Run targeted tests**

Run parser and storage tests through XcodeBuildMCP or `xcodebuild test`.

- [ ] **Step 2: Run full app build**

Run the SonosWidget simulator build through XcodeBuildMCP or `xcodebuild build`.

- [ ] **Step 3: Inspect git diff**

Confirm changes are scoped to the parser, storage, route, Home UI, share extension, Xcode project, and tests. Confirm existing unrelated dirty files are not reverted.

- [ ] **Step 4: Report manual checks**

List physical-device checks still needed: Apple Music share sheet visibility, best-effort app open, fallback view, target selection, and Sonos playback.
