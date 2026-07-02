# Windows-aehnliche Gestensteuerung: Umsetzungsplan

Stand: 2026-07-02

Dieser Plan ist absichtlich so geschrieben, dass ein anderer Agent ihn Schritt fuer Schritt abarbeiten kann. Vor der Umsetzung keine weiteren Produktionsdateien aendern. Erst diesen Plan lesen, dann den Arbeitsbaum pruefen, dann die Schritte in der angegebenen Reihenfolge ausfuehren.

## Ziel

Touch Up soll eine robuste Windows-aehnliche Gestensteuerung fuer USB-HID-Touchscreens bekommen. Die Gesten sollen nicht mehr ueber mehrere Legacy-Schichten verteilt sein, sondern in einer kleinen, expliziten Gesture-State-Machine erkannt und anschliessend als klare Cursor-Events gepostet werden.

Zielverhalten:

| Geste | Bedingung | Ergebnis |
| --- | --- | --- |
| 1 Finger Tap | Finger runter/hoch innerhalb Tap-Zeit und Tap-Bewegungstoleranz | Cursor zur Touch-Position, Left Click beim Loslassen |
| 1 Finger Drag | Finger bewegt sich ueber Bewegungsgrenze, bevor Long-Press greift | Cursor folgt absolut der Fingerposition, kein Click beim Loslassen |
| 1 Finger Drag auf Fenster-Titelleiste | Finger startet auf einer verschiebbaren Fensterzone und bewegt sich ueber Bewegungsgrenze | Left Mouse Down/Drag/Up, damit das Fenster per Touch verschoben wird |
| 1 Finger Press and Hold | Finger bleibt bis `holdDuration` innerhalb Hold-Toleranz | Right Mouse Down an Touch-Position; Right Mouse Up bei Loslassen/Cancel |
| 1 Finger Hold + Move | Nach Right Mouse Down bewegt sich der Finger | Right Mouse Drag bis Loslassen |
| 2 Finger Drag | Zwei aktive Finger bewegen ihren Mittelpunkt ueber Scroll-Grenze, ohne Pinch-Grenze zu ueberschreiten | Pixel Scroll mit Delta aus Mittelpunktbewegung |
| 2 Finger Pinch | Abstandsaenderung der zwei Finger ueberschreitet Pinch-Grenze | Magnify/Zoom-Geste |
| 2 Finger Tap | Optional, wenn Secondary-Click-Setting aktiv bleibt | Secondary Click an Mittelpunkt oder primaerer Touch-Position |
| Cancel / Device Drop | Touch verschwindet, Error Resistance laeuft aus, App stoppt | Alle gedrueckten Buttons und aktiven Gesten sauber beenden |

Nicht-Ziele fuer diesen Durchlauf:

- Keine Drei- oder Vier-Finger-Gesten.
- Keine macOS-Trackpad-Emulation ueber private Felder ausser der bereits vorhandenen Magnify-Logik.
- Keine Aenderungen an HID-Device-Erkennung, Screen-Mapping oder Berechtigungslogik, ausser sie blockieren die Gesture-State-Machine.

## Aktueller Befund

Relevante Dateien:

- `TouchUpCore/TUCTouchInputManager.m`: HID-Touch-Updates, Touch-Set, aktuelle Gesture-Erkennung, Event-Dispatch.
- `TouchUpCore/TUCTouchInputManager.h`: oeffentliche Manager-Properties wie `holdDuration`.
- `TouchUpCore/TUCTouch.h` und `.m`: Touch-Modell, Phase, Position, einfache Trajectory-Helfer.
- `TouchUpCore/TUCCursorUtilities.h` und `.m`: Posting von CGEvents fuer Move, Click, Drag, Scroll, Magnify.
- `TouchUpCore/TUCTouchDelegate.h`: oeffentliche Delegate-Schnittstelle inklusive Legacy-`actionForGesture:`.
- `Touch Up/TouchUp.swift`: App-Model, UserDefaults, Mapping von Gesten auf Aktionen.
- `Touch Up/SettingsView.swift`: UI fuer alte Gestenoptionen.
- `TouchUpCore/Touch.h` und `.m`: alte, offenbar ungenutzte Duplikate des Touch-Modells. Sie sind nicht im Xcode-Projekt verdrahtet.

Probleme in der aktuellen Gesture-Implementierung:

