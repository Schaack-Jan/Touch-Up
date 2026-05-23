# Touch Behavior Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows-like touch behavior — cursor follows finger by default, 2-finger drag always scrolls, cursor returns to pre-touch position after lift.

**Architecture:** All changes extend existing layers without structural refactoring. `TUCCursorUtilities` gains save/restore methods. `TUCTouchInputManager` exposes a new `restoresCursorPositionAfterTouch` BOOL property (synced from Swift via Combine, the same pattern as `postMouseEvents`). The existing but disabled `TwoFingerDrag` gesture recognition is re-enabled.

**Tech Stack:** Objective-C (TouchUpCore framework), Swift (Touch Up app), AppKit/CoreGraphics, Combine

**Spec:** `docs/superpowers/specs/2026-05-23-touch-behavior-design.md`

---

## File Map

| File | Change |
|---|---|
| `TouchUpCore/TUCCursorUtilities.h` | Add `saveCursorPosition`, `restoreCursorPosition` declarations |
| `TouchUpCore/TUCCursorUtilities.m` | Add `savedCursorPosition` private property + implementations |
| `TouchUpCore/TUCTouchInputManager.h` | Add `restoresCursorPositionAfterTouch` BOOL property |
| `TouchUpCore/TUCTouchInputManager.m` | Save on touch-down, restore on lift, re-enable TwoFingerDrag |
| `Touch Up/TouchUp.swift` | New property + Combine observer, updated defaults, TwoFingerDrag mapping, uiLabels |
| `Touch Up/SettingsView.swift` | New toggle in Gestures section |

---

## Task 1: TUCCursorUtilities — cursor save/restore

**Files:**
- Modify: `TouchUpCore/TUCCursorUtilities.h`
- Modify: `TouchUpCore/TUCCursorUtilities.m`

- [ ] **Step 1.1 — Add method declarations to `TUCCursorUtilities.h`**

  Replace the block of method declarations (after `- (CGPoint)currentCursorLocation;`) so the interface reads:

  ```objc
  - (CGPoint)currentCursorLocation;

  - (void)saveCursorPosition;
  - (void)restoreCursorPosition;

  - (void)bringWindowToFrontAt:(CGPoint)aLocation;
  ```

  Full updated header (only the `@interface` body — do not remove `NS_ASSUME_NONNULL_BEGIN/END` or copyright):

  ```objc
  @interface TUCCursorUtilities : NSObject

  + (instancetype)sharedInstance;

  @property CGFloat doubleClickTolerance;

  - (CGPoint)currentCursorLocation;

  - (void)saveCursorPosition;
  - (void)restoreCursorPosition;

  - (void)bringWindowToFrontAt:(CGPoint)aLocation;
  - (void)moveCursorTo:(CGPoint)aLocation;
  - (void)performClickAt:(CGPoint)aLocation;
  - (void)performSecondaryClickAt:(CGPoint)aLocation;
  - (void)dragCursorTo:(CGPoint)aLocation phase:(NSTouchPhase)phase;
  - (void)stopDraggingCursor;
  - (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase;
  - (void)magnifyLocationA:(CGPoint)p1 locationB:(CGPoint)p2 relativeP1:(CGPoint)r1 relP2:(CGPoint)r2;
  - (void)stopMagnifying;

  @end
  ```

- [ ] **Step 1.2 — Add `savedCursorPosition` to the private interface in `TUCCursorUtilities.m`**

  The file already has a private `@interface TUCCursorUtilities ()` block (lines 10–24). Add one property there:

  ```objc
  @interface TUCCursorUtilities ()

  @property NSInteger cursorClickCount;
  @property NSDate *timeOfLastClick;
  @property CGPoint locationOfLastClick;

  @property BOOL isLeftMouseDown;

  @property CGPoint momentumScrollTranslation;
  @property (strong) NSTimer *momentumScrollTimer;

  @property BOOL isMagnifying;
  @property CGFloat lastPinchDistance;

  @property CGPoint savedCursorPosition;   // ← add this line

  @end
  ```

