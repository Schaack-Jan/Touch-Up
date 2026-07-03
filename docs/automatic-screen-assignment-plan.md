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
- Nutzer koennen ein manuelles Mapping starten: Touch Up zeigt nacheinander jeden externen Monitor fullscreen und bindet die jeweils beruehrte HID-Quelle an diesen Monitor.
- Debug- oder Diagnoseansichten duerfen die automatische Zuordnung anzeigen, aber nicht als normale Nutzerentscheidung verlangen.

### Funktionsanforderungen

- Die automatische Zuordnung ist pro HID-Touchdevice, nicht global.
- Jede Touchquelle erhaelt eine Zuordnung pro HID-Geraet; `sourceIdentifier` gilt nur fuer die laufende Sitzung, eine gelernte Calibration-Zuordnung wird zusaetzlich ueber eine stabile Geraetekennung gespeichert.
- Eine bestehende gueltige Zuordnung wird beibehalten, solange der Display weiterhin existiert.
- Wird ein Display entfernt oder aendert sich die Display-Topologie, werden Zuordnungen neu validiert.
- Aendert sich die Zuordnung eines aktiven Touchdevices, werden aktive Touches und Gesten dieser Quelle abgebrochen.
- Mouse Events werden immer mit dem Screen berechnet, der am jeweiligen `TUCTouch.screen` haengt.
- Calibration bleibt monitor-spezifisch und verwendet weiterhin `TUCScreen.calibrationKey`.
- Das Calibration-Overlay darf keine globale Touchscreen-Zuweisung mehr setzen.
- Manuelles Mapping darf bestehende automatische oder gelernte Zuordnungen ueberschreiben.
- Monitor- oder Hersteller-spezifische Sonderfaelle sollen nicht im Resolver kodiert werden.

### Zuordnungsstrategie

Prioritaet der Zuordnung:

1. Gelerntes Signal aus Manual-Mapping oder Calibration-Overlay: aktive Touchquelle wird dem gewaehlten Screen zugeordnet; bei Reconnects wird diese Zuordnung ueber stabile HID-Geraetemerkmale wiederverwendet.
2. Bestehende `assignedDisplayID`, falls der Display weiterhin verbunden ist.
3. Eindeutiger Match zwischen HID-Geraetename und Displayname.
4. Anschlussreihenfolge: neu erkannte externe Displays und neu erkannte USB-Touchdevices werden innerhalb eines Zeitfensters paarweise verbunden.
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

### Phase 5: Manuelles Mapping

- In den Settings einen Button "Map Touchscreens" ergaenzen.
- Beim Start des Mapping-Flows normale Mouse-Event-Ausgabe temporaer deaktivieren.
- Vor dem Mapping alte gelernte/automatische Zuordnungen zuruecksetzen.
- Externe Monitore nacheinander fullscreen anzeigen.
- Beim ersten aktiven Touch auf dem angezeigten Monitor `sourceIdentifier -> displayID` lernen und persistieren.
- Bereits im Mapping verwendete Touchquellen fuer die folgenden Schritte ignorieren.
- Nach Abschluss Mouse-Event-Ausgabe wiederherstellen und Assignments refreshen.

### Phase 6: Migration und Aufraeumen

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
- Gelerntes Manual-/Calibration-Signal gewinnt gegen bestehende falsche Assignments.
- Controller- und Displaynamen ohne echte Uebereinstimmung erzeugen keine Hersteller-Alias-Zuordnung.

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
- Settings enthalten einen Mapping-Button, der den Fullscreen-Mapping-Flow startet.

### Manuelle QA

- Ein externer Touchscreen an einem MacBook.
- Zwei externe Touchscreens gleichzeitig.
- Touchscreen nach App-Start einstecken.
- Display-Kabel und USB-Kabel in unterschiedlicher Reihenfolge verbinden.
- Fuer automatische Erkennung: Touch Up starten, hoechstens einen externen Touchmonitor verbunden lassen, danach weitere Display-/USB-Paare nacheinander verbinden.
- Mapping-Button starten, nacheinander jeden externen Touchmonitor beruehren und pruefen, dass danach jeder Monitor korrekt reagiert.
- Display waehrend aktiver Beruehrung abziehen.
- Drag starten und dann Display-Topologie aendern, keine haengenden Maustasten.
- Calibration auf Screen A ausfuehren, danach pruefen, dass Touches auf Screen A landen.
- Calibration auf Screen B ausfuehren, danach pruefen, dass Screen A unveraendert bleibt.

