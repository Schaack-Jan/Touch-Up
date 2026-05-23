# Touch Behavior Redesign — Design Spec
**Date:** 2026-05-23  
**Status:** Approved

---

## Overview

Improve touch input to match Windows touchscreen behavior: cursor follows finger by default, 2-finger scroll always active, and cursor returns to its pre-touch position after lifting.

---

## Goals

1. Default 1-finger drag moves cursor (not scroll)
2. 2-finger drag always scrolls, independent of 1-finger mode
3. Cursor returns to previous position after touch lift (configurable)
4. All behavior changes are non-breaking — existing users can reconfigure via Settings

---

## Out of Scope (Future)

3-finger gestures (Mission Control, App Switcher, Middle Click) — architecture is ready, implementation deferred. See [Future Work](#future-work).

---

## Architecture

No structural changes. All changes extend the existing layers:

```
HID Device
    └── TUCTouchInputManager   (gesture recognition + action dispatch)
            └── TUCCursorUtilities   (cursor/mouse event posting)
                    ↑
            TouchUp (delegate: maps gestures → actions, owns settings)
```

---

## Section 1: Settings Changes

### New property

| Property | Type | Default | UserDefaults key |
|---|---|---|---|
| `isCursorRestoredAfterTouch` | `Bool` | `true` | `isCursorRestoredAfterTouch` |

### Changed default

| Property | Old default | New default |
|---|---|---|
| `isScrollingWithOneFingerEnabled` | `true` | `false` |

`UserDefaults.register(defaults:)` is updated so new installs get the new defaults. Existing users keep their saved preference.

### Settings UI

In the **Gestures** section, add one new toggle after the existing "On Finger Drag" picker:

```
[ Toggle ] Restore cursor position after touch
           After lifting your finger, the cursor returns to where it was before the touch.
```

---

## Section 2: Cursor Position Restoration

### `TUCCursorUtilities` changes

Add two methods:

```objc
- (void)saveCursorPosition;    // stores currentCursorLocation into savedCursorPosition
- (void)restoreCursorPosition; // CGWarpMouseCursorPosition + mouseMoved event to savedCursorPosition
```

And a private property:

```objc
@property CGPoint savedCursorPosition;
```

### `TUCTouchInputManager` changes

- On `TUCCursorGestureTouchDown`: call `[utils saveCursorPosition]`
- On touch lift (`NSTouchPhaseEnded`), after `stopCurrentGesture`: call `[self.delegate restoreCursorIfNeeded]`

### Delegate protocol (`TUCTouchDelegate`)

Add optional method:

```objc
@optional
- (void)restoreCursorIfNeeded;
```

### `TouchUp` (Swift delegate) implementation

```swift
func restoreCursorIfNeeded() {
    guard isCursorRestoredAfterTouch else { return }
    TUCCursorUtilities.shared().restoreCursorPosition()
}
```

### When restoration is skipped

Restoration does **not** happen after `HoldAndDrag` (the user dragged an object — returning the cursor would be confusing). The delegate decides: `TouchUp` calls `restoreCursorIfNeeded` only when the last gesture was not `HoldAndDrag`.

The `TUCTouchInputManager` exposes the last identified gesture via a property so the delegate can inspect it:

```objc
@property (readonly) TUCCursorGesture lastPerformedGesture;
```

---

## Section 3: 2-Finger Scroll

### `TUCTouchInputManager.m` — re-enable TwoFingerDrag recognition

Uncomment (line ~426):

```objc
else {
    self.identifiedMultitouchGesture = TUCCursorGestureTwoFingerDrag;
}
```

This makes 2-finger same-direction drag produce `TUCCursorGestureTwoFingerDrag`. Pinch (opposite directions) and right-click (second finger stationary) are unaffected — they are recognized first.

### `TouchUp.swift` — fix gesture → action mapping

```swift
case .TUCCursorGestureDrag:
    // 1-finger drag: move cursor (default) or scroll, never both at once
    return isClickOnLiftEnabled ? .pointAndClick : (isScrollingWithOneFingerEnabled ? .scroll : .move)

case .TUCCursorGestureTwoFingerDrag:
    // always scroll — independent of 1-finger setting
    return .scroll
```

The old mapping (`isScrollingWithOneFingerEnabled ? .drag : .scroll`) is removed.

---

## Section 4: Default Value Change

In `TouchUp.initPreferences()`, update the registered default:

```swift
"isScrollingWithOneFingerEnabled": false,  // was: true
"isCursorRestoredAfterTouch": true,        // new
```

---

## Future Work: 3-Finger Gestures

The `TUCCursorGesture` enum and delegate `action(for:)` pattern are already extensible. To add 3-finger support later:

1. Add new enum values: `TUCCursorGestureThreeFingerSwipeUp`, `TUCCursorGestureThreeFingerSwipeLeft`, etc.
2. Add 3-touch detection in `processTouchesForCursorInput` (analogous to the existing 2-touch block)
3. Add new `TUCCursorAction` values if needed (e.g. `missionControl`, `appSwitcher`)
4. Map in `TouchUp.action(for:)` and optionally expose as settings

Planned mappings (Windows-style):
- 3-finger swipe up → Mission Control (`CGSMissionControl()` or key event simulation)
- 3-finger swipe left/right → App Switcher / Space switch
- 3-finger tap → Middle mouse button (optional setting)

---

## Files Changed

| File | Change |
|---|---|
| `TouchUpCore/TUCCursorUtilities.h` | Add `saveCursorPosition`, `restoreCursorPosition` |
| `TouchUpCore/TUCCursorUtilities.m` | Implement save/restore |
| `TouchUpCore/TUCTouchDelegate.h` | Add optional `restoreCursorIfNeeded` |
| `TouchUpCore/TUCTouchInputManager.h` | Add `lastPerformedGesture` property |
| `TouchUpCore/TUCTouchInputManager.m` | Re-enable TwoFingerDrag, call save/restore, expose lastPerformedGesture |
| `Touch Up/TouchUp.swift` | New property, new default, fix TwoFingerDrag mapping, implement `restoreCursorIfNeeded` |
| `Touch Up/SettingsView.swift` | New toggle for cursor restoration |