1. `processTouchesForCursorInputForSourceState:` ist eine lange Mischmethode. Sie erkennt Gesten, verwaltet State, fragt App-Settings ab und postet indirekt Events.
2. `cursorTouch` und `gestureAdditionalTouch` sind schwache Objekt-Referenzen auf Objekte im `touchSet`. Durch verzoegertes Entfernen und Reuse sind Stale-State-Fehler schwer zu kontrollieren.
3. Zwei-Finger-Drag wird ueber `trajectorySign` beider Finger in einem einzelnen Frame erkannt. Bei echten HID-Reports kommen Finger oft nicht synchron, wodurch parallele Bewegung instabil oder gar nicht erkannt wird.
4. Pinch vs Scroll wird nur ueber Richtungsgleichheit unterschieden. Das ist zu grob; ein stabiler Ansatz braucht Mittelpunktdelta und Abstandsaenderung mit Schwellwerten.
5. Long-Press, Hold-and-Drag und Rechtsklick sind semantisch vermischt. Das alte iPadOS-artige `HoldAndDrag` soll fuer Windows-Default nicht mehr die primaere Semantik sein.
6. Fenster koennen aktuell nicht zuverlaessig per Touch verschoben werden, weil One-Finger-Drag nur Cursor-Move sein soll und kein Left-Button-Drag auf der Titelleiste gestartet wird.
7. `TUCCursorUtilities` stoppt aktuell teilweise andere Modi implizit in Methoden wie `moveCursorTo:`. Fuer eine State-Machine sollten Button-Down/Up-Zustaende explizit beendet werden, sonst bricht ein gedrueckter Rechtsklick leicht unbeabsichtigt ab.
8. `TouchUp.swift` entscheidet per Delegate `action(for:)`, was eine Geste tut. Fuer ein klares Windows-Profil sollte die App nicht mehr die Core-Gesten semantisch umbiegen.
9. Settings wie `isScrollingWithOneFingerEnabled` und `isClickOnLiftEnabled` sind Altlasten des alten Profils und koennen Windows-Defaults ueberlagern.
10. README und UI wurden im letzten Versuch bereits teilweise angepasst, aber ohne tragfaehige Core-Architektur.

Wichtig: Der Arbeitsbaum enthaelt noch uncommitted Aenderungen aus dem vorherigen Versuch in diesen Dateien:

- `README.md`
- `Touch Up/SettingsView.swift`
- `Touch Up/TouchUp.swift`
- `TouchUpCore/TUCCursorUtilities.h`
- `TouchUpCore/TUCCursorUtilities.m`
- `TouchUpCore/TUCTouch.h`
- `TouchUpCore/TUCTouchInputManager.m`

Diese Aenderungen nicht blind verwerfen. Zuerst vergleichen, dann kontrolliert durch die neue Umsetzung ersetzen.

## Zielarchitektur

### Kernidee

Eine eindeutige State-Machine pro `sourceIdentifier` verarbeitet aktive Touches und erzeugt Befehle an `TUCCursorUtilities`.

Die Gesture-Erkennung soll nicht mehr ueber `TUCCursorGesture -> TUCCursorAction -> Delegate -> Swift-Settings` laufen. Diese Legacy-Schicht kann fuer API-Kompatibilitaet vorerst bestehen bleiben, darf aber fuer das Windows-Profil nicht mehr die zentrale Steuerung sein.

### Neue interne State-Daten

In `TUCTouchInputManager.m` entweder `TUCInputSourceState` erweitern oder eine private Hilfsklasse `TUCWindowsGestureState` einfuehren. Keine oeffentliche API noetig.

Empfohlene Felder:

```objc
typedef NS_ENUM(NSInteger, TUCWindowsGestureKind) {
    TUCWindowsGestureKindIdle,
    TUCWindowsGestureKindOneFingerPending,
    TUCWindowsGestureKindOneFingerMove,
    TUCWindowsGestureKindWindowMove,
    TUCWindowsGestureKindRightButtonDown,
    TUCWindowsGestureKindTwoFingerPending,
    TUCWindowsGestureKindTwoFingerScroll,
    TUCWindowsGestureKindPinch,
    TUCWindowsGestureKindSuppressUntilAllLifted
};
```

Pro Quelle speichern:

- `TUCWindowsGestureKind activeGesture`
- `NSInteger primaryContactID`
- `NSInteger secondaryContactID`
- `NSDate *gestureStartDate`
- `CGPoint primaryStartLocation`
- `CGPoint secondaryStartLocation`
- `CGPoint lastPrimaryLocation`
- `CGPoint lastSecondaryLocation`
- `CGPoint lastCentroid`
- `CGFloat initialTwoFingerDistance`
- `CGFloat lastTwoFingerDistance`
- `BOOL tapCandidate`
- `BOOL windowMoveCandidate`
- `CGPoint windowMoveStartScreenLocation`
- `NSInteger windowMoveWindowNumber` oder eine vergleichbare Debug-ID, falls per CGWindowList erkannt
- `BOOL rightButtonIsDown`
- `BOOL suppressClickUntilAllLifted`

