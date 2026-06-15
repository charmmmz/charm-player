# Album Detail Shared UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Share album detail presentation between Sonos Browse albums and Local Service Apple Music albums, while keeping Sonos Favorite and future Apple Music Favorite as distinct actions.

**Architecture:** Add a small presentation layer for album action semantics, muted theme colors, and the Apple Music style action bar. Keep `AlbumDetailView` and `LocalMusicAlbumDetailView` as data adapters that pass callbacks into the shared component.

**Tech Stack:** Swift, SwiftUI, UIKit color conversion, XCTest, existing SonosWidget app target.

---

## File Structure

- Create: `SonosWidget/AlbumDetailPresentation.swift`
  - Pure enums and policies for favorite kind, primary actions, overflow actions, and muted theme color components.
- Create: `SonosWidget/AlbumDetailSharedViews.swift`
  - SwiftUI `AlbumPrimaryActionBar` and small helper button views.
- Create: `SonosWidgetTests/AlbumDetailPresentationTests.swift`
  - Unit tests for action policy and color muting.
- Modify: `SonosWidget/AlbumDetailView.swift`
  - Use shared muted theme color, shared primary action bar, and remove album Favorite from top-right menu.
- Modify: `SonosWidget/LocalMusicDetailViews.swift`
  - Use shared muted theme color and shared primary action bar for `LocalMusicAlbumDetailView` only.

Do not touch playlist detail, artist detail, or track row favorite menus in this plan.

---

### Task 1: Add Album Action Policy Tests

**Files:**
- Create: `SonosWidgetTests/AlbumDetailPresentationTests.swift`
- Create later: `SonosWidget/AlbumDetailPresentation.swift`

- [ ] **Step 1: Write the failing tests**

Create `SonosWidgetTests/AlbumDetailPresentationTests.swift`:

```swift
import XCTest
import UIKit
@testable import SonosWidget

final class AlbumDetailPresentationTests: XCTestCase {
    func testSonosAlbumPrimaryActionsUseSonosFavorite() {
        XCTAssertEqual(
            AlbumPrimaryActionPolicy.actions(favoriteKind: .sonos),
            [.shuffle, .play, .favorite(.sonos)]
        )
    }

    func testLocalMusicAlbumPrimaryActionsUseAppleMusicFavorite() {
        XCTAssertEqual(
            AlbumPrimaryActionPolicy.actions(favoriteKind: .appleMusic),
            [.shuffle, .play, .favorite(.appleMusic)]
        )
    }

    func testAlbumOverflowActionsExcludeFavorite() {
        XCTAssertEqual(
            AlbumOverflowActionPolicy.albumActions,
            [.playNext, .addToQueue]
        )
    }

    func testVividThemeColorIsMutedAndDarkened() {
        let original = AlbumThemeColorComponents(hue: 0.0, saturation: 0.95, brightness: 0.92, alpha: 1.0)
        let muted = AlbumThemeColorPolicy.mutedComponents(from: original)

        XCTAssertLessThan(muted.saturation, original.saturation)
        XCTAssertLessThan(muted.brightness, original.brightness)
        XCTAssertLessThanOrEqual(muted.saturation, 0.48)
        XCTAssertLessThanOrEqual(muted.brightness, 0.48)
    }

    func testMutedThemeColorKeepsLowSaturationUsable() {
        let original = AlbumThemeColorComponents(hue: 0.58, saturation: 0.18, brightness: 0.32, alpha: 1.0)
        let muted = AlbumThemeColorPolicy.mutedComponents(from: original)

        XCTAssertEqual(muted.hue, original.hue, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(muted.saturation, 0.16)
        XCTAssertGreaterThanOrEqual(muted.brightness, 0.20)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/AlbumDetailPresentationTests
```

Expected: fail with missing `AlbumPrimaryActionPolicy`, `AlbumOverflowActionPolicy`, and `AlbumThemeColorPolicy`.

---

### Task 2: Implement Album Presentation Policies

**Files:**
- Create: `SonosWidget/AlbumDetailPresentation.swift`
- Test: `SonosWidgetTests/AlbumDetailPresentationTests.swift`

- [ ] **Step 1: Add the minimal implementation**

Create `SonosWidget/AlbumDetailPresentation.swift`:

