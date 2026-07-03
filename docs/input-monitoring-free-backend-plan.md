# Input-Monitoring-freies Touch-Backend nach UPDD-Vorbild

Stand: 2026-07-03

Dieser Plan beschreibt, wie Touch Up ein UPDD-aehnliches Backend bekommen kann, ohne im normalen Eingabepfad `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` und damit macOS Input Monitoring zu benoetigen. Ziel ist kein neues Monitor-spezifisches System, sondern ein generischer Eingabepfad fuer alle passenden Touch-/Digitizer-Geraete.

## Ziel

Touch Up soll sich fuer Nutzer wie bisher verhalten, aber die HID-Eingabe ueber ein neues Backend erhalten:

- Aktuelle Parameter bleiben erhalten:
  - `postMouseEvents`
  - `holdDuration`
  - `doubleClickTolerance`
  - `errorResistance`
  - `ignoreOriginTouches`
  - `windowTitleBarDragEnabled`
  - `twoFingerTapSecondaryClickEnabled`
  - `twoFingerScrollEnabled`
  - `calibrationsByMonitorKey`
- Mehrere Touchmonitore werden weiterhin unterstuetzt.
- Automatische Erkennung und Zuordnung bleiben generisch.
- Manuelles Touch Mapping bleibt erhalten.
- Kalibrierung bleibt pro Display erhalten.
- Gesten bleiben im Verhalten gleich.
- Der neue Treiber enthaelt keine Monitor-, Display-, Hersteller- oder Modell-spezifische Logik.
- Das System funktioniert generisch mit allen kompatiblen Touch-/Digitizer-Geraeten, soweit deren HID-Deskriptoren auswertbar sind.

## UPDD-Befund

UPDD kommt nicht dadurch ohne Input Monitoring aus, dass es weniger privilegiert arbeitet. Es verschiebt den Hardwarezugriff aus dem normalen App-IOHID-Pfad heraus.

### Architekturprinzipien

- UPDD nutzt unter aktuellen macOS-Versionen eine System Extension/DriverKit-Komponente, die fuer den Zugriff auf USB-Geraete vom Nutzer erlaubt werden muss. Touch-Base beschreibt diese Erweiterungen als Komponenten, die unter macOS 10.15 und neuer verwendet werden, um die von UPDD unterstuetzten USB-Geraete zu definieren und anderen Treibern den Zugriff zu entziehen.
- UPDD V7 nutzt auf macOS eine eigene USB-Schnittstelle ueber IOKit. V6 hatte zuvor fuer USB plattformuebergreifend libUSB genutzt; V7 ersetzt das auf macOS durch eigene IOKit-Anbindung.
- Der UPDD-Treiber ist ein eigener Server. Die API-Kommunikation zwischen Treiber und Clients laeuft laut Dokumentation ueber TCP/IP, standardmaessig Port 4146. Mehrere Clients koennen gleichzeitig verbunden sein.
- UPDD-Clients wie Commander, Calibrate, Daemon, Gestures und Test nutzen diese API. Der Treiber muss dadurch nicht direkt jede UI-Funktion besitzen.
- UPDD Commander erhaelt Touchdaten ueber die Treiber-API, erkennt Gesten und postet Touch-/Gesture-/TUIO-/OS-Events. Unter macOS benoetigt Commander fuer das Steuern des Systems Accessibility, nicht Input Monitoring.
- Multi-Monitor-Logik liegt bei UPDD nicht als harte Monitorliste im USB-Treiber. UPDD ermittelt bzw. speichert Monitor-Metriken separat, bietet Configure/Identify, Display-Binding und Port/Device-Binding an, und ordnet Geraete auf dieser Ebene zu.

### Schlussfolgerung fuer Touch Up

Input Monitoring entsteht heute, weil Touch Up als normale App `IOHIDDeviceOpen`, `IOHIDDeviceRegisterInputValueCallback`, `IOHIDDeviceRegisterInputReportCallback` und `IOHIDDeviceGetValue` auf IOHID-Geraeten nutzt. macOS fasst diesen Low-Level-HID-Zugriff unter "Input Monitoring" zusammen.

Ein UPDD-aehnlicher Ansatz ersetzt diesen Pfad durch:

1. Eine System Extension bzw. DriverKit-Komponente, die generisch geeignete USB-HID-Interfaces besitzt oder an sie gebunden wird.
2. Einen lokalen Backend-Service, der die rohen HID-Reports auswertet und als Touchframes bereitstellt.
3. Eine stabile lokale API zwischen Backend-Service und TouchUpCore.
4. Die bestehende Touch-Up-Pipeline fuer Display-Zuordnung, Kalibrierung, Gesten und CGEvent-Ausgabe.

Wichtig: Accessibility bleibt weiterhin noetig, solange Touch Up Maus-, Scroll- und Gesture-Events per CoreGraphics/Accessibility in macOS postet. Der Plan entfernt Input Monitoring aus dem Eingabepfad, nicht jede macOS-Sicherheitsabfrage.

## Aktueller Touch-Up-Befund

### Heute problematischer Eingabepfad

- `TouchUpCore/TUCTouchInputManager.m` sucht alle `IOHIDDevice`-Services, filtert auf USB und touch-aehnliche Deskriptoren, oeffnet das IOHIDDevice und registriert Value-/Report-Callbacks.
- `checkHIDListenEventAccessGranted` und `requestHIDListenEventAccess` pruefen bzw. beantragen `kIOHIDRequestTypeListenEvent`.
- `Touch Up/TouchUp.swift` und `Touch Up/SettingsView.swift` zeigen daraus die Input-Monitoring-Prompts.
- README dokumentiert Input Monitoring als Pflicht fuer den aktuellen HID-Report-Zugriff.

### Bereits wiederverwendbare Teile

Diese Teile muessen nicht neu erfunden werden:

- `TUCTouchInputManager` verwaltet Touch-Set, Phasen, `sourceIdentifier`, Gesten-State und Event-Ausgabe.
- `TUCTouchDisplayAssignmentResolver` ist bereits generisch:
  - gelernte Zuweisung
  - bestehende Zuweisung
  - Name-Match
  - Hotplug-Korrelation
  - Single-Screen
  - naechster freier Screen
  - deterministischer Fallback
- `TUCScreen` kapselt Display-IDs, Namen, Frames, Rotation und Kalibrierungskeys.
- `TouchCalibrationStore` speichert Kalibrierung pro `screen.calibrationKey`.
- Manuelles Mapping lernt bereits `sourceIdentifier -> displayID`.
- Gesten arbeiten auf normalisierten Touchpunkten und `TUCTouch.screen`, nicht direkt auf IOHID.

## Zielarchitektur

### Schichten

```text
USB Touch/Digitizer Hardware
        |
        v
TouchUp Driver/System Extension
  - besitzt/liest passende USB-HID-Interfaces
  - parst keine Monitor-Informationen
  - kennt keine Displays
  - liefert nur Geraete + Touchframes
        |
        v
TouchUp Backend Service
  - HID-Report-Parser
  - Device-Lifecycle
  - stabile Device-Keys
  - XPC/API zu TouchUpCore
        |
        v
TouchUpCore
  - TUCTouchInputBackend-Protokoll
  - Touch-Set
  - DisplayAssignmentResolver
  - Kalibrierung
  - Gesten
        |
        v
Touch Up App
  - Settings
  - Mapping Assistant
  - Calibration Assistant
  - Debug/QA
```

### Harte Grenze fuer den Treiber

Der Treiber darf:

- USB-Interfaces erkennen und oeffnen.
- HID-Report-Deskriptoren und Input-Reports bereitstellen oder bereits normalisierte Kontaktframes liefern.
- Geraete-Metadaten melden:
  - Vendor ID
  - Product ID
  - optional Serial
  - USB-Location/Port-Pfad
  - Interface/Endpoint
  - Produkt-/Manufacturer-Name, falls vorhanden
  - maximale Kontaktanzahl, falls ableitbar
- Kontaktframes liefern:
  - Device Key
  - Contact ID
  - normalisiertes X/Y in Geraetekoordinaten
  - On-Surface/Tip-State
  - Valid/Confidence
  - Report-Zeitstempel

Der Treiber darf nicht:

- `NSScreen`, `CGDirectDisplayID`, `TUCScreen` oder Display-Frames kennen.
- Displaynamen matchen.
- Kalibrierung anwenden.
- Monitor-Metriken speichern.
- Geraete auf Monitore abbilden.
- Hersteller- oder Monitor-spezifische Sonderfaelle enthalten.
- Eingebaute Listen wie "Iiyama", "3M", "Dell" oder andere Produktnamen benutzen.

### API im Core

Neue interne Core-Schnittstelle:

```objc
@protocol TUCTouchInputBackend <NSObject>
- (void)start;
- (void)stop;
- (NSArray<TUCTouchBackendDevice *> *)connectedDevices;
@property (weak, nonatomic) id<TUCTouchInputBackendDelegate> delegate;
@end
```

Backend-Events:

- `deviceDidConnect(TUCTouchBackendDevice *)`
- `deviceDidDisconnect(stableDeviceKey)`
- `didReceiveTouchFrame(TUCTouchBackendFrame *)`
- `backendAccessStateDidChange(...)`

Das bestehende IOHID-Backend wird zuerst als Adapter hinter dieses Protokoll gelegt. Danach kann das DriverKit/XPC-Backend denselben Contract implementieren.

## Implementierungsplan

### Phase 1: Backend-Abstraktion ohne Verhaltensaenderung

Ziel: Die aktuelle App funktioniert unveraendert, aber IOHID ist nicht mehr direkt in der Hauptlogik von `TUCTouchInputManager` verankert.

- `TUCTouchInputBackend` und `TUCTouchInputBackendDelegate` einfuehren.
- Datenmodelle einfuehren:
  - `TUCTouchBackendDevice`
  - `TUCTouchBackendContact`
  - `TUCTouchBackendFrame`
  - `TUCTouchBackendAccessState`
- Bestehende IOHID-Logik aus `TUCTouchInputManager.m` in `TUCIOHIDTouchInputBackend` verschieben.
- `TUCTouchInputManager` verarbeitet nur noch generische Backend-Frames und ruft weiter `updateTouch:withLocation:onSurface:tooLargeForFinger:screen:sourceIdentifier:`.
- Bestehende Public Properties und Swift Bindings unveraendert lassen.
- Fake-Backend fuer Tests bauen.
- Unit-Tests fuer "Backend Frame -> Touch Set -> Gesture Pipeline" ergaenzen.

### Phase 2: DriverKit/System-Extension Machbarkeitsnachweis

Ziel: Ein einzelnes generisches Touch-HID-Interface liefert Reports ohne Input Monitoring.

- Neues Target `TouchUpDriverExtension` oder vergleichbarer Name anlegen.
- Benoetigte Apple-Entitlements und Provisioning klaeren:
  - DriverKit/System Extension
  - USBDriverKit bzw. passende HID/USB-Komponente
  - notarization-faehige Signierung
- Generische Matching-Strategie pruefen:
  - HID-Interfaces mit Boot-Keyboard und Boot-Mouse explizit ausschliessen.
  - Report-Deskriptor frueh pruefen.
  - Nicht-Touch-Geraete sofort ablehnen oder durchreichen.
- Erfolgskriterium:
  - Ein kompatibler Touchscreen streamt Input-Reports ohne Input-Monitoring-Prompt.
  - Normale Tastaturen, Maeuse und nicht-touch HID-Geraete werden nicht uebernommen.
  - System Extension Approval ist dokumentiert und reproduzierbar.
- Abbruchkriterium:
  - Wenn macOS nur zu breite HID-Matches erlaubt, die Nicht-Touch-HID-Geraete zeitweise abfangen, muss die Matching-Strategie neu bewertet werden, bevor Code in den Hauptpfad wandert.

### Phase 3: Generischer HID-Report-Parser

Ziel: Der Parser verarbeitet Windows-kompatible HID-Touchscreens ohne Geraete- oder Monitor-Sonderfaelle.

- HID-Report-Descriptor-Parser bauen oder eine etablierte kleine Parser-Komponente einbinden.
- Unterstuetzte generische Usages:
  - Digitizer Touch Screen
  - Finger
  - Tip Switch / Touch
  - Contact Identifier
  - Contact Count
  - X/Y absolute axes
  - Touch Valid / Data Valid
  - Confidence, falls vorhanden
  - optional Width/Height/Pressure als spaetere Erweiterung