Warum Contact IDs statt schwacher Touch-Referenzen:

- Ein Touch kann spaeter aus `touchSet` entfernt werden.
- Contact IDs plus `sourceIdentifier` lassen sich stabil neu aufloesen.
- Der Zustand bleibt klar, wenn ein Finger endet, aber noch fuer kurze Zeit im Set liegt.

### Schwellwerte

Als private Konstanten in `TUCTouchInputManager.m` starten:

```objc
static const CGFloat TUCTapMaxMovementMM = 4.0;
static const CGFloat TUCMoveStartThresholdMM = 1.5;
static const CGFloat TUCHoldMaxMovementMM = 3.0;
static const CGFloat TUCWindowMoveStartThresholdMM = 1.5;
static const CGFloat TUCScrollStartThresholdMM = 1.5;
static const CGFloat TUCPinchStartScaleDelta = 0.04; // 4%
static const CGFloat TUCScrollPinchSuppressScaleDelta = 0.03;
static const NSTimeInterval TUCDefaultHoldDuration = 0.55;
```

`holdDuration` sollte weiterhin konfigurierbar bleiben, aber Default und Sliderbereich muessen zum Rechtsklick passen. Der bisherige Default `0.1` Sekunden ist fuer Windows-aehnlichen Press-and-Hold viel zu kurz.

### Geometrie-Helfer

In `TUCTouchInputManager.m` private Helfer einfuehren:

- `- (NSArray<TUCTouch *> *)activeTouchesSortedForSourceIdentifier:(NSInteger)sourceIdentifier`
- `- (nullable TUCTouch *)activeTouchWithContactID:(NSInteger)contactID sourceIdentifier:(NSInteger)sourceIdentifier`
- `- (CGFloat)distanceInMMFrom:(CGPoint)a to:(CGPoint)b onScreen:(TUCScreen *)screen`
- `- (CGPoint)absoluteLocationForTouch:(TUCTouch *)touch`
- `- (CGPoint)centroidForTouch:(TUCTouch *)a otherTouch:(TUCTouch *)b`
- `- (CGFloat)distanceBetweenTouch:(TUCTouch *)a otherTouch:(TUCTouch *)b`
- `- (BOOL)isPointInDraggableWindowArea:(CGPoint)screenPoint onScreen:(TUCScreen *)screen`
- `- (BOOL)isPointInApproximateTitlebar:(CGPoint)screenPoint windowBounds:(CGRect)windowBounds`
- `- (void)resetWindowsGestureForSourceState:(TUCInputSourceState *)sourceState endingButtons:(BOOL)endingButtons`

Bei Distanzen nicht nur `physicalSize.width` verwenden. Fuer relative Punkte in x/y die physische Breite und Hoehe beruecksichtigen:

```objc
CGFloat dxMM = fabs(a.x - b.x) * screen.physicalSize.width;
CGFloat dyMM = fabs(a.y - b.y) * screen.physicalSize.height;
return sqrt(dxMM * dxMM + dyMM * dyMM);
```

### Fenster-Hit-Testing fuer Touch-Window-Move

Fenster-Verschieben soll explizit als Windows-aehnliches Draggen der Titelleiste funktionieren, ohne normales One-Finger-Cursor-Move in einen generellen Left-Drag zu verwandeln.

Empfohlener Ansatz:

1. Primaer Accessibility-Hit-Testing nutzen, weil Touch Up ohnehin Accessibility-Rechte zum Posten von Mouse Events braucht:
   - `AXUIElementCreateSystemWide()`
   - `AXUIElementCopyElementAtPosition(systemWide, screenPoint.x, screenPoint.y, &element)`
   - Rollen/Subrollen pruefen, z.B. `AXTitleBar`, `AXToolbar`, Fenster-Chrome oder andere eindeutig verschiebbare Bereiche.
2. Falls AX-Hit-Testing fehlschlaegt, Fallback ueber `CGWindowListCopyWindowInfo`:
   - Topmost on-screen window unter dem Punkt finden.
   - Menu Bar, Desktop, Dock und systemeigene Overlays ausschliessen.
   - Eine konservative Titelleistenzone am oberen Fensterrand annehmen, z.B. 28 bis 44 pt Hoehe, je nach Window-Bounds.
3. Kein Window-Move starten, wenn der Punkt in Content-Controls liegt. Im Zweifel lieber Cursor-Move statt versehentlich Fenster ziehen.
4. Die Erkennung nur beim Start eines One-Finger-Pending speichern (`windowMoveCandidate`). Nicht waehrend derselben Geste dynamisch umschalten, wenn der Finger spaeter ueber eine Titelleiste faehrt.
5. Falls das Fenster nicht frontmost ist, trotzdem mit normalem Left-Down/Drag testen. macOS kann inaktive Fenster in vielen Faellen direkt ziehen. Wenn das nicht stabil ist, optional vor dem Window-Move einen sehr kurzen Focus-Click nur fuer Titelleistenpunkte einfuehren und per QA absichern.