```swift
import SwiftUI
import UIKit

enum AlbumFavoriteKind: Equatable, Hashable, Sendable {
    case sonos
    case appleMusic
}

enum AlbumPrimaryAction: Equatable, Hashable, Sendable {
    case shuffle
    case play
    case favorite(AlbumFavoriteKind)

    var accessibilityTitle: String {
        switch self {
        case .shuffle:
            return "Shuffle"
        case .play:
            return "Play"
        case .favorite(.sonos):
            return "Sonos Favorite"
        case .favorite(.appleMusic):
            return "Apple Music Favorite"
        }
    }
}

enum AlbumPrimaryActionPolicy {
    static func actions(favoriteKind: AlbumFavoriteKind) -> [AlbumPrimaryAction] {
        [.shuffle, .play, .favorite(favoriteKind)]
    }
}

enum AlbumOverflowAction: Equatable, Hashable, Sendable {
    case playNext
    case addToQueue
}

enum AlbumOverflowActionPolicy {
    static let albumActions: [AlbumOverflowAction] = [.playNext, .addToQueue]
}

struct AlbumThemeColorComponents: Equatable, Sendable {
    let hue: CGFloat
    let saturation: CGFloat
    let brightness: CGFloat
    let alpha: CGFloat
}

enum AlbumThemeColorPolicy {
    static func mutedComponents(from components: AlbumThemeColorComponents) -> AlbumThemeColorComponents {
        AlbumThemeColorComponents(
            hue: components.hue,
            saturation: min(max(components.saturation * 0.62, 0.16), 0.48),
            brightness: min(max(components.brightness * 0.58, 0.20), 0.48),
            alpha: components.alpha
        )
    }

    static func mutedColor(from uiColor: UIColor) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        guard uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return Color(uiColor).opacity(0.55)
        }

        let muted = mutedComponents(
            from: AlbumThemeColorComponents(
                hue: hue,
                saturation: saturation,
                brightness: brightness,
                alpha: alpha
            )
        )

        return Color(
            uiColor: UIColor(
                hue: muted.hue,
                saturation: muted.saturation,
                brightness: muted.brightness,
                alpha: muted.alpha
            )
        )
    }
}
```

- [ ] **Step 2: Run the focused tests**

Run the same command from Task 1.

Expected: `AlbumDetailPresentationTests` passes.

- [ ] **Step 3: Commit the pure policy layer**

```bash
git add SonosWidget/AlbumDetailPresentation.swift SonosWidgetTests/AlbumDetailPresentationTests.swift
git commit -m "feat: add shared album detail presentation policy"
```

---

### Task 3: Add Shared Album Primary Action Bar

**Files:**
- Create: `SonosWidget/AlbumDetailSharedViews.swift`
- Modify later: `SonosWidget/AlbumDetailView.swift`
- Modify later: `SonosWidget/LocalMusicDetailViews.swift`

- [ ] **Step 1: Add the shared SwiftUI component**

Create `SonosWidget/AlbumDetailSharedViews.swift`:

```swift
import SwiftUI

struct AlbumPrimaryActionBar: View {
    let favoriteKind: AlbumFavoriteKind
    let tint: Color?
    let isPlayActive: Bool
    let isShuffleActive: Bool
    let isFavoriteActive: Bool
    let isFavoriteBusy: Bool
    let isFavoriteDisabled: Bool
    let isDisabled: Bool
    let play: () -> Void
    let shuffle: () -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 30) {
            AlbumCircleActionButton(
                systemImage: "shuffle",
                accessibilityTitle: "Shuffle",
                tint: tint,
                isActive: isShuffleActive,
                isDisabled: isDisabled,
                action: shuffle
            )

            Button(action: play) {
                HStack(spacing: 8) {
                    if isPlayActive {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.black)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.headline.weight(.bold))
                    }

                    Text("Play")
                        .font(.headline.weight(.bold))
                }
                .frame(width: 184, height: 56)
                .foregroundStyle(.black.opacity(0.86))
                .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.45 : 1)
            .accessibilityLabel("Play")

            AlbumCircleActionButton(
                systemImage: isFavoriteActive ? "heart.fill" : "heart",
                accessibilityTitle: favoriteKind.accessibilityTitle,
                tint: tint,
                isActive: isFavoriteBusy,
                isDisabled: isDisabled || isFavoriteDisabled,
                action: toggleFavorite
            )
        }
        .padding(.horizontal)
    }
}

private struct AlbumCircleActionButton: View {
    let systemImage: String
    let accessibilityTitle: String
    let tint: Color?
    let isActive: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill((tint ?? .white).opacity(0.18))
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }

                if isActive {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(width: 64, height: 64)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityLabel(accessibilityTitle)
    }
}
```

- [ ] **Step 2: Build to catch SwiftUI compile errors**

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Expected: build succeeds, or only fails on unrelated dirty Local Service work already present in the tree. If it fails on `AlbumDetailSharedViews.swift`, fix those compile errors before continuing.

- [ ] **Step 3: Commit the shared view**

```bash
git add SonosWidget/AlbumDetailSharedViews.swift
git commit -m "feat: add shared album detail action bar"
```

---

