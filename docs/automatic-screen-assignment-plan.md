# Automatische Screen-Zuordnung fuer Mouse Events

## Ziel

Die manuelle Auswahl, auf welchem Screen Touch Up Mouse Events ausfuehrt, entfaellt. Stattdessen ordnet Touch Up jedes erkannte Touch-HID-Geraet automatisch einem `TUCScreen` zu und verwendet diese Zuordnung fuer alle daraus entstehenden Cursor-, Klick-, Drag-, Scroll- und Calibration-Events.

## Ausgangslage

- In `SettingsView.top` gibt es aktuell den Picker "Assign Mouse Events to".
- `TouchUp` speichert dafuer `connectedTouchscreen` und ruft `assignTouchscreen(_:)` auf.
- `assignTouchscreen(_:)` setzt alle Touchdevices per `assignAllTouchDevicesToDisplayID(_:)` auf denselben Screen.
- Im Core existiert bereits eine automatische Zuordnung in `screenForTouchDevice(_:)`.
- Die Core-Zuordnung wird aber noch durch App-Zustand, gespeicherte Cues und manuelle Auswahl uebersteuert.

## Feature-Spec

### Nutzerverhalten

- Nutzer muessen keinen Ziel-Screen mehr auswaehlen.
- Die Settings zeigen keinen Picker fuer "Assign Mouse Events to" mehr.
- Touches auf einem Touchscreen steuern automatisch den dazugehoerigen Screen.
- Wenn mehrere Touchscreens angeschlossen sind, wird jedes HID-Touchdevice separat einem Display zugeordnet.
- Wenn die Zuordnung nicht eindeutig ist, bleibt die App benutzbar und waehlt einen deterministischen Fallback.
- Debug- oder Diagnoseansichten duerfen die automatische Zuordnung anzeigen, aber nicht als normale Nutzerentscheidung verlangen.

### Funktionsanforderungen

- Die automatische Zuordnung ist pro HID-Touchdevice, nicht global.
- Jede Touchquelle erhaelt eine stabile `sourceIdentifier`-basierte Zuordnung.
- Eine bestehende gueltige Zuordnung wird beibehalten, solange der Display weiterhin existiert.
- Wird ein Display entfernt oder aendert sich die Display-Topologie, werden Zuordnungen neu validiert.
- Aendert sich die Zuordnung eines aktiven Touchdevices, werden aktive Touches und Gesten dieser Quelle abgebrochen.
- Mouse Events werden immer mit dem Screen berechnet, der am jeweiligen `TUCTouch.screen` haengt.
- Calibration bleibt monitor-spezifisch und verwendet weiterhin `TUCScreen.calibrationKey`.
- Das Calibration-Overlay darf keine globale Touchscreen-Zuweisung mehr setzen.

### Zuordnungsstrategie

Prioritaet der automatischen Zuordnung:

1. Bestehende `assignedDisplayID`, falls der Display weiterhin verbunden ist.
2. Eindeutiger Match zwischen HID-Geraetename und Displayname.
3. Hotplug-Korrelation: USB-Touchdevice und neuer Display erscheinen innerhalb eines kurzen Zeitfensters.
4. Gelerntes Signal aus Calibration-Overlay: aktive Touchquelle wird dem kalibrierten Screen zugeordnet.
5. Single-device/single-screen-Fall.
6. Noch nicht belegter Screen, wenn mehrere Touchdevices vorhanden sind.
7. Deterministischer Fallback auf den ersten verfuegbaren Screen.

Jede Entscheidung soll intern einen Grund und eine Confidence erhalten, zum Beispiel:

- `existingAssignment`, hoch
- `nameMatch`, hoch bis mittel
- `hotPlug`, mittel
- `calibrationLearned`, hoch
- `singleScreen`, hoch
- `nextUnassigned`, niedrig bis mittel
- `fallback`, niedrig

## Implementierungsplan

### Phase 1: Core als Quelle der Wahrheit

- Einen kleinen Resolver einfuehren, z. B. `TUCTouchDisplayAssignmentResolver`.
- Resolver mit reinen Eingaben testenbar halten:
  - Touchdevice-Descriptor: `sourceIdentifier`, `registryID`, `vendorID`, `productID`, `name`, vorherige `assignedDisplayID`.
  - Screen-Descriptor: `id`, `name`, `calibrationKey`, `frame`, `physicalSize`.
  - Optionale Signale: Hotplug-Zeitpunkt, gelernte Calibration-Zuordnung.