## Refactoring- und Implementierungsschritte

### Schritt 1: Arbeitsbaum und Baseline sichern

1. `git status --short` ausfuehren.
2. `git diff --stat` und `git diff --check` ausfuehren.
3. Die vorherigen Versuchsaenderungen in den sieben genannten Dateien bewusst in die neue Umsetzung integrieren oder ersetzen. Nicht per `git checkout --` arbeiten, ausser der User fordert das explizit.
4. Build-Befehl fuer spaetere Verifikation vormerken:

```sh
xcodebuild -project 'Touch Up.xcodeproj' -scheme 'Touch Up' -configuration Debug -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO build
```

### Schritt 2: Altlasten im Modell identifizieren und entfernen

Entfernen oder isolieren:

- `TUCCursorActionSecondaryDrag` aus dem vorherigen Versuch wieder entfernen, falls es durch klar benannte Cursor-Utility-Methoden ersetzt wird.
- `secondaryDragCursorTo:` und `stopSecondaryDraggingCursor` durch explizite Methoden ersetzen:
  - `rightMouseDownAt:`
  - `rightMouseDraggedTo:`
  - `rightMouseUp`
  - `releaseAllButtons`
- Legacy-Kommentar in `TUCTouchInputManager.h` anpassen: `holdDuration` beschreibt kuenftig Press-and-Hold fuer Rechtsklick, nicht Hold-and-Drag.
- `TouchUpCore/Touch.h` und `TouchUpCore/Touch.m` loeschen, wenn nach `rg` weiterhin keine Nutzung existiert. Da sie nicht im Xcode-Projekt sind, reicht Dateiloeschung. Vorher pruefen, ob externe Includes ausserhalb des Projektfiles existieren.
- Das alte App-Mapping `TouchUp.action(for:)` nicht mehr als Quelle fuer Windows-Gesten verwenden. Entweder:
  - Methode entfernen, nachdem `TUCTouchDelegate` `actionForGesture:` optional geworden ist; oder
  - Methode bestehen lassen, aber im Core nicht mehr aufrufen.

Empfohlene API-kompatible Loesung:

1. In `TUCTouchDelegate.h` `actionForGesture:` in einen `@optional`-Block verschieben und als Legacy kommentieren.
2. `TUCTouchInputManager.m` fuer das neue Windows-Profil nicht mehr ueber `[self.delegate actionForGesture:]` verzweigen lassen.
3. Die Enums `TUCCursorGesture` und `TUCCursorAction` vorerst in `TUCTouch.h` behalten, aber nicht mehr fuer das Windows-Profil erweitern.

### Schritt 3: `TUCCursorUtilities` bereinigen

Ziel: Cursor-Utilities posten nur Events und verwalten Button-Zustaende. Sie entscheiden keine Gesten.

Konkret:

1. State-Felder:
   - `isLeftMouseDown`
   - `isRightMouseDown`
   - `cursorClickCount`
   - Momentum/Magnify-State wie bisher
2. Neue oder bereinigte Methoden in `TUCCursorUtilities.h`:

```objc
- (void)moveCursorTo:(CGPoint)aLocation;
- (void)performClickAt:(CGPoint)aLocation;
- (void)performSecondaryClickAt:(CGPoint)aLocation;

- (void)leftMouseDownAt:(CGPoint)aLocation;
- (void)leftMouseDraggedTo:(CGPoint)aLocation;
- (void)leftMouseUp;

- (void)rightMouseDownAt:(CGPoint)aLocation;
- (void)rightMouseDraggedTo:(CGPoint)aLocation;
- (void)rightMouseUp;

- (void)releaseAllButtons;
- (void)scroll:(CGPoint)translation phase:(NSTouchPhase)phase;
- (void)cancelMomentumScroll;
```

3. `moveCursorTo:` soll nicht mehr automatisch Buttons releasen. Buttons werden durch die State-Machine beendet. Ausnahme: `performClickAt:` und `performSecondaryClickAt:` duerfen vorher `releaseAllButtons` aufrufen, um haengende Buttons zu vermeiden.
4. `scroll:` soll aktive Buttons nicht implizit beenden; der Gesture-Recognizer ruft vor Scroll-Start `releaseAllButtons`.
5. `stopDraggingCursor` kann als Legacy-Wrapper um `leftMouseUp` bestehen bleiben, falls andere Stellen ihn noch nutzen.
6. Magnify vor Start sicher mit `releaseAllButtons` kombinieren.