### Task 4: Update Sonos Browse Album Detail

**Files:**
- Modify: `SonosWidget/AlbumDetailView.swift`
- Test: `SonosWidgetTests/AlbumDetailPresentationTests.swift`

- [ ] **Step 1: Use muted theme color when loading artwork**

In `loadCoverImage()`, replace:

```swift
if let color = img?.dominantColor() {
    themeColor = color
}
```

with:

```swift
if let uiColor = img?.dominantUIColor() {
    themeColor = AlbumThemeColorPolicy.mutedColor(from: uiColor)
} else if let color = img?.dominantColor() {
    themeColor = color.opacity(0.55)
}
```

If `dominantUIColor()` does not exist, add this helper near `dominantColor()` in `Shared/DominantColor.swift`:

```swift
func dominantUIColor() -> UIColor? {
    guard let cg = self.cgImage else { return nil }
    let w = 1
    let h = 1
    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * w
    var data = [UInt8](repeating: 0, count: w * h * bytesPerPixel)
    guard let ctx = CGContext(
        data: &data,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return UIColor(
        red: CGFloat(data[0]) / 255.0,
        green: CGFloat(data[1]) / 255.0,
        blue: CGFloat(data[2]) / 255.0,
        alpha: CGFloat(data[3]) / 255.0
    )
}
```

- [ ] **Step 2: Replace the old two-button action bar**

Replace `private var actionBar` and `private func actionButton(...)` in `AlbumDetailView.swift` with:

```swift
private var actionBar: some View {
    AlbumPrimaryActionBar(
        favoriteKind: .sonos,
        tint: themeColor,
        isPlayActive: playingItemId == "play-all",
        isShuffleActive: playingItemId == "shuffle",
        isFavoriteActive: isFavorited,
        isFavoriteBusy: false,
        isFavoriteDisabled: false,
        isDisabled: playingItemId != nil,
        play: playAlbum,
        shuffle: playAlbumShuffled,
        toggleFavorite: toggleFavorite
    )
}
```

- [ ] **Step 3: Remove album Favorite from top-right menu**

In `albumMenu`, remove the first `Button { toggleFavorite() }` block and the following `Divider()`. Keep only Play Next and Add to Queue.

The resulting menu should be:

```swift
private var albumMenu: some View {
    Menu {
        Button {
            Task {
                await searchManager.playNext(item: albumItem, manager: manager)
                showToast("Playing next")
            }
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            Task {
                await searchManager.addToQueue(item: albumItem, manager: manager)
                showToast("Added to queue")
            }
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }
    } label: {
        Image(systemName: "ellipsis.circle")
            .font(.body)
            .symbolRenderingMode(.hierarchical)
    }
}
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/AlbumDetailPresentationTests
```

Expected: tests pass.

- [ ] **Step 5: Commit the Browse album page update**

```bash
git add SonosWidget/AlbumDetailView.swift Shared/DominantColor.swift
git commit -m "feat: refresh Sonos album detail actions"
```

Only include `Shared/DominantColor.swift` if `dominantUIColor()` was added there.

---

### Task 5: Update Local Music Album Detail

**Files:**
- Modify: `SonosWidget/LocalMusicDetailViews.swift`
- Modify if needed: `SonosWidget/LocalLibraryModels.swift`
- Test: `SonosWidgetTests/LocalServiceInteractionTests.swift`

- [ ] **Step 1: Update local album action policy tests**

In `SonosWidgetTests/LocalServiceInteractionTests.swift`, change:

```swift
XCTAssertEqual(
    LocalMusicDetailActions.album(hasAppleMusicURL: true),
    [.play, .shuffle])
```

to:

```swift
XCTAssertEqual(
    LocalMusicDetailActions.album(hasAppleMusicURL: true),
    [.play, .shuffle, .favorite])
```

Make the same change for `hasAppleMusicURL: false`.

- [ ] **Step 2: Add a local favorite action enum case**

In `SonosWidget/LocalLibraryModels.swift`, add:

```swift
case favorite
```

to `LocalMusicDetailAction`, and update:

```swift
case .favorite: return "Favorite"
case .favorite: return "heart"
```

in `title` and `systemImage`. Keep `isCompact` unchanged unless the old `LocalMusicDetailActionButton` is still used elsewhere:

```swift
var isCompact: Bool {
    self == .openAppleMusic || self == .favorite
}
```

Then change:

```swift
static func album(hasAppleMusicURL _: Bool) -> [LocalMusicDetailAction] {
    [.play, .shuffle]
}
```

to:

```swift
static func album(hasAppleMusicURL _: Bool) -> [LocalMusicDetailAction] {
    [.play, .shuffle, .favorite]
}
```

- [ ] **Step 3: Add Local Music album favorite state**