- Modi abdecken:
  - Parallel Mode
  - Hybrid Mode
  - Single-Touch absolute pointer fallback, falls der Deskriptor das generisch hergibt
- Keine VID/PID-Branches in den Parser aufnehmen.
- Bestehenden SIS-Raw-Report-Fallback nicht in den neuen Treiber uebernehmen. Falls solche Geraete weiterhin wichtig sind, nur als spaetere, datengetriebene Kompatibilitaetsdatei ausserhalb des Treibers und mit Tests diskutieren.
- Descriptor-Fixtures anlegen und parserseitig testen:
  - Standard multitouch
  - single-touch absolute
  - mehrere Collections
  - hybrid reports
  - fehlende Contact IDs
  - invalid/lift reports

### Phase 4: Backend-Service/API

Ziel: App und Core sprechen nicht direkt mit der System Extension, sondern mit einem stabilen lokalen Service.

- `TouchUpBackendService` als LaunchAgent oder in der App eingebetteter XPC-Service entwerfen.
- API versionieren.
- XPC statt TCP verwenden, ausser es gibt einen starken Grund fuer TCP. UPDD nutzt TCP fuer Cross-Platform-Portabilitaet; Touch Up kann lokal enger und sicherer bleiben.
- Funktionen:
  - `listDevices`
  - `subscribeToTouchFrames`
  - `activateDriverExtension`
  - `driverStatus`
  - `diagnosticsSnapshot`
- Device-Key generisch bilden:
  - bevorzugt USB Serial
  - sonst VID/PID plus USB-Location/Port-Pfad plus Interface
  - fallback laufende Session-ID, dann aber nicht persistent lernen
- Backpressure und Event-Reihenfolge definieren:
  - Frames pro Device monoton nummerieren.
  - Disconnect cancelt aktive Kontakte dieses Device.
  - Service startet keine Display-Zuordnung.

### Phase 5: Integration in TouchUpCore

Ziel: Das neue Backend wird Standard, die alte IOHID-Logik bleibt hoechstens als Debug-/Fallback-Pfad.

- `TUCTouchInputManager.start` startet das konfigurierte Backend.
- `TUCTouchInputManager.stop` stoppt Backend und cancelt aktive Gesten/Touches.
- `TUCUSBHIDTouchDevice` durch backend-neutrales Device-State-Modell ersetzen.
- `sourceIdentifier` aus Backend-Device-State generieren und stabil halten, solange Device verbunden ist.
- `stableIdentifierForTouchDevice:` auf generische Backend-Device-Keys umstellen.
- Gelernte Zuweisungen migrieren:
  - alte `usb:vendor:product:name`-Keys lesen.
  - neue `driverkit:...`-Keys schreiben.
  - bei Mehrdeutigkeit nicht automatisch uebernehmen.
- `checkHIDListenEventAccessGranted` und `requestHIDListenEventAccess` ersetzen:
  - neue API z. B. `checkInputBackendAccessGranted`
  - alte Namen optional als deprecated Shim fuer interne Kompatibilitaet behalten, aber sie duerfen kein Input Monitoring mehr anfordern.
- Input-Monitoring-Banner aus Settings entfernen.
- Neues Backend-/System-Extension-Statusbanner ergaenzen, falls Aktivierung noch fehlt.

### Phase 6: Mapping, Kalibrierung und Gesten unveraendert absichern

Ziel: Alles bleibt fuer Nutzer wie bisher.

- `TUCTouchDisplayAssignmentResolver` bleibt die einzige Stelle fuer Display-Zuordnung.
- Automatische Zuordnung nutzt weiterhin:
  - gelernte Zuweisung
  - bestehende Zuweisung
  - Name-Match
  - Hotplug-Korrelation
  - Single-Screen
  - naechster freier Screen
  - Fallback