### Schritt 4: `TUCInputSourceState` umbauen

In `TUCInputSourceState` alte Felder schrittweise ersetzen:

Alt:

- `cursorTouch`
- `gestureAdditionalTouch`
- `cursorTouchQualifiedForTap`
- `cursorTouchDidHold`
- `cursorTouchStationarySinceDate`
- `pinchDistance`
- `identifiedMultitouchGesture`

Neu:

- `activeGesture`
- Contact-ID-basierte Primary/Secondary-Felder
- Start- und Last-Positionsfelder
- Zeitstempel
- Window-Move-Kandidat, Startpunkt und optional erkannte Window-ID
- Right-Button-Status
- Suppression-Flag fuer "nicht klicken, bis alle Finger weg sind"

Wenn der Umbau zu gross fuer einen Patch wird, zuerst neue Felder ergaenzen und alte Felder nach Build-Erfolg entfernen.

### Schritt 5: Aktive Touches stabil sortieren

`[[self activeTouchesForSourceIdentifier:] allObjects]` ist unsortiert. Fuer reproduzierbare Zwei-Finger-Gesten:

1. Aktive Touches nach `contactID` sortieren.
2. Wenn bereits `primaryContactID` oder `secondaryContactID` gesetzt ist, diese IDs bevorzugt weiterverwenden.
3. Beim Start einer Zwei-Finger-Geste:
   - Wenn vorher ein primaerer Touch existierte, bleibt er primary.
   - Der neue/andere aktive Touch wird secondary.
   - Wenn zwei Finger gleichzeitig starten, der kleinere `contactID` primary, der andere secondary.

### Schritt 6: Neue State-Machine implementieren

`processTouchesForCursorInputForSourceState:` soll am Ende ungefaehr so aussehen:

```objc
- (void)processTouchesForCursorInputForSourceState:(TUCInputSourceState *)sourceState {
    if (!self.postMouseEvents) return;

    NSArray<TUCTouch *> *activeTouches = [self activeTouchesSortedForSourceIdentifier:sourceState.sourceIdentifier];
    [self advanceWindowsGestureWithActiveTouches:activeTouches sourceState:sourceState];
}
```

Die neue Methode `advanceWindowsGestureWithActiveTouches:sourceState:` implementiert:

#### Keine aktiven Touches

- Wenn Right/Left Button down: Button up posten.
- Wenn Magnify aktiv: `stopMagnifying`.
- Wenn Scroll aktiv: Scroll-Ende bzw. Momentum nur, wenn gewuenscht.
- State auf Idle setzen.

#### Ein aktiver Touch

Wenn State Idle:

- Primary setzen.
- Startposition und Startzeit setzen.
- `windowMoveCandidate` ueber `isPointInDraggableWindowArea:onScreen:` am Touch-Startpunkt bestimmen.
- `windowMoveStartScreenLocation` auf die absolute Startposition setzen.
- State `OneFingerPending`.
- Cursor zur absoluten Touch-Position bewegen.

Wenn State `OneFingerPending`:

- Distanz zur Startposition in mm berechnen.
- Wenn `windowMoveCandidate == YES` und Distanz > `TUCWindowMoveStartThresholdMM`:
  - State `WindowMove`.
  - `releaseAllButtons`.
  - Cursor zur Startposition bewegen.
  - `leftMouseDownAt:windowMoveStartScreenLocation` posten.
  - Direkt danach `leftMouseDraggedTo:` zur aktuellen Touch-Position posten.
  - Tap/Long-Press-Kandidat beenden.
- Sonst, wenn Distanz > `TUCMoveStartThresholdMM`:
  - State `OneFingerMove`.
  - Cursor zur aktuellen Position bewegen.
  - Tap/Long-Press-Kandidat beenden.
- Sonst, wenn Zeit seit Start >= `holdDuration` und Distanz <= `TUCHoldMaxMovementMM`:
  - State `RightButtonDown`.
  - Cursor zur aktuellen Position bewegen.
  - `rightMouseDownAt:` posten.
- Sonst:
  - Cursor optional weiter exakt auf Touch-Position halten, aber keinen Click posten.

Wenn State `OneFingerMove`:

- Cursor zur aktuellen Position bewegen.
- Kein Click beim Loslassen.

Wenn State `WindowMove`:

- Bei Bewegung `leftMouseDraggedTo:` zur aktuellen absoluten Touch-Position posten.
- Bei Stillstand nichts posten.
- Kein Left Click beim Loslassen; nur `leftMouseUp`.
- Wenn ein zweiter Finger dazukommt, Window-Move zuerst mit `leftMouseUp` beenden und danach `SuppressUntilAllLifted` setzen. Nicht in Scroll/Pinch umdeuten.