- [ ] **Step 1.3 — Implement `saveCursorPosition` and `restoreCursorPosition` in `TUCCursorUtilities.m`**

  Add the two methods directly after the existing `- (CGPoint)currentCursorLocation` implementation (around line 52):

  ```objc
  - (void)saveCursorPosition {
      self.savedCursorPosition = [self currentCursorLocation];
  }

  - (void)restoreCursorPosition {
      CGWarpMouseCursorPosition(self.savedCursorPosition);
      CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                                 self.savedCursorPosition, kCGMouseButtonLeft);
      CGEventSetIntegerValueField(event, kCGMouseEventClickState, 0);
      CGEventPost(kCGSessionEventTap, event);
      CFRelease(event);
  }
  ```

- [ ] **Step 1.4 — Build to verify no compile errors**

  In Xcode: **Product → Build** (⌘B). Expected: Build Succeeded. No new warnings or errors.

- [ ] **Step 1.5 — Commit**

  ```bash
  git add TouchUpCore/TUCCursorUtilities.h TouchUpCore/TUCCursorUtilities.m
  git commit -m "feat(core): add cursor position save/restore to TUCCursorUtilities"
  ```

---

## Task 2: TUCTouchInputManager — new property, TwoFingerDrag, save/restore hooks

**Files:**
- Modify: `TouchUpCore/TUCTouchInputManager.h`
- Modify: `TouchUpCore/TUCTouchInputManager.m`

Depends on: Task 1 completed.

- [ ] **Step 2.1 — Add `restoresCursorPositionAfterTouch` property to `TUCTouchInputManager.h`**

  After the existing `@property BOOL ignoreOriginTouches;` declaration (around line 49), add:

  ```objc
  /**
   When YES, the cursor is moved back to its position before the touch began.
   Does not apply to hold-and-drag gestures (would undo the drag).
   */
  @property BOOL restoresCursorPositionAfterTouch;
  ```

- [ ] **Step 2.2 — Initialise the property in `TUCTouchInputManager.m`**

  In the `- (instancetype)init` method (around line 817), add one line after `self.ignoreOriginTouches = NO;`:

  ```objc
  self.restoresCursorPositionAfterTouch = NO;
  ```

- [ ] **Step 2.3 — Save cursor position on touch-down in `processTouchesForCursorInput`**

  In `TUCTouchInputManager.m`, find the `NSTouchPhaseBegan` block (around line 350):

  ```objc
  if (phase == NSTouchPhaseBegan) {
      [self performMouseEventForGesture:TUCCursorGestureTouchDown];
      return;
  }
  ```

  Replace it with:

  ```objc
  if (phase == NSTouchPhaseBegan) {
      if (self.restoresCursorPositionAfterTouch) {
          [[TUCCursorUtilities sharedInstance] saveCursorPosition];
      }
      [self performMouseEventForGesture:TUCCursorGestureTouchDown];
      return;
  }
  ```

- [ ] **Step 2.4 — Restore cursor position on touch lift in `processTouchesForCursorInput`**

  Find the `NSTouchPhaseEnded` block (around line 372). It currently ends with `return;` after the tap/gesture dispatch. Insert the restore call before that `return`:

  ```objc
  else if (phase == NSTouchPhaseEnded) {
      if (self.identifiedMultitouchGesture == _TUCCursorGestureNone) {
          if (self.cursorTouchDidHold) {
              [self performMouseEventForGesture:TUCCursorGestureHoldAndDrag];
          } else if (!self.cursorTouchQualifiedForTap) {
              [self performMouseEventForGesture:TUCCursorGestureDrag];
          }
      }

      [self stopCurrentGesture];

      if (self.cursorTouchQualifiedForTap) {
          [self performMouseEventForGesture:TUCCursorGestureTap];
      } else {
          if (self.identifiedMultitouchGesture != _TUCCursorGestureNone) {
              [self performMouseEventForGesture:self.identifiedMultitouchGesture];
          }
      }

      if (self.restoresCursorPositionAfterTouch && !self.cursorTouchDidHold) {
          [[TUCCursorUtilities sharedInstance] restoreCursorPosition];
      }

      return;
  }
  ```