- `screenForTouchDevice(_:)` so umbauen, dass es nur noch Resolver-Ergebnisse anwendet.
- Bei Assignment-Wechsel `cancelTouchesForSourceIdentifier(_:)` fuer die betroffene Quelle ausfuehren.
- Logging fuer `sourceIdentifier`, HID-Name, Screenname, Grund und Confidence ergaenzen.

### Phase 2: Manuelle Zuweisung entfernen

- `assignAllTouchDevicesToDisplayID(_:)` aus der Public API entfernen oder als intern/deprecated markieren.
- `TouchUp.assignTouchscreen(_:)` entfernen.
- `connectedTouchscreen` entfernen oder zu read-only Diagnosezustand ersetzen.
- `identificationCues`, `rememeberCues`, `identifyPreferredOrNoScreen` und `identifyHotPlug` aus dem App-Modell entfernen, sofern sie nur der manuellen/globalen Zuweisung dienen.
- `screenParametersDidChange()` auf folgende Aufgaben reduzieren:
  - `connectedScreens` aktualisieren.
  - Core-Assignments refreshen lassen.
  - Calibration-Sync ausfuehren.

### Phase 3: UI anpassen

- Picker "Assign Mouse Events to" aus `SettingsView.top` entfernen.
- Label-Case fuer `connectedTouchscreen` in `uiLabels(for:)` entfernen.
- Optional eine read-only Diagnosezeile ergaenzen:
  - "Automatic screen assignment active"
  - oder in Debug UI: "Touch Device -> Display".
- `SettingsWindow.makeVisible()` darf nicht mehr von `connectedTouchscreen` abhaengen.

### Phase 4: Calibration-Flow anpassen

- `AppDelegate.showCalibrationOverlay(for:)` darf nicht mehr `model.assignTouchscreen(screen)` aufrufen.
- Das Overlay sammelt wie bisher Samples fuer den ausgewaehlten Monitor.
- Wenn waehrend der Calibration ein aktiver Touch mit `sourceIdentifier` erkannt wird, kann diese Zuordnung als gelerntes Signal an den Core gemeldet werden.
- `CalibrationAssistantView.activeTouch()` soll weiterhin bevorzugt Touches verwenden, deren `touch.screen.calibrationKey` zum Overlay-Screen passt.
- Fallback auf `activeTouches.first` bleibt nur fuer Diagnose/Recovery, nicht als globale Screen-Zuweisung.

### Phase 5: Migration und Aufraeumen

- Alte Defaults `touchscreenNameCue` und `touchscreenIDCue` nicht mehr lesen.
- Keine harte Migration notwendig, wenn die Keys einfach ignoriert werden.
- README und relevante Dokumentation aktualisieren:
  - kein manueller Screen-Picker mehr,
  - automatische Zuordnung,
  - Debug-Hinweis fuer Spezialfaelle.

## Testplan

### Neue Teststruktur

Aktuell gibt es kein dediziertes Test-Target. Zuerst soll ein `TouchUpCoreTests`-Target angelegt werden, damit die automatische Zuordnung ohne echte HID-Hardware getestet werden kann.

### Unit-Tests fuer Resolver

- Bestehende gueltige Display-ID wird wiederverwendet.
- Stale Display-ID wird verworfen, wenn der Screen entfernt wurde.
- Exakter HID-/Display-Namensmatch waehlt den passenden Screen.
- Substring- und Token-Namensmatches funktionieren robust.
- Ambige Namensmatches fuehren nicht zu instabilen Wechseln.
- Ein Touchdevice und ein Screen fuehren zu `singleScreen`.
- Zwei Touchdevices mit eindeutigen Namen werden zwei verschiedenen Screens zugeordnet.
- Mehrere Touchdevices ohne eindeutige Namen bekommen deterministische, moeglichst eindeutige Fallbacks.
- Bereits belegte Displays werden bei `nextUnassigned` vermieden.
- Hotplug-Signal gewinnt gegen unsichere Fallbacks.
- Gelerntes Calibration-Signal gewinnt gegen unsichere Fallbacks.

