# Touchscreen Calibration Plan for AI Agent

## Goal

Implement precise per-monitor touchscreen calibration in Touch Up.

The app must allow users to configure calibration values in a monitor-specific submenu. Calibration must always be scoped to one monitor only. Users must be able to undo calibration changes in Touch Up. Implement calibration versioning with a maximum of 5 saved previous versions per monitor.

## Non-Negotiable Requirements

- Calibration is per monitor, never global.
- Every connected monitor has its own calibration settings UI.
- Calibration values can be edited manually.
- Touch Up always provides a way to undo calibration for the selected monitor.
- Keep at most 5 historical calibration versions per monitor.
- Reset to default calibration must always be available, independent of history.
- Applying calibration to monitor A must not change monitor B.
- Existing behavior must remain unchanged when calibration is disabled or identity/default.
- The implementation must be precise enough for touchscreen use, not just approximate cursor correction.

## Current Code Context

Important files:

- `TouchUpCore/TUCScreen.h`
- `TouchUpCore/TUCScreen.m`
- `TouchUpCore/TUCTouch.h`
- `TouchUpCore/TUCTouch.m`
- `TouchUpCore/TUCTouchInputManager.h`
- `TouchUpCore/TUCTouchInputManager.m`
- `Touch Up/TouchUp.swift`
- `Touch Up/SettingsView.swift`
- `Touch Up/DebugView.swift`

Current behavior:

- `TUCScreen` wraps `NSScreen` and stores display ID, name, rotation, physical size, and frame.
- `TUCTouchInputManager` maps HID relative coordinates to screen-relative coordinates and then to absolute macOS coordinates.
- `TUCTouchInputManager.screenForTouchDevice(_:)` already assigns a HID touch device to a display via `assignedDisplayID`.
- `TouchUp` stores preferences in `UserDefaults`.
- `SettingsView` currently exposes global settings and the selected touchscreen, but no per-monitor calibration.

Critical conversion path:

1. HID contact reports raw normalized x/y values.
2. `processHIDValuesForTouchDevice` clamps them to `0...1`.
3. `updateTouch(... screen:sourceIdentifier:)` calls `convertDigitizerPoint(... toRelativeScreenPointOnScreen:)`.
4. Gesture logic uses `TUCTouch.location`.
5. Cursor events call `absoluteLocationForTouch`.
6. `absoluteLocationForTouch` calls `convertScreenPointRelativeToAbsolute`.
7. `TUCScreen.convertPointRelativeToAbsolute` maps relative screen coordinates to global macOS coordinates.

Calibration should be applied after rotation correction and before absolute coordinate conversion.

## Data Model

Create a calibration model in Swift for persistence and UI. The Objective-C core can receive plain numeric values or a lightweight Objective-C model.

Recommended Swift model:

```swift
struct TouchCalibration: Codable, Equatable, Identifiable {
    var id: UUID
    var monitorKey: String
    var monitorName: String
    var createdAt: Date
    var enabled: Bool

    var xOffset: CGFloat
    var yOffset: CGFloat
    var xScale: CGFloat
    var yScale: CGFloat

    var xSkew: CGFloat
    var ySkew: CGFloat
}
```

Default identity calibration:

```swift
enabled = false
xOffset = 0
yOffset = 0
xScale = 1
yScale = 1
xSkew = 0
ySkew = 0
```

Recommended transform:

```swift
let calibratedX = rawX * xScale + rawY * xSkew + xOffset
let calibratedY = rawY * yScale + rawX * ySkew + yOffset
```

Clamp calibrated x/y to `0...1` after applying calibration.

Why include skew:

- Offset/scale handles most simple misalignment.
- Skew allows a more accurate affine correction for panels where x/y drift across the surface.
- Values can default to zero and be hidden under an "Advanced" disclosure if needed.

## Monitor Identity

Do not rely only on `CGDirectDisplayID` for persisted calibration. It can change after reconnects, reboots, or display topology changes.

Add a stable monitor key to `TUCScreen`.

Recommended priority:

1. EDID-derived identity if available: vendor ID, product ID, serial number.
2. Fallback: display name + physical size.
3. Last fallback: current `CGDirectDisplayID`.

Implementation note:

- Add a `calibrationKey` property to `TUCScreen`.
- Compute it in `TUCScreen.m` during initialization.
- Keep `id` for runtime display assignment.
- Use `calibrationKey` for persisted calibration storage and history.

Suggested key examples:

```text
edid:vendor-product-serial
screen:name-widthMM-heightMM
display-id:12345678
```