- Manuelles Mapping bleibt App/Core-Funktion und schreibt nur gelernte Device-Key-zu-DisplayID-Zuweisungen.
- Kalibrierung bleibt in `TouchCalibrationStore` pro `TUCScreen.calibrationKey`.
- Gesten-State-Machine bleibt auf `TUCTouch` und `sourceIdentifier`.
- Bei Display-Zuordnungswechseln aktive Touches/Gesten pro Device canceln.
- Tests mit Fake-Backend:
  - zwei Touchdevices auf zwei Screens
  - identische VID/PID ohne Serial
  - Reconnect mit Serial
  - Reconnect ohne Serial auf anderem Port
  - manuelles Mapping gewinnt gegen Fallback
  - Kalibrierung wird nur im Core angewendet

### Phase 7: Packaging, Berechtigungen und Dokumentation

Ziel: Der Nutzer sieht keine Input-Monitoring-Anforderung mehr, aber bekommt klare System-Extension-Hinweise.

- Entitlements, Team ID, Bundle IDs und Notarization pruefen.
- System Extension Activation Flow in App integrieren.
- MDM-Hinweise dokumentieren.
- README aktualisieren:
  - Input Monitoring entfernen.
  - Accessibility bleibt fuer Event-Ausgabe.
  - System Extension Approval erklaeren.
  - Mapping/Kalibrierung unveraendert beschreiben.
- Settings-Texte aktualisieren.
- Diagnose-Logs aktualisieren:
  - Backend status
  - Device key
  - sourceIdentifier
  - assigned display
  - assignment reason/confidence
  - parser profile, aber keine rohen privaten Eingabedaten dauerhaft loggen

### Phase 8: QA und Abnahme

Automatisierte Pruefung:

```sh
git diff --check
xcodebuild -project 'Touch Up.xcodeproj' -scheme 'Touch Up' -configuration Debug -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project 'Touch Up.xcodeproj' -scheme 'TouchUpCore' -configuration Debug -derivedDataPath ./DerivedData CODE_SIGNING_ALLOWED=NO test
```

Manuelle Hardware-QA:

- Einzelner externer Touchmonitor.
- Ein interner plus ein externer Touchmonitor.
- Zwei externe Touchmonitore.
- Zwei identische Touchcontroller ohne eindeutige Seriennummer.
- USB vor Display verbinden.
- Display vor USB verbinden.
- Reconnect am gleichen Port.
- Reconnect an anderem Port.
- Display Rotation.
- Mapping Assistant.
- Calibration Assistant.
- Tap, Cursor Move, Titlebar Drag, Press-and-Hold, Two-Finger Tap, Two-Finger Scroll.
- Disconnect waehrend aktiver Geste.
- App Neustart.
- System Neustart.

## Abnahmekriterien

Die Umsetzung gilt erst als fertig, wenn:

- Touch-Eingabe funktioniert ohne Input-Monitoring-Prompt.
- Keine normale Tastatur, Maus oder nicht-touch HID-Komponente vom Treiber uebernommen wird.
- Accessibility bleibt nur fuer Event-Ausgabe relevant.
- Alle aktuellen Parameter wirken weiter.
- Mehrere Touchmonitore funktionieren automatisch.
- Manuelles Mapping funktioniert bei mehrdeutigen Setups.
- Kalibrierung bleibt pro Display erhalten.
- Gesten verhalten sich wie vor dem Backend-Tausch.
- Der Treiber enthaelt keine Display-, Monitor-, Hersteller- oder Modell-spezifische Logik.
- Display-Zuordnung findet nur in TouchUpCore/App statt.
- Hardware-QA ist dokumentiert.
- README und Settings sagen nicht mehr, dass Input Monitoring erforderlich ist.

## Risiken und Entscheidungen