Wenn State `RightButtonDown`:

- Bei Bewegung `rightMouseDraggedTo:` posten.
- Bei Stillstand nichts posten oder nur Cursorlocation nicht veraendern.

Wenn State `SuppressUntilAllLifted`:

- Keine neuen Clicks oder Long-Presses starten, bis `activeTouches.count == 0`.

#### Ein Touch endet

Da `TUCTouch.phase` auf `Ended` gesetzt wird, bevor der Touch spaeter entfernt wird, die Endlogik nicht nur aus `activeTouches` ableiten. In `didProcessReportForSourceIdentifier:` oder direkt nach Touch-Ende sicherstellen:

- Wenn State `OneFingerPending` und Finger endet innerhalb Tap-Toleranz: `performClickAt:` an letzter Position.
- Wenn State `RightButtonDown`: `rightMouseUp`.
- Wenn State `WindowMove`: `leftMouseUp`.
- Wenn State `OneFingerMove`: kein Click.
- Danach State Idle.

Falls das einfacher ist: In `advanceWindowsGesture...` eine zweite Liste `endedTouchesForSourceIdentifier:` berechnen, solange ended Touches noch im Set sind.

#### Zwei aktive Touches

Wenn State `OneFingerPending` oder `OneFingerMove`:

- In `TwoFingerPending` wechseln.
- Primaeren Touch behalten, zweiten Touch setzen.
- Start-Centroid und initiale Distanz speichern.
- Tap/Long-Press fuer den ersten Finger unterdruecken.

Wenn State `WindowMove`:

- Window-Move mit `leftMouseUp` beenden.
- In `SuppressUntilAllLifted` wechseln, damit der verbleibende oder zweite Finger nicht unmittelbar Tap/Scroll ausloest.

Wenn State Idle:

- Zwei Touches stabil waehlen.
- In `TwoFingerPending` wechseln.
- Start-Centroid und initiale Distanz speichern.

Wenn State `TwoFingerPending`:

- Aktuellen Centroid berechnen.
- Aktuelle Distanz berechnen.
- `centroidDeltaMM` und `scaleDelta` berechnen.
- Wenn `fabs(scaleDelta) >= TUCPinchStartScaleDelta`:
  - State `Pinch`.
  - `releaseAllButtons`.
  - Magnify starten.
- Sonst wenn `centroidDeltaMM >= TUCScrollStartThresholdMM` und `fabs(scaleDelta) < TUCScrollPinchSuppressScaleDelta`:
  - State `TwoFingerScroll`.
  - `releaseAllButtons`.
  - Last-Centroid setzen, noch keinen grossen Sprung posten.

Wenn State `TwoFingerScroll`:

- Delta aus aktuellem Centroid minus letztem Centroid berechnen.
- Delta in absolute Pixel umrechnen.
- `scroll:phase:` mit `NSTouchPhaseMoved` posten.
- Last-Centroid aktualisieren.

Wenn State `Pinch`:

- Magnify mit Mittelpunkt und Distanzdelta posten.
- Last-Distanz aktualisieren.

#### Einer von zwei Touches endet

- Scroll oder Pinch sauber beenden.
- Kein Tap fuer den verbleibenden Finger posten.
- State `SuppressUntilAllLifted`, bis alle Finger weg sind.

#### Mehr als zwei aktive Touches

- Fuer diesen Durchlauf: aktive Gesten beenden, `releaseAllButtons`, State `SuppressUntilAllLifted`.
- Keine Events posten, bis alle Finger weg sind.

### Schritt 7: Event-Details richtig kalibrieren

Scroll-Richtung:

1. Bestehende `scroll:`-Methode nutzt `CGEventCreateScrollWheelEvent2(..., translation.y, translation.x, 0)`.
2. Bei manueller QA pruefen:
   - Zwei Finger nach unten: Content soll Windows-aehnlich/natuerlich in die erwartete Richtung laufen.
   - Zwei Finger nach oben: Gegenrichtung.
3. Wenn invertiert, genau eine Stelle aendern: Entweder Translation in der State-Machine negieren oder in `TUCCursorUtilities scroll:`. Nicht an mehreren Stellen korrigieren.

Right-Click:

- `rightMouseDownAt:` muss genau einmal feuern, wenn Long-Press threshold erreicht ist.
- `rightMouseUp` muss bei Loslassen, Cancel, Device Disconnect, `postMouseEvents = NO` und App Stop feuern.
- Kein zusaetzlicher Left Click nach Right Click.

Tap:

- Tap wird beim Loslassen gepostet, nicht beim Touch Down.
- Touch Down darf nur Cursor bewegen.