## Akzeptanzkriterien

- Der Nutzer sieht keine Auswahl fuer den Ziel-Screen der Mouse Events.
- Mouse Events landen im Normalfall auf dem physisch passenden Touchscreen.
- Multi-Touchscreen-Setups funktionieren pro HID-Geraet.
- Bei uneindeutigen Setups kann der Nutzer die Zuordnung ueber den Mapping-Button manuell herstellen.
- Kein globaler Screen-Override bleibt im normalen Eventpfad uebrig.
- Calibration bleibt pro Monitor erhalten.
- Die App verhaelt sich bei unklarer Zuordnung deterministisch und bricht aktive Gesten bei Zuordnungswechseln sauber ab.
- Unit-Tests decken Resolver und Touch-Pipeline ab.
- Bestehende Nutzer verlieren keine Calibration-Daten.

## Fortschrittstracking

| Schritt | Status | Notizen |
| --- | --- | --- |
| Feature-Spec dokumentieren | Erledigt | Dieses Dokument beschreibt Zielverhalten, Anforderungen und Akzeptanzkriterien. |
| Test-Target fuer Core anlegen | Erledigt | `TouchUpCoreTests` ist im Xcode-Projekt und in der `TouchUpCore`-Scheme verdrahtet. |
| Resolver-API entwerfen | Erledigt | `TUCTouchDisplayAssignmentResolver` nutzt reine Touchdevice-/Screen-Descriptoren plus optionale Hotplug- und Calibration-Signale. |
| Resolver implementieren | Erledigt | Zuordnungsstrategie mit `reason` und `confidence`, inklusive stabiler Fallbacks. |
| Resolver-Unit-Tests schreiben | Erledigt | Namensmatch, ambige Matches, Hotplug, Calibration-Learning, Single-Screen und Fallbacks sind abgedeckt. |
| Core-Pipeline auf Resolver umstellen | Erledigt | `screenForTouchDevice(_:)` delegiert an den Resolver und wendet dessen Ergebnis an. |
| Assignment-Wechsel absichern | Erledigt | Display-Wechsel canceln Touches/Gesten pro `sourceIdentifier` ueber `cancelTouchesForSourceIdentifier(_:)`. |
| Public Manual-Assignment-API entfernen | Erledigt | `assignAllTouchDevicesToDisplayID(_:)` ist nicht mehr Public API; App-Code nutzt keinen globalen Override mehr. |
| App-Modell bereinigen | Erledigt | `connectedTouchscreen`, Cue-Defaults und Hotplug-Auswahl im Swift-Modell sind entfernt. |
| Settings-Picker entfernen | Erledigt | Top-Section enthaelt nur noch den Mouse-Control-Toggle. |
| Calibration-Overlay entkoppeln | Erledigt | Overlay startet ohne globale Zuweisung und meldet aktive Touchquellen als gelerntes Signal an den Core. |
| Calibration-Learning gegen Reconnects absichern | Erledigt | Gelernte Zuordnungen werden zusaetzlich per stabiler HID-Kennung in `UserDefaults` persistiert; doppelte identische Kennungen werden nicht automatisch uebernommen. |
| Monitor-spezifische Sonderlogik entfernen | Erledigt | Hersteller-/Monitor-Aliasregeln sind entfernt; der Resolver nutzt nur generische Signale. |
| Anschlussreihenfolge als Auto-Mapping nutzen | Erledigt | Core paart neu erkannte externe Displays und USB-Touchdevices innerhalb eines Zeitfensters in Reihenfolge. |
| Manuellen Mapping-Button einbauen | Erledigt | Settings starten einen Fullscreen-Assistenten, der jeden externen Monitor nacheinander per Touchquelle bindet. |
| Diagnose/Logging ergaenzen | Erledigt | Core loggt `sourceIdentifier`, HID-Name, Display, Reason und Confidence. |
| README aktualisieren | Erledigt | Automatische per-Device-Zuordnung ist dokumentiert. |
| App-/UI-Tests schreiben | Teilweise | App-Build und statische Suche verifizieren keinen Picker/Override; ein dediziertes UI-Testtarget wurde nicht angelegt. |
| Manuelle QA durchfuehren | Offen | Hardware-Szenarien mit einem oder mehreren Touchscreens muessen auf echten Geraeten geprueft werden. |