| Risiko | Auswirkung | Gegenmassnahme |
| --- | --- | --- |
| DriverKit-Entitlements sind nicht verfuegbar | Backend kann nicht verteilt werden | Frueh klaeren, bevor Parser/Integration gross gebaut werden |
| Generisches HID-Matching ist zu breit | Nicht-Touch-Geraete koennten abgefangen werden | Boot-Keyboard/-Mouse ausschliessen, Report-Descriptor vor Aktivierung pruefen, Nicht-Touch ablehnen |
| Driver kann Nicht-Touch-Geraete nicht sauber durchreichen | Sicherheits- und UX-Risiko | Phase 2 als hartes Gate; kein Hauptpfad ohne Beweis |
| Einige Touchscreens liefern fehlerhafte Deskriptoren | Geraet funktioniert schlechter als im alten Backend | Parser-Fixtures sammeln; nur generische Heuristiken; Quirks nicht im Treiber |
| System Extension Approval ist schwerer als Input Monitoring | Andere Installationshuerde | Klare UI und README, MDM-Hinweise |
| Gesten regressieren durch Backend-Timing | Bestehendes Verhalten bricht | Fake-Backend-Tests plus Hardware-QA mit Frame-Sequenzen |
| Identische Controller ohne Serial wechseln Ports | Persistente Zuordnung kann mehrdeutig werden | Ohne stabile Identitaet nicht automatisch persistent lernen; Mapping neu anbieten |

## Fortschrittstracking

| Schritt | Status | Notizen |
| --- | --- | --- |
| UPDD-Architektur analysieren | Erledigt | Quellen ausgewertet: System Extension, USB-Zugriff, API/Commander, Multi-Monitor-Metriken. |
| Touch-Up Ist-Zustand analysieren | Erledigt | IOHID/Input-Monitoring-Pfad, Resolver, Kalibrierung, Mapping und Gesten geprueft. |
| Zielarchitektur festlegen | Erledigt | Driver ohne Monitorwissen, Backend-Service/API, bestehender Core fuer Mapping/Kalibrierung/Gesten. |
| Plan-Dokument anlegen | Erledigt | Dieses Dokument. |
| Backend-Abstraktion implementieren | Offen | Start mit IOHID-Adapter ohne Verhaltensaenderung. |
| Fake-Backend und Core-Tests | Offen | Touchframes, Device-Lifecycle, Disconnect, Gesten. |
| DriverKit-Entitlements/Signing klaeren | Offen | Muss vor echter System Extension passieren. |
| DriverKit/System-Extension POC | Offen | Hartes Gate: Touch ohne Input Monitoring, keine Nicht-Touch-HID-Uebernahme. |
| Generischen HID-Parser bauen | Offen | Descriptor-Fixtures und Multi-Touch-Modi. |
| Backend-Service/XPC bauen | Offen | Versionierte lokale API, Diagnostics, Device-Lifecycle. |
| TouchUpCore auf neues Backend umstellen | Offen | Neuer Standardpfad, alter IOHID-Pfad hoechstens Debug/Fallback. |
| Input-Monitoring-UI entfernen | Offen | Durch Backend-/System-Extension-Status ersetzen. |
| Mapping/Kalibrierung/Gesten regressionssicher machen | Offen | Tests und Hardware-QA. |
| Packaging/Notarization | Offen | System Extension Activation, MDM, Distribution. |
| README und Docs aktualisieren | Offen | Nach erfolgreichem POC und Integrationsentscheidung. |
| Hardware-QA durchfuehren | Offen | Mehrere Geraete-/Monitor-Szenarien dokumentieren. |

## Ausfuehrungsprotokoll

| Zeit | Schritt | Commit | Ergebnis |
| --- | --- | --- | --- |
| 2026-07-03 | Plan-Dokument versionieren | ausstehend | Plan als Arbeitsgrundlage in Git aufgenommen. |

## Quellen

- Touch-Base UPDD Home: https://www.touch-base.com/
- Touch-Base Drivers: https://www.touch-base.com/drivers.html
- UPDD V7 introduction: https://support.touch-base.com/Documentation/50781/UPDD-V7-introduction
- System Interfaces: https://support.touch-base.com/Documentation/50351/System-Interfaces
- UPDD API topology: https://support.touch-base.com/Documentation/50416/UPDD-API-topology
- UPDD Commander: https://support.touch-base.com/Documentation/50592/Commander
- USB Hardware Interfaces: https://support.touch-base.com/Documentation/50536/USB
- MacOS Quick Installation Guide: https://support.touch-base.com/Documentation/50245/Quick-installation-guide
- System Extension consideration: https://support.touch-base.com/Documentation/50751/System-Extension-consideration
- Multi-monitor and device support: https://support.touch-base.com/Documentation/50347/Multimonitor-and-device-support
- Monitor Metrics: https://support.touch-base.com/Documentation/50387/Monitor-Metrics