### Unit-Tests fuer Touch-Pipeline

- `processHIDValuesForTouchDevice` setzt `TUCTouch.screen` auf den automatisch zugeordneten Screen.
- `absoluteLocationForTouch(_:)` verwendet `touch.screen`.
- Rotation wird weiterhin vor Calibration angewendet.
- Calibration wird fuer den automatisch zugeordneten Screen angewendet.
- Assignment-Wechsel cancelt nur Touches derselben `sourceIdentifier`.
- Assignment-Wechsel beendet aktive Button-/Drag-Zustaende.

### Swift/App-Tests

- Settings enthalten keinen Text "Assign Mouse Events to".
- Settings enthalten keinen Picker, der `connectedTouchscreen` setzt.
- `screenParametersDidChange()` aktualisiert Screens und triggert Assignment-Refresh, aber keine globale Zuweisung.
- `showCalibrationOverlay(for:)` setzt keinen globalen Touchscreen.
- Alte UserDefaults fuer `touchscreenNameCue` und `touchscreenIDCue` veraendern das Verhalten nicht.

### Manuelle QA

- Ein externer Touchscreen an einem MacBook.
- Zwei externe Touchscreens gleichzeitig.
- Touchscreen nach App-Start einstecken.
- Display-Kabel und USB-Kabel in unterschiedlicher Reihenfolge verbinden.
- Display waehrend aktiver Beruehrung abziehen.
- Drag starten und dann Display-Topologie aendern, keine haengenden Maustasten.
- Calibration auf Screen A ausfuehren, danach pruefen, dass Touches auf Screen A landen.
- Calibration auf Screen B ausfuehren, danach pruefen, dass Screen A unveraendert bleibt.

## Akzeptanzkriterien

- Der Nutzer sieht keine Auswahl fuer den Ziel-Screen der Mouse Events.
- Mouse Events landen im Normalfall auf dem physisch passenden Touchscreen.
- Multi-Touchscreen-Setups funktionieren pro HID-Geraet.
- Kein globaler Screen-Override bleibt im normalen Eventpfad uebrig.
- Calibration bleibt pro Monitor erhalten.
- Die App verhaelt sich bei unklarer Zuordnung deterministisch und bricht aktive Gesten bei Zuordnungswechseln sauber ab.
- Unit-Tests decken Resolver und Touch-Pipeline ab.
- Bestehende Nutzer verlieren keine Calibration-Daten.

## Fortschrittstracking

| Schritt | Status | Notizen |
| --- | --- | --- |
| Feature-Spec dokumentieren | Erledigt | Dieses Dokument beschreibt Zielverhalten, Anforderungen und Akzeptanzkriterien. |
| Test-Target fuer Core anlegen | Offen | `TouchUpCoreTests` im Xcode-Projekt ergaenzen. |
| Resolver-API entwerfen | Offen | Reine Descriptor-Eingaben, testbar ohne HID-Hardware. |
| Resolver implementieren | Offen | Zuordnungsstrategie mit Reason und Confidence. |
| Resolver-Unit-Tests schreiben | Offen | Namensmatch, Hotplug, Calibration-Learning, Fallbacks. |
| Core-Pipeline auf Resolver umstellen | Offen | `screenForTouchDevice(_:)` delegiert an Resolver. |
| Assignment-Wechsel absichern | Offen | Touches/Gesten pro `sourceIdentifier` canceln. |
| Public Manual-Assignment-API entfernen | Offen | `assignAllTouchDevicesToDisplayID(_:)` abbauen oder intern machen. |
| App-Modell bereinigen | Offen | `connectedTouchscreen` und Cue-Logik entfernen oder diagnostisch ersetzen. |
| Settings-Picker entfernen | Offen | Top-Section behaelt nur noch Mouse-Control-Toggle. |
| Calibration-Overlay entkoppeln | Offen | Keine globale Zuweisung beim Start der Calibration. |
| Diagnose/Logging ergaenzen | Offen | Assignment-Grund und Confidence sichtbar machen. |
| README aktualisieren | Offen | Automatische Zuordnung dokumentieren. |
| App-/UI-Tests schreiben | Offen | Kein Picker, kein globaler Override. |
| Manuelle QA durchfuehren | Offen | Ein- und Multi-Touchscreen-Szenarien pruefen. |