## Persistence Store

Store all calibration data in one `Codable` container in `UserDefaults`.

Recommended key:

```text
touchCalibrationStore.v1
```

Recommended store:

```swift
struct TouchCalibrationStore: Codable {
    var schemaVersion: Int
    var current: [String: TouchCalibration]
    var history: [String: [TouchCalibration]]
}
```

Rules:

- Dictionary key is `TUCScreen.calibrationKey`.
- `current[monitorKey]` is the active calibration for that monitor.
- `history[monitorKey]` contains previous calibrations, newest first.
- Keep only 5 entries in each monitor history.
- Avoid duplicate consecutive versions.
- Reset to default should not depend on history availability.

## Versioning and Undo Rules

When user presses Apply for one monitor:

1. Load current calibration for that monitor.
2. If the new value equals the current value, do nothing.
3. Push the old current calibration into `history[monitorKey]`.
4. Remove consecutive duplicates.
5. Trim `history[monitorKey]` to max 5 entries.
6. Save the new calibration as `current[monitorKey]`.
7. Notify `TUCTouchInputManager` so new touch events use the updated calibration.

When user presses Undo for one monitor:

1. Read `history[monitorKey]`.
2. If empty, disable Undo.
3. Pop the newest history entry.
4. Set it as `current[monitorKey]`.
5. Save store.
6. Notify `TUCTouchInputManager`.

When user presses Reset for one monitor:

1. Push old current calibration into that monitor's history if it differs from identity.
2. Set current calibration to identity/default.
3. Save store.
4. Notify `TUCTouchInputManager`.

Important:

- Undo for monitor A must never inspect or mutate monitor B history.
- Reset to default must always be visible.
- Undo can be disabled when no history exists, but the option should remain visible.

## Core Integration

Add calibration lookup to the Objective-C touch pipeline.

Recommended approach:

1. Add a calibration property or provider to `TUCTouchInputManager`.
2. The Swift app model owns the persisted calibration store.
3. On startup and after each settings change, Swift updates the manager with active calibrations.

Possible Objective-C-friendly model:

```objc
@interface TUCTouchCalibration : NSObject
@property BOOL enabled;
@property CGFloat xOffset;
@property CGFloat yOffset;
@property CGFloat xScale;
@property CGFloat yScale;
@property CGFloat xSkew;
@property CGFloat ySkew;
- (CGPoint)applyToPoint:(CGPoint)point;
+ (instancetype)identityCalibration;
@end
```

Manager API:

```objc
@property (copy, nonatomic) NSDictionary<NSString *, TUCTouchCalibration *> *calibrationsByMonitorKey;
```

or:

```objc
- (void)setCalibration:(TUCTouchCalibration *)calibration forMonitorKey:(NSString *)monitorKey;
- (TUCTouchCalibration *)calibrationForScreen:(TUCScreen *)screen;
```

Apply calibration inside `updateTouch(... screen:sourceIdentifier:)`:

```objc
CGPoint rotatedPoint = [self convertDigitizerPoint:digitizerPoint toRelativeScreenPointOnScreen:touchscreen];
CGPoint calibratedPoint = [self applyCalibrationToPoint:rotatedPoint onScreen:touchscreen];
```

Then set:

```objc
touch.rawLocation = rotatedPoint;
touch.location = calibratedPoint;
```

Do not apply calibration twice in `absoluteLocationForTouch`.

## Touch Model Changes

Add raw location to `TUCTouch`.

In `TUCTouch.h`:

```objc
@property CGPoint rawLocation;
@property CGPoint previousRawLocation;
```

In `TUCTouch.m`:

- Initialize both to `CGPointZero`.
- Add setter behavior mirroring `location` so `previousRawLocation` updates correctly.

Purpose:

- `rawLocation` is the rotation-corrected but uncalibrated normalized screen point.
- `location` remains the calibrated normalized screen point.
- Debug and future calibration assistant can compare raw vs calibrated.

## Settings UI

In `SettingsView.swift`, add a new section named `Calibration`.

For each connected monitor in `model.connectedScreens`:

- Show monitor name.
- Show a nested submenu using `DisclosureGroup`.
- Include:
  - Enable Calibration toggle.
  - X Offset numeric input.
  - Y Offset numeric input.
  - X Scale numeric input.
  - Y Scale numeric input.
  - Advanced disclosure for X Skew and Y Skew.
  - Apply button.
  - Undo button.
  - Reset to Default button.
  - Optional list or picker of up to 5 previous versions.