Fenster verschieben:

- Window-Move startet nur, wenn der erste Touch auf einer erkannten Titelleiste oder anderweitig verschiebbaren Fensterzone beginnt.
- Beim Ueberschreiten der Window-Move-Schwelle wird ein normaler Left-Button-Drag gepostet: erst `leftMouseDownAt:` am Startpunkt, dann `leftMouseDraggedTo:` an die aktuelle Touch-Position.
- Beim Loslassen, Cancel, zweitem Finger, Device Disconnect oder `postMouseEvents = NO` muss `leftMouseUp` garantiert gepostet werden.
- Normales One-Finger-Drag in Fensterinhalt bleibt Cursor-Move und darf keinen Left-Button-Drag starten.
- Press-and-Hold gewinnt, wenn der Finger auf der Titelleiste stationaer bleibt und `holdDuration` vor der Bewegungsschwelle erreicht. Das ergibt wie Windows einen Rechtsklick statt Fensterbewegung.

### Schritt 8: Settings und Defaults auf Windows-Profil vereinfachen

`Touch Up/TouchUp.swift`:

- Default `holdDuration` auf ca. `0.55` setzen.
- UserDefaults-Version fuer Gestenprofil auf neue Version setzen, z.B. `"gestureProfileVersion": 2`.
- Bei Migration:
  - `isScrollingWithOneFingerEnabled = false`
  - `isClickOnLiftEnabled = false`
  - `isSecondaryClickEnabled = true` nur fuer optionalen Two-Finger-Tap, nicht fuer Press-and-Hold.
  - `isMagnificationEnabled = true`
- `action(for:)` entfernen, wenn `TUCTouchDelegate.actionForGesture:` optional ist und Core es nicht mehr braucht. Sonst als Legacy belassen, aber nicht mehr von Core aufrufen.

`Touch Up/SettingsView.swift`:

- Den Picker "One Finger Drag: Move Cursor / Scroll / Point and Click" entfernen oder in einen klar benannten Advanced/Legacy-Abschnitt verschieben.
- Fuer Windows-Default sichtbare Controls:
  - Toggle "Control Mouse with Touch"
  - Toggle "Move Windows by Title Bar Drag" optional, Default `true`
  - Toggle "Two Finger Tap Secondary Click" optional
  - Toggle "Pinch to Zoom"
  - Slider "Press and Hold Duration" mit Bereich etwa `0.3...1.2`, Step `0.05`
  - Double Click Zone
  - Troubleshooting wie bisher
- Texte nicht mehr "iPadOS", "Hold and Drag" oder "Point and Click" nennen.

`README.md`:

- README am Ende der Umsetzung an echte Defaults angleichen.
- Geste-Liste mit den Zielgesten aus diesem Plan synchron halten.

### Schritt 9: Tests vorbereiten

Es gibt aktuell kein Testtarget. Trotzdem soll die neue Logik testbar gebaut werden.

Empfohlene Minimalstrategie:

1. Gesture-State-Machine so schreiben, dass sie ihre Entscheidungen moeglichst in kleinen Methoden trifft.
2. `TUCCursorUtilities` nicht direkt in Entscheidungsmethoden instanziieren, sondern ueber einen kleinen internen Wrapper aufrufen, der spaeter mockbar ist.
3. Optional ein neues Testtarget `TouchUpCoreTests` anlegen, wenn die Xcode-Projektpflege vertretbar ist.

Testfaelle, die mindestens manuell oder automatisiert abgedeckt werden muessen:

| Test | Eingabe | Erwartung |
| --- | --- | --- |
| Single tap | Down, kleiner Move, Up < Tap-Toleranz | Move + Left Click, kein Scroll/Right |
| Single drag | Down, Move > MoveThreshold, Up | Cursor bewegt sich, kein Click |
| Window move | Down auf Titelleiste, Move > WindowMoveThreshold, Up | Left Down, Left Drag Events, Left Up; Fenster bewegt sich |
| Window titlebar tap | Down/Up auf Titelleiste ohne Bewegung | Normaler Left Click, kein Drag |
| Window content drag | Down im Fensterinhalt, Move > MoveThreshold, Up | Cursor bewegt sich, kein Left Down |
| Long press | Down, stationaer bis holdDuration, Up | Right Down, Right Up, kein Left Click |
| Long press drag | Down, holdDuration, Move, Up | Right Down, Right Drag Events, Right Up |
| Two-finger scroll | Zwei Touches, parallele Centroid-Bewegung | Scroll Events, kein Click |
| Pinch | Zwei Touches, Abstandsaenderung > PinchThreshold | Magnify Events, kein Scroll |
| Two-finger lift | Scroll starten, einen Finger heben | Scroll endet, verbleibender Finger klickt nicht |
| Cancel | Button down, Touch Cancelled oder Device Disconnect | Button wird freigegeben |
| Multi-source | Zwei HID sources parallel | State bleibt pro source getrennt |