- [ ] **Step 2.5 — Re-enable TwoFingerDrag gesture recognition**

  Find the commented-out `else` block inside the 2-finger trajectory comparison (around line 423):

  ```objc
  if (!CGPointEqualToPoint(trajectoryA, trajectoryB)) {
      self.identifiedMultitouchGesture = TUCCursorGesturePinch;
  }
  //                    else {
  //                        self.identifiedMultitouchGesture = TUCCursorGestureTwoFingerDrag;
  //                    }
  ```

  Replace with:

  ```objc
  if (!CGPointEqualToPoint(trajectoryA, trajectoryB)) {
      self.identifiedMultitouchGesture = TUCCursorGesturePinch;
  } else {
      self.identifiedMultitouchGesture = TUCCursorGestureTwoFingerDrag;
  }
  ```

- [ ] **Step 2.6 — Build to verify no compile errors**

  **Product → Build** (⌘B). Expected: Build Succeeded.

- [ ] **Step 2.7 — Commit**

  ```bash
  git add TouchUpCore/TUCTouchInputManager.h TouchUpCore/TUCTouchInputManager.m
  git commit -m "feat(core): add restoresCursorPositionAfterTouch, re-enable TwoFingerDrag scroll"
  ```

---

## Task 3: TouchUp.swift — property, Combine, defaults, gesture mapping, uiLabels

**Files:**
- Modify: `Touch Up/TouchUp.swift`

Depends on: Task 2 completed.

- [ ] **Step 3.1 — Add `isCursorRestoredAfterTouch` published property**

  In `TouchUp.swift`, in the `@Published` properties block (around line 38, with the other gesture booleans), add:

  ```swift
  @Published var isCursorRestoredAfterTouch = false
  ```

- [ ] **Step 3.2 — Sync the new property to `touchManager` via Combine**

  In `initPreferences()`, find the `self.observers = [` block (around line 227). Add one entry:

  ```swift
  self.observers = [
      $isPublishingMouseEventsEnabled.assign(to: \.postMouseEvents, on: touchManager),
      $holdDuration.assign(to: \.holdDuration, on: touchManager),
      $doubleClickDistance.assign(to: \.doubleClickTolerance, on: touchManager),
      $errorResistance.assign(to: \.errorResistance, on: touchManager),
      $ignoreOriginTouches.assign(to: \.ignoreOriginTouches, on: touchManager),
      $isCursorRestoredAfterTouch.assign(to: \.restoresCursorPositionAfterTouch, on: touchManager)
  ]
  ```

- [ ] **Step 3.3 — Update registered defaults and load the new property**

  In `initPreferences()`, update `defaults.register(defaults:)` to change `isScrollingWithOneFingerEnabled` default and add the new key:

  ```swift
  defaults.register(defaults: [
      "holdDuration" : 0.1,
      "doubleClickDistance" : 8,
      "errorResistance" : 4,
      "ignoreOriginTouches" : true,

      "isScrollingWithOneFingerEnabled" : false,   // changed from true
      "isSecondaryClickEnabled" : true,
      "isMagnificationEnabled" : true,
      "isClickWindowToFrontEnabled" : false,
      "isClickOnLiftEnabled" : false,
      "isCursorRestoredAfterTouch" : true           // new
  ])
  ```

  Then, at the end of the loading section (after the existing `isClickOnLiftEnabled = ...` line), add:

  ```swift
  isCursorRestoredAfterTouch = defaults.bool(forKey: "isCursorRestoredAfterTouch")
  ```