Important UI behavior:

- Editing fields should update a draft calibration, not immediately overwrite history.
- Pressing Apply creates a history version.
- Undo operates only on the monitor in that submenu.
- Reset operates only on the monitor in that submenu.
- Display whether calibration is active for each monitor.

Recommended Swift state in `TouchUp`:

```swift
@Published var calibrationStore: TouchCalibrationStore
@Published var calibrationDrafts: [String: TouchCalibration]
```

Recommended methods:

```swift
func calibration(for screen: TUCScreen) -> TouchCalibration
func draftCalibration(for screen: TUCScreen) -> TouchCalibration
func updateCalibrationDraft(_ calibration: TouchCalibration, for screen: TUCScreen)
func applyCalibration(for screen: TUCScreen)
func undoCalibration(for screen: TUCScreen)
func resetCalibration(for screen: TUCScreen)
func calibrationHistory(for screen: TUCScreen) -> [TouchCalibration]
func restoreCalibrationVersion(_ calibration: TouchCalibration, for screen: TUCScreen)
func syncCalibrationsToTouchManager()
```

## Optional Calibration Assistant

Manual numeric input is required. A guided assistant is optional but recommended for precision.

Recommended assistant:

- Open a fullscreen overlay on the selected monitor.
- Show calibration targets at:
  - top-left
  - top-right
  - bottom-right
  - bottom-left
  - center
- Temporarily disable mouse event publishing while collecting samples.
- Collect multiple raw samples per target.
- Drop outliers.
- Use median or average of stable samples.
- Solve affine transform values.
- Save result as draft.
- User reviews and presses Apply.

This assistant should use `TUCTouch.rawLocation`, not calibrated `location`.

## Edge Cases

Handle these explicitly:

- No monitors connected: hide or disable calibration UI.
- Monitor key changes fallback path: keep old data, do not delete it automatically.
- Duplicate monitor names: UI must still use unique monitor keys internally.
- Touch device assigned to a different monitor after reconnect: calibration must follow the assigned monitor key.
- Calibration values that produce out-of-range points: clamp output to `0...1`.
- Invalid numeric values: prevent NaN/infinity from being saved.
- History full: keep newest 5 only.

## Testing Plan

Add focused tests where the project supports them. If no test target exists, add small isolated tests or at least keep transformation logic in testable pure Swift/Objective-C methods.

Required test cases:

- Identity calibration returns unchanged points.
- Offset calibration shifts x/y correctly.
- Scale calibration expands/shrinks correctly.
- Skew calibration affects the opposite axis correctly.
- Output is clamped to `0...1`.
- Applying a calibration pushes the previous version to that monitor's history.
- History is limited to 5 versions per monitor.
- Undo restores only the selected monitor.
- Reset restores identity/default only for the selected monitor.
- Two monitors with different calibration values remain independent.
- Disabled calibration behaves exactly like identity calibration.

Manual QA:

1. Connect two monitors.
2. Assign touchscreen to monitor A.
3. Set obvious calibration on monitor A.
4. Verify cursor changes only on monitor A.
5. Switch to monitor B and verify monitor B remains unchanged.
6. Apply six changes to monitor A.
7. Verify only five previous versions are retained.
8. Undo repeatedly and verify only monitor A changes.
9. Reset monitor A and verify default behavior is restored.

## Implementation Order

1. Add `calibrationKey` to `TUCScreen`.
2. Add calibration model/store in Swift.
3. Load/save calibration store from `UserDefaults`.
4. Add active calibration sync from `TouchUp` to `TUCTouchInputManager`.
5. Add Objective-C calibration object or equivalent manager storage.
6. Add `rawLocation` to `TUCTouch`.
7. Apply calibration in `TUCTouchInputManager` after rotation and before setting `touch.location`.
8. Add per-monitor calibration UI in `SettingsView`.
9. Implement Apply, Undo, Reset, and restore-version actions.
10. Add tests or isolated verification for transform and history behavior.
11. Manually verify multi-monitor behavior.

## Definition of Done

- Users can open Touch Up settings and configure calibration numbers per monitor.
- Calibration is persisted per monitor.
- Calibration affects live touch mapping.
- Calibration is applied once and only once.
- Undo is available per monitor.
- Version history is capped at 5 entries per monitor.
- Reset to default is always available.
- Monitor A and monitor B calibration states are independent.
- Existing users with no calibration data see unchanged behavior.
- Code is documented only where needed and follows the existing project style.