Wenn kein Testtarget angelegt wird, im Code zumindest temporaere `NSLog`-Debugausgaben hinter `#if DEBUG` einbauen, z.B. fuer State-Wechsel:

```objc
#if DEBUG
NSLog(@"[TouchUp] Gesture state %@ -> %@ source=%ld", oldName, newName, (long)sourceState.sourceIdentifier);
#endif
```

Vor Finalisierung sollten diese Logs entweder nuetzlich und knapp bleiben oder entfernt werden.

### Schritt 10: Build- und QA-Ablauf

Nach jeder groesseren Etappe:

```sh
git diff --check
xcodebuild -project 'Touch Up.xcodeproj' -scheme 'Touch Up' -configuration Debug -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO build
```

Bekannte Xcode-Nebenwarnungen im Sandbox-Kontext:

- CoreSimulatorService kann Warnungen ausgeben.
- Das ist fuer macOS-Build nicht automatisch ein Fehler.
- Relevant ist am Ende `** BUILD SUCCEEDED **`.

Manuelle QA mit echtem Touchscreen:

1. App starten, Touchscreen zuordnen.
2. Debug Overlay oeffnen, pruefen ob Touchpunkte stabil und in korrekter Screen-Koordinate liegen.
3. In Finder oder TextEdit testen:
   - Tap selektiert/klickt.
   - One-Finger-Drag bewegt Cursor, scrollt nicht.
   - Drag auf Fenster-Titelleiste verschiebt das Fenster.
   - Drag im Fensterinhalt verschiebt das Fenster nicht.
   - Press-and-Hold oeffnet Kontextmenue oder haelt rechten Button bis Lift.
   - Two-Finger-Drag scrollt in erwarteter Richtung.
   - Pinch zoomt dort, wo macOS/Applikation Magnify annimmt.
4. In Safari oder einem scrollbaren Dokument:
   - Kurze und lange Zwei-Finger-Scrolls pruefen.
   - Einen Finger waehrend Scroll heben: kein anschliessender Tap.
5. Fehlerfall:
   - Finger halten und App deaktivieren/Touchscreen abziehen. Kein haengender Mausbutton.

### Schritt 11: Dokumentation und Abschluss

Am Ende:

1. `README.md` final mit tatsaechlichen Defaults abgleichen.
2. Falls Legacy-Settings entfernt wurden, keine alten UI-Texte uebrig lassen.
3. `git status --short` pruefen.
4. Final zusammenfassen:
   - Welche Altlasten entfernt wurden.
   - Welche Gesten implementiert sind.
   - Build-Ergebnis.
   - Ob echte Hardware-QA erfolgt ist oder noch offen ist.

## Empfohlene Patch-Reihenfolge

1. CursorUtilities bereinigen und Build herstellen.
2. TUCTouchInputManager State-Felder und Helper hinzufuegen, alte Logik noch nicht entfernen.
3. Neue State-Machine parallel implementieren und in `processTouchesForCursorInputForSourceState:` aktivieren.
4. Alte Gesture-Mapping-Methode `performMouseEventForGesture:` und `actionForGesture:` aus dem Runtime-Pfad entfernen.
5. Swift-Settings vereinfachen und Defaults migrieren.
6. Ungenutzte Dateien `Touch.h` und `Touch.m` entfernen.
7. README finalisieren.
8. Build, `git diff --check`, manuelle QA.

## Abnahmekriterien

Die Umsetzung gilt erst als fertig, wenn alle Punkte erfuellt sind:

- `git diff --check` ist sauber.
- `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` ist erfolgreich.
- Es gibt keine haengenden Left- oder Right-Mouse-Down-Zustaende nach Cancel/Disconnect.
- One-Finger-Drag erzeugt keine Scroll-Events.
- One-Finger-Drag auf einer erkannten Titelleiste kann Fenster verschieben und gibt Left Mouse Up immer frei.
- One-Finger-Drag im Fensterinhalt startet keinen Window-Move.
- Two-Finger-Drag erzeugt Scroll-Events ohne vorherigen Left/Right Click.
- Press-and-Hold erzeugt genau einen Rechtsklick-Zyklus und keinen Left Click.
- Pinch und Two-Finger-Scroll sind durch Schwellwerte getrennt, nicht nur durch Richtungsvergleich.
- App-Settings und README beschreiben dasselbe Verhalten, das der Core tatsaechlich ausfuehrt.
