# DriverKit-Entitlements und Signing-Klaerung

Stand: 2026-07-03

## Ergebnis

Der DriverKit/System-Extension-Pfad ist technisch plausibel, aber fuer einen echten POC nicht nur eine Codefrage. Touch Up braucht vor dem lauffaehigen DriverKit-Target Apple-gewaehrte DriverKit-Entitlements und ein passendes Provisioning-Profil fuer das Team `KU5M734DYN`.

## Aktueller Repo-Stand

- App Bundle ID: `de.schafe.Touch-Up`
- Core Bundle ID: `de.schafe.HID-Touch-Input`
- Development Team: `KU5M734DYN`
- Aktuelle App-Entitlements: nur `com.apple.security.cs.disable-library-validation`
- Es gibt noch kein DriverKit/System-Extension-Target und noch kein System-Extension-Install-Entitlement in der Host-App.

## Benoetigte Entitlements

Host-App:

- `com.apple.developer.system-extension.install`
  - Erforderlich, damit die App System Extensions, inklusive DriverKit Extensions, aktivieren oder deaktivieren kann.

DriverKit Extension:

- `com.apple.developer.driverkit`
  - Erforderlich fuer jede DriverKit-Extension; Apple beschreibt das als Berechtigung, als User-Space-Driver zu laufen.
  - Muss bei Apple beantragt und dem Team-Profil zugeordnet werden.
- Transport-/Familien-Entitlement je nach POC-Ansatz:
  - USB-Rohzugriff: `com.apple.developer.driverkit.transport.usb`
  - HID-Ansatz: mindestens `com.apple.developer.driverkit.transport.hid`; fuer HID-Event-Service-Beispiele nennt Apple zusaetzlich `com.apple.developer.driverkit.family.hid.eventservice`.
- Falls App oder Backend-Service per `IOUserClient` mit dem Driver spricht:
  - `com.apple.developer.driverkit.userclient-access`
  - Wert: Bundle ID(s) der DriverKit-Extension(s), die der Client verwenden darf.

## USB-Matching-Konsequenz

Apple beschreibt `com.apple.developer.driverkit.transport.usb` als Array von Dictionaries, die USB-Geraete anhand von Descriptor-Feldern identifizieren. Genannte Keys sind unter anderem `idVendor`, `idProduct`, `idProductArray`, `idProductMask`, `bDeviceClass`, `bDeviceSubClass`, `bDeviceProtocol`, `bInterfaceClass`, `bInterfaceSubClass`, `bInterfaceProtocol`, `bInterfaceNumber` und `bConfigurationValue`.

Das ist fuer Touch Up der wichtigste offene Gate-Punkt:

- Der Plan verlangt einen generischen Treiber ohne Hersteller-/Monitor-Sonderfaelle.
- Apple-Entitlements und USB-Matching scheinen trotzdem descriptor-basierte Eingrenzung zu verlangen.
- Phase 2 muss deshalb beweisen, dass ein ausreichend enger generischer Interface-Match fuer Touch-/Digitizer-HID moeglich ist, ohne normale Tastaturen, Maeuse oder andere HID-Geraete zu uebernehmen.
- Wenn Apple oder macOS nur VID/PID-nahe oder zu breite Matches erlauben, bleibt der POC am Abbruchkriterium des Plans haengen.

## Signing- und Packaging-Notizen

- DriverKit-Treiber werden als App Extension in der Host-App ausgeliefert.
- Auf macOS installiert bzw. aktualisiert die Host-App den Driver ueber das SystemExtensions-Framework.
- Fuer Distribution sind Developer-ID/Team-Profil, passende Entitlements, Hardened Runtime und Notarization gemeinsam zu pruefen.
- Lokales Entwickeln/Testen kann laut Apple auch waehrend der Entitlement-Wartezeit fortgesetzt werden, aber produktionsnahe Installation und Distribution brauchen die finalen Entitlements.

## Entscheidung fuer den naechsten Schritt

Noch kein dauerhaftes DriverKit-Target ins Hauptprodukt aufnehmen, bevor die Entitlement-Gruppe und die Matching-Strategie geklaert sind. Der naechste sinnvolle Schritt ist ein isolierter POC-Branch/Target mit:

- Host-App-Entitlement `com.apple.developer.system-extension.install`
- DriverKit-Extension-Bundle ID, z. B. `de.schafe.Touch-Up.TouchUpDriverExtension`
- beantragtem `com.apple.developer.driverkit`
- geprueftem USB- oder HID-Transport-Entitlement
- dokumentiertem Test gegen mindestens ein Touch-HID-Interface und normale Nicht-Touch-HID-Geraete

## Primaerquellen

- Apple DriverKit: https://developer.apple.com/documentation/driverkit
- Apple Requesting Entitlements for DriverKit Development: https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development
- Apple `com.apple.developer.driverkit`: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit
- Apple System Extension Entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install
- Apple USBDriverKit: https://developer.apple.com/documentation/usbdriverkit
- Apple `com.apple.developer.driverkit.transport.usb`: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.transport.usb
- Apple `com.apple.developer.driverkit.userclient-access`: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.userclient-access