- [ ] **Step 3.4 — Save the new property in `savePreferences()`**

  In `savePreferences()`, after the last `defaults.set(isClickOnLiftEnabled, ...)` line, add:

  ```swift
  defaults.set(isCursorRestoredAfterTouch, forKey: "isCursorRestoredAfterTouch")
  ```

- [ ] **Step 3.5 — Fix `TwoFingerDrag` gesture-to-action mapping**

  In `action(for gesture:)` (around line 290), find:

  ```swift
  case .TUCCursorGestureTwoFingerDrag:
      return isScrollingWithOneFingerEnabled ? .drag : .scroll
  ```

  Replace with:

  ```swift
  case .TUCCursorGestureTwoFingerDrag:
      return .scroll
  ```

- [ ] **Step 3.6 — Add `uiLabels` entry for the new property**

  In `uiLabels<T>(for:)` (around line 328), add a new case before the `default:` fallback:

  ```swift
  case \.isCursorRestoredAfterTouch:
      return ("Restore cursor after touch",
              "After lifting your finger, the cursor returns to where it was before the touch.")
  ```

- [ ] **Step 3.7 — Build to verify no compile errors**

  **Product → Build** (⌘B). Expected: Build Succeeded.

- [ ] **Step 3.8 — Commit**

  ```bash
  git add "Touch Up/TouchUp.swift"
  git commit -m "feat(app): add cursor restoration setting, fix TwoFingerDrag → scroll mapping"
  ```

---

## Task 4: SettingsView.swift — new toggle

**Files:**
- Modify: `Touch Up/SettingsView.swift`

Depends on: Task 3 completed.

- [ ] **Step 4.1 — Add toggle for `isCursorRestoredAfterTouch` in `gestureSettings`**

  In `SettingsView.swift`, find the `gestureSettings` computed property (around line 55). Add the new toggle after the existing `Toggle(isOn: $model.isClickWindowToFrontEnabled)` block (the last toggle before the closing `}`):

  ```swift
  Toggle(isOn: $model.isClickWindowToFrontEnabled) {
      SettingsExplanationLabel(labels: model.uiLabels(for: \.isClickWindowToFrontEnabled))
  }

  Toggle(isOn: $model.isCursorRestoredAfterTouch) {
      SettingsExplanationLabel(labels: model.uiLabels(for: \.isCursorRestoredAfterTouch))
  }
  ```

- [ ] **Step 4.2 — Build to verify no compile errors**

  **Product → Build** (⌘B). Expected: Build Succeeded.

- [ ] **Step 4.3 — Manual smoke test**

  1. Run the app.
  2. Open Settings. Verify the new **"Restore cursor after touch"** toggle appears in the Gestures section and is **ON** by default.
  3. Verify the **"On Finger Drag"** picker defaults to **"Move Cursor"** (not "Scroll") on a fresh install (delete `~/Library/Preferences/com.sebastianhueber.Touch-Up.plist` to reset, then relaunch).
  4. Connect a touchscreen and verify:
     - 1-finger drag moves the cursor.
     - After lifting, the cursor returns to where it was before the touch.
     - 2-finger drag scrolls (e.g. in Safari or Finder).
     - 2-finger tap still produces a right-click context menu.
     - Pinch still zooms in supported apps.
  5. Toggle "Restore cursor after touch" OFF, touch the screen, lift — verify the cursor stays at the touch location.

- [ ] **Step 4.4 — Commit**

  ```bash
  git add "Touch Up/SettingsView.swift"
  git commit -m "feat(ui): add restore-cursor-after-touch toggle to Settings"
  ```

---

## Future Work (not implemented)

See spec section "Future Work: 3-Finger Gestures" for the planned extension points:
- New `TUCCursorGestureThreeFingerSwipe*` enum values in `TUCTouch.h`
- 3-touch detection block in `processTouchesForCursorInput` in `TUCTouchInputManager.m`
- New `TUCCursorAction` values if needed
- Mapping in `TouchUp.action(for:)` with optional Settings toggles