Inside `LocalMusicAlbumDetailView`, add state:

```swift
@State private var isAppleMusicFavorited = false
@State private var isAppleMusicFavoriteBusy = false
```

This is intentionally separate from Sonos Favorites. Do not call `SearchManager.addToFavorites` from Local Music album favorite.

- [ ] **Step 4: Replace Local Music album action bar**

Replace only `LocalMusicAlbumDetailView`'s `actionBar` with:

```swift
private var actionBar: some View {
    AlbumPrimaryActionBar(
        favoriteKind: .appleMusic,
        tint: actionTint,
        isPlayActive: isActionActive(.play),
        isShuffleActive: isActionActive(.shuffle),
        isFavoriteActive: isAppleMusicFavorited,
        isFavoriteBusy: isAppleMusicFavoriteBusy,
        isFavoriteDisabled: false,
        isDisabled: actionInFlight != nil || store.isStartingPlayback,
        play: { performAction(.play) },
        shuffle: { performAction(.shuffle) },
        toggleFavorite: toggleAppleMusicFavorite
    )
}
```

- [ ] **Step 5: Add a separate placeholder Apple Music favorite handler**

Add this method inside `LocalMusicAlbumDetailView`:

```swift
private func toggleAppleMusicFavorite() {
    guard !isAppleMusicFavoriteBusy else { return }
    isAppleMusicFavoriteBusy = true

    Task { @MainActor in
        defer { isAppleMusicFavoriteBusy = false }
        SonosLog.debug(
            .localService,
            "Apple Music album favorite tapped title='\(displayAlbum.title)' id='\(displayAlbum.id.rawValue)'"
        )
        isAppleMusicFavorited.toggle()
    }
}
```

This is a UI-level placeholder so the action is wired independently. Replace this method later with the MusicKit favorite implementation.

- [ ] **Step 6: Use muted theme color for Local Music album artwork**

In `LocalMusicAlbumDetailView.loadCoverImage(from:)`, replace:

```swift
themeColor = image?.dominantColor()
```

with:

```swift
if let uiColor = image?.dominantUIColor() {
    themeColor = AlbumThemeColorPolicy.mutedColor(from: uiColor)
} else {
    themeColor = image?.dominantColor()?.opacity(0.55)
}
```

- [ ] **Step 7: Run focused Local Service tests**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests
```

Expected: tests pass after updating expected actions.

- [ ] **Step 8: Commit the Local Music album update**

```bash
git add SonosWidget/LocalLibraryModels.swift SonosWidget/LocalMusicDetailViews.swift SonosWidgetTests/LocalServiceInteractionTests.swift
git commit -m "feat: align local album detail actions"
```

---

### Task 6: Build and Manual Verification

**Files:**
- No new files.

- [ ] **Step 1: Run combined focused tests**

Run:

```bash
xcodebuild test \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SonosWidgetTests/AlbumDetailPresentationTests \
  -only-testing:SonosWidgetTests/LocalServiceInteractionTests
```

Expected: both test classes pass.

- [ ] **Step 2: Run an app build**

Run:

```bash
xcodebuild build \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'generic/platform=iOS'
```

Expected: build succeeds. If the build fails on already-dirty Local Service files unrelated to album detail, record the exact errors before fixing them.

- [ ] **Step 3: Manual UI check on device or simulator**

Open:

- A Sonos Browse album detail page.
- A Local Service album detail page.

Verify:

- Action row visually matches Apple Music direction: Shuffle circle, Play capsule, Favorite circle.
- Sonos Browse album favorite toggles Sonos Favorites.
- Sonos Browse top-right overflow no longer contains album Favorite.
- Local Music album favorite button does not call Sonos Favorites.
- Background is darker and less saturated than the raw dominant artwork color.

- [ ] **Step 4: Commit verification-only fixes if needed**

If manual verification requires small fixes, commit them separately:

```bash
git add SonosWidget/AlbumDetailView.swift SonosWidget/LocalMusicDetailViews.swift SonosWidget/AlbumDetailSharedViews.swift
git commit -m "fix: polish shared album detail controls"
```

---

## Self-Review

- Spec coverage: The plan covers shared album UI, muted theme color, Sonos vs Apple Music favorite separation, and removal of album Favorite from the Browse overflow menu.
- Placeholder scan: No implementation step relies on an undefined later decision. The Local Music favorite action is explicitly a UI-level placeholder and not a hidden Sonos Favorite call.
- Type consistency: `AlbumFavoriteKind`, `AlbumPrimaryAction`, `AlbumOverflowAction`, and `AlbumThemeColorPolicy` are defined before use.
- Scope check: Playlist, artist, and track row refactors are intentionally excluded.
