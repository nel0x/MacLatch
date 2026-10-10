# YubiKey Guard for macOS

## 1. Projektziel

Dieses Projekt implementiert ein kleines, quelloffenes und möglichst robustes macOS-Menüleistenprogramm, das einen angeschlossenen YubiKey überwacht.

Der zentrale Anwendungsfall ist:

1. Der Mac kann jederzeit ganz normal **ohne YubiKey** benutzt werden.
2. Sobald der definierte YubiKey angeschlossen wird, wird die Schutzfunktion automatisch aktiviert.
3. Wird dieser YubiKey anschließend entfernt, startet ein Countdown von **3 Sekunden**.
4. Ist der YubiKey nach Ablauf dieser 3 Sekunden weiterhin nicht angeschlossen, wird der Mac gesperrt.
5. Wird der YubiKey innerhalb dieser 3 Sekunden wieder angeschlossen, wird die Sperrung abgebrochen.
6. Nach einer durch das Programm ausgelösten Sperrung ist der Schutz wieder **deaktiviert**, bis der YubiKey erneut angeschlossen wird.

Das Projekt darf unter keinen Umständen dazu führen, dass der Benutzer ohne YubiKey dauerhaft vom eigenen Mac ausgesperrt wird.

Der YubiKey ist ausdrücklich **kein Authentifizierungsfaktor für macOS Login oder Unlock**.

---

# 2. Zentrale Sicherheitsinvariante

Die wichtigste Designregel des gesamten Projekts lautet:

> Ein YubiKey darf die Anwendung scharf schalten. Das Fehlen eines YubiKeys darf die Anwendung niemals scharf schalten.

Das bedeutet insbesondere:

- Der Mac muss vollständig ohne YubiKey benutzbar bleiben.
- Die Anwendung darf niemals voraussetzen, dass ein YubiKey vorhanden ist, um sich einzuloggen oder den Mac zu entsperren.
- Die Anwendung darf keine Änderungen an PAM, `loginwindow`, FileVault, Touch ID, Passwortauthentifizierung oder anderen macOS-Authentifizierungsmechanismen vornehmen.
- Der `armed`-Zustand darf nicht dauerhaft gespeichert werden.
- Nach Programmstart ohne YubiKey muss der Zustand immer `unarmed` sein.
- Nach einer durch die Anwendung ausgelösten Bildschirmsperre muss der Zustand ebenfalls wieder `unarmed` sein.
- Fehler oder unklare Zustände sollen möglichst **fail-open** behandelt werden:
  - lieber nicht sperren
  - als durch einen Fehler ungewollt eine Sperrschleife zu erzeugen.

Ein Softwarefehler darf im schlimmsten Fall dazu führen, dass der automatische Lock nicht funktioniert.

Ein Softwarefehler darf nicht dazu führen, dass der Benutzer den Mac ohne YubiKey nicht mehr verwenden kann.

---

# 3. Zielplattform

Primäre Zielplattform:

- macOS
- Apple Silicon
- aktuelle macOS-Versionen

Die Anwendung soll möglichst auch auf Intel-Macs funktionieren, solange dies ohne erhebliche Zusatzkomplexität möglich ist.

Die Anwendung soll nativ implementiert werden.

Bevorzugte Sprache:

- **Swift**

Begründung:

- speichersicher
- native macOS-Integration
- gute Integration mit AppKit
- gute Integration mit Swift Concurrency
- Zugriff auf IOKit möglich
- verständlicher und möglichst kleiner Code

Es soll kein Electron, Node.js, Python oder vergleichbarer Runtime-Stack verwendet werden.

---

# 4. Open Source

Das Projekt soll vollständig quelloffen sein.

Bevorzugte Lizenz:

- MIT

Alternativ:

- Apache-2.0

Der Code soll möglichst leicht auditierbar bleiben.

Security-relevanter Code sollte bewusst einfach und nachvollziehbar geschrieben werden.

---

# 5. Anwendungstyp

Die Anwendung soll als normale macOS-Menüleisten-App laufen.

Sie benötigt kein Dock-Icon.

Sie soll möglichst ohne Root-Rechte funktionieren.

Nicht verwenden:

- Root-Daemon
- privileged helper
- Kernel Extension
- System Extension, sofern nicht zwingend erforderlich
- PAM-Module
- Login Hooks

Bevorzugt wird ein normaler Prozess im Benutzerkontext.

---

# 6. Zustände

Die Anwendung besitzt drei wesentliche Zustände.

## 6.1 UNARMED

Darstellung:

- gelb

Bedeutung:

- Der Schutz ist nicht aktiv.
- Das Entfernen eines YubiKeys darf keine Aktion auslösen.
- Der Mac kann normal verwendet werden.

Typische Situationen:

- App wurde gestartet und es ist kein YubiKey angeschlossen.
- Mac wurde gerade entsperrt, nachdem YubiKey Guard ihn gesperrt hat.
- Anwendung wurde bewusst deaktiviert.
- Nach einem Programmfehler oder einem nicht eindeutig bestimmbaren Gerätezustand.

Symbolisch:

```text
🟡 UNARMED
```

---

## 6.2 ARMED

Darstellung:

- grün

Bedeutung:

- Der konfigurierte YubiKey ist angeschlossen.
- Das Entfernen dieses YubiKeys startet den 3-Sekunden-Countdown.

Symbolisch:

```text
🟢 ARMED
```

Der Zustand wird ausschließlich dadurch erreicht, dass der konfigurierte YubiKey tatsächlich erkannt wurde.

---

## 6.3 PENDING_LOCK

Darstellung:

- rot

Bedeutung:

- Der konfigurierte YubiKey wurde entfernt.
- Ein Countdown von 3 Sekunden läuft.
- Wird der YubiKey innerhalb dieses Zeitraums wieder erkannt, wird die Aktion abgebrochen.
- Ist er nach 3 Sekunden weiterhin nicht vorhanden, wird der Mac gesperrt.

Symbolisch:

```text
🔴 PENDING_LOCK
```

Der rote Zustand ist bewusst kurzlebig.

---

# 7. Zustandsmaschine

Die zentrale Zustandsmaschine soll ungefähr folgendes Verhalten implementieren:

```text
                       YubiKey inserted
                ┌─────────────────────────┐
                │                         ▼
          🟡 UNARMED                 🟢 ARMED
                ▲                         │
                │                         │ YubiKey removed
                │                         ▼
                │                   🔴 PENDING_LOCK
                │                         │
                │                    3 second timer
                │                         │
                │           ┌─────────────┴─────────────┐
                │           │                           │
                │      key inserted                timer expires
                │           │                           │
                │           ▼                           ▼
                │       🟢 ARMED                   revalidate key
                │                                       │
                │                              ┌────────┴─────────┐
                │                              │                  │
                │                         key present        key absent
                │                              │                  │
                │                              ▼                  ▼
                │                          🟢 ARMED             LOCK
                │                                                 │
                └─────────────────────────────────────────────────┘
                                       🟡 UNARMED
```

Wichtig:

Nach erfolgreichem Lock muss der State **UNARMED** sein.

---

# 8. Verhalten beim Programmstart

Der Zustand `armed` darf nicht aus einer vorherigen Sitzung wiederhergestellt werden.

Beim Start:

```text
App starts
    |
    +-- configured YubiKey currently connected
    |        |
    |        +--> ARMED
    |
    +-- configured YubiKey not connected
             |
             +--> UNARMED
```

Es darf insbesondere nicht passieren:

```text
Yesterday:
armed = true

Restart today without YubiKey:
armed restored from disk
```

Dieser Zustand ist ausdrücklich verboten.

---

# 9. Persistente Einstellungen

Persistiert werden dürfen beispielsweise:

- ausgewählter YubiKey
- Seriennummer
- Gerätebezeichnung
- Vendor-ID
- Product-ID, falls sinnvoll
- Lock Delay
- Start at Login
- SSH-Verbindungen schließen: ja/nein
- Test-/Monitor-Modus
- UI-Einstellungen

Nicht persistieren:

```text
armed = true
pendingLock = true
```

Runtime-State muss flüchtig sein.

---

# 10. YubiKey-Erkennung

Es soll ausdrücklich **kein permanentes Polling** verwendet werden.

Nicht erwünscht:

```bash
while true; do
    ioreg ...
    sleep 1
done
```

oder:

```bash
system_profiler SPUSBDataType
```

in regelmäßigen Intervallen.

Stattdessen soll die Anwendung auf macOS-USB-/IOKit-Notifications reagieren.

Bevorzugter Ansatz:

- IOKit
- `IOServiceAddMatchingNotification`
- passende USB-/IOUSBHost-Geräte
- Arrival-/Termination-Notifications

Der Code soll möglichst direkt auf das physische USB-Gerät reagieren.

---

# 11. Composite Device beachten

YubiKeys stellen häufig mehrere Funktionen bzw. Interfaces bereit, beispielsweise:

- HID
- OTP
- FIDO
- CCID / Smart Card

Die Anwendung darf nicht davon ausgehen, dass das Entfernen eines einzelnen Interfaces dem physischen Entfernen des YubiKeys entspricht.

Bevorzugt soll das eigentliche physische USB-Gerät überwacht werden.

Ein interner Interface-Reset darf möglichst nicht als vollständiges YubiKey-Removal behandelt werden.

---

# 12. Geräteidentifikation

Der Schutz soll möglichst nicht von irgendeinem beliebigen YubiKey aktiviert werden.

Die Anwendung sollte einen konkreten YubiKey identifizieren können.

Bevorzugte Identifikation:

1. Yubico Vendor-ID
2. spezifische Seriennummer des YubiKeys
3. optional Product-ID / Modell

Bekannte Yubico Vendor-ID:

```text
0x1050
```

Die Seriennummer des konfigurierten YubiKeys soll gespeichert werden können.

Beispiel:

```text
Configured YubiKey:
Model: YubiKey 5C NFC
Serial: 12345678
Vendor: 0x1050
```

In der normalen UI darf die Seriennummer optional teilweise maskiert dargestellt werden:

```text
••••5678
```

---

# 13. Removal-Handling

Wird der konfigurierte YubiKey im Zustand `ARMED` entfernt:

1. State auf `PENDING_LOCK`
2. Statusanzeige auf rot
3. cancellable Timer mit exakt 3 Sekunden starten
4. YubiKey-Insert-Notifications weiterhin verarbeiten

Wird der YubiKey innerhalb der 3 Sekunden wieder erkannt:

1. Timer abbrechen
2. State zurück auf `ARMED`
3. keine Sperrung

---

# 14. 3-Sekunden-Timer

Der Timer soll nicht über Vergleiche mit der normalen Systemzeit implementiert werden.

Bevorzugt:

- Swift `Clock`
- ContinuousClock / monotonic time
- Swift Concurrency

Beispielsweise sinngemäß:

```swift
try await ContinuousClock().sleep(for: .seconds(3))
```

Der Timer muss cancellable sein.

Wenn währenddessen der YubiKey wieder angeschlossen wird:

```swift
pendingLockTask?.cancel()
```

Die Zustandsmaschine muss Race Conditions zwischen:

- USB removal
- USB insertion
- Timer expiration

verhindern.

Ein Swift `actor` für die Zustandsmaschine ist ausdrücklich erwünscht.

---

# 15. Revalidation vor dem Lock

Vor dem tatsächlichen Lock soll nach Ablauf der 3 Sekunden noch einmal geprüft werden, ob der konfigurierte YubiKey aktuell wirklich nicht vorhanden ist.

Dies ist ausdrücklich erlaubt und gilt nicht als Polling.

Ablauf:

```text
Removal notification
        |
        v
PENDING_LOCK
        |
      3 sec
        |
        v
one-time device revalidation
        |
   +----+----+
   |         |
present    absent
   |         |
 ARMED     LOCK
```

Das schützt beispielsweise vor:

- kurzfristigen USB-Resets
- Dock-Resets
- Race Conditions
- Notification-Reordering
- einem YubiKey, der unmittelbar vor Ablauf des Timers erneut erkannt wurde

Bei Unsicherheit soll nicht gesperrt werden.

---

# 16. Verhalten nach Lock

Nachdem die Anwendung erfolgreich eine Sperrung ausgelöst hat:

```text
state = UNARMED
```

Der Benutzer darf anschließend:

- per Passwort
- per Touch ID
- oder über andere normale macOS-Mechanismen

den Mac entsperren.

Der YubiKey darf hierfür nicht erforderlich sein.

Wichtig:

Ein weiterhin abgezogener YubiKey darf **keine erneute automatische Sperre** auslösen.

Erst wenn der konfigurierte YubiKey erneut angeschlossen wird:

```text
UNARMED -> ARMED
```

---

# 17. Kein Lock-Loop

Folgendes Verhalten darf niemals auftreten:

```text
YubiKey removed
    |
LOCK
    |
user unlocks with password
    |
YubiKey still absent
    |
LOCK again
    |
user unlocks
    |
LOCK again
```

Nach jeder ausgelösten Sperrung muss die Anwendung `UNARMED` sein.

---

# 18. macOS Lock-Implementierung

Die Anwendung soll ausschließlich den normalen macOS Lock Screen auslösen.

Nicht verwenden:

- Logout
- `kill loginwindow`
- Shutdown
- Reboot
- Prozessabschuss des WindowServers
- Passwortänderungen
- Login-Manipulation

Zu untersuchen ist die robusteste Möglichkeit auf aktuellen macOS-Versionen.

Mögliche Ansätze:

- aktuelle öffentliche macOS APIs, sofern vorhanden
- `SACLockScreenImmediate()` als bestehender, aber privater Mechanismus
- andere etablierte und möglichst risikoarme Lock-Mechanismen

Wenn ein verwendeter Lock-Mechanismus nicht verfügbar ist, muss die Anwendung **fail-open** reagieren.

Das bedeutet:

```text
Lock backend unavailable
        |
        v
do not arm
```

Die Anwendung darf nicht auf einen aggressiveren Mechanismus wie Logout oder Shutdown zurückfallen.

---

# 19. LockService

Der Lock-Code soll klar von der übrigen Anwendung getrennt sein.

Beispielsweise:

```text
LockService
```

API ungefähr:

```swift
protocol LockService {
    var isAvailable: Bool { get }

    func lock() async throws
}
```

Die State Machine muss prüfen können:

```swift
guard lockService.isAvailable else {
    state = .unarmed
    return
}
```

---

# 20. Menüleisten-UI

Die Anwendung soll ein kleines Symbol oben in der macOS-Menüleiste besitzen.

Bevorzugt:

- `NSStatusItem`
- AppKit

Die Anzeige soll sofort erkennen lassen, ob der Schutz aktiv ist.

Gewünschte Zustände:

```text
🟡 yellow  = unarmed
🟢 green   = armed
🔴 red     = pending lock
```

Optisch beispielsweise:

```text
🔒 ●
```

oder ein Schloss-Icon mit Statuspunkt.

Es sollen native macOS-Symbole verwendet werden, sofern sinnvoll:

- SF Symbols
- z. B. `lock`
- `lock.fill`

---

# 21. Menüinhalt

Beispiel für ARMED:

```text
YubiKey Guard

● Armed

YubiKey 5C NFC
Serial: ••••5678

Lock after removal: 3 seconds
SSH sessions: Disabled

────────────────────
Disarm
Test Lock
Settings…
────────────────────
Quit
```

Beispiel für UNARMED:

```text
YubiKey Guard

● Unarmed

Insert your YubiKey to arm protection.

────────────────────
Settings…
Test Lock
────────────────────
Quit
```

Beispiel für PENDING_LOCK:

```text
YubiKey Guard

● YubiKey removed

Locking in 2.3 seconds…

Insert YubiKey to cancel.
```

Der Countdown darf optional live dargestellt werden.

Die korrekte Sicherheitslogik ist wichtiger als eine perfekte Countdown-Anzeige.

---

# 22. Manuelles Disarm

Es soll möglich sein, den Schutz bewusst zu deaktivieren.

Beispielsweise:

```text
Disarm
```

Danach:

```text
state = UNARMED
```

Optional kann entschieden werden, ob ein bereits angeschlossener YubiKey anschließend erst einmal entfernt und neu eingesteckt werden muss, bevor erneut automatisch `ARMED` erreicht wird.

Bevorzugte sichere Variante:

Nach manuellem `Disarm` bleibt die Anwendung unarmed, bis ein neuer eindeutiger Insert-Event des konfigurierten YubiKeys erfolgt.

---

# 23. Monitor-/Test-Modus

Für die erste Version soll ein Monitor-/Test-Modus vorhanden sein.

In diesem Modus werden Events und geplante Aktionen angezeigt oder geloggt, aber es erfolgt kein tatsächlicher Lock.

Beispiel:

```text
[14:20:11] YubiKey inserted
[14:20:11] State: ARMED

[14:25:43] YubiKey removed
[14:25:43] State: PENDING_LOCK
[14:25:46] Would lock now
[14:25:46] State: UNARMED
```

Zweck:

Vor Aktivierung des echten Lockings sollen unter realen Bedingungen getestet werden:

- direkt am Mac
- USB-C-Hub
- Docking Station
- Sleep/Wake
- Display Sleep
- macOS User Lock
- USB Reset
- Thunderbolt Dock Reconnect
- Neustart
- App Restart
- YubiKey schnell herausziehen und wieder einstecken

Der Monitor Mode soll helfen, Fehlalarme zu erkennen.

---

# 24. Logging

Logging soll hilfreich, aber zurückhaltend sein.

Bevorzugt:

- `Logger`
- `os.log`

Zu loggen:

- Programmstart
- erkannte YubiKeys
- State Transitions
- USB insert/remove
- Timer start
- Timer cancellation
- Revalidation
- Lock-Versuch
- Lock-Erfolg/Fehler

Nicht loggen:

- geheime YubiKey-Daten
- PINs
- Secrets
- private Keys

Beispiel:

```text
UNARMED -> ARMED
Reason: configured YubiKey attached
```

---

# 25. Swift-Concurrency-Architektur

Bevorzugte Komponenten:

```text
┌────────────────────┐
│   YubiKeyMonitor   │
│       IOKit        │
└─────────┬──────────┘
          │ events
          ▼
┌────────────────────┐
│ GuardStateMachine  │
│       actor        │
└───────┬───────┬────┘
        │       │
        │       └──────────────┐
        ▼                      ▼
┌──────────────┐       ┌───────────────┐
│ LockService  │       │ UI Controller │
└──────────────┘       └───────────────┘
```

Mögliche weitere Komponenten:

```text
SettingsStore
SSHSessionService
AppController
StatusItemController
```

Die Zustandslogik soll möglichst unabhängig von der UI testbar sein.

---

# 26. Event-Modell

Beispielsweise:

```swift
enum GuardEvent {
    case configuredKeyAttached
    case configuredKeyRemoved
    case lockTimerExpired
    case manualDisarm
    case lockCompleted
    case lockFailed
}
```

State:

```swift
enum GuardState {
    case unarmed
    case armed
    case pendingLock
}
```

Die State Machine sollte möglichst explizit implementiert sein.

Keine schwer nachvollziehbare Kombination aus vielen Booleans wie:

```swift
isAttached
isActive
isWaiting
wasPreviouslyConnected
shouldLock
didLock
```

Bevorzugt wird ein eindeutiger State.

---

# 27. Start at Login

Optional soll die Anwendung bei Benutzeranmeldung automatisch gestartet werden können.

Bevorzugt moderne Apple-Mechanismen verwenden.

Keine Shell-Hacks oder manuell erzeugten Login-Skripte, sofern vermeidbar.

Wichtig:

Autostart ohne YubiKey führt immer zu:

```text
UNARMED
```

---

# 28. SSH-Session-Unterstützung

Eine optionale spätere Funktion ist:

> Beim Entfernen des YubiKeys laufende SSH-Sessions schließen.

Diese Funktion muss optional sein und standardmäßig zunächst deaktiviert bleiben.

Grund:

Das Beenden einer SSH-, SCP- oder SFTP-Verbindung kann laufende Arbeiten oder Dateiübertragungen unterbrechen.

Mögliche Prozesse:

```text
ssh
scp
sftp
```

Bevorzugtes Verhalten:

zunächst:

```text
SIGTERM
```

Nicht sofort:

```text
SIGKILL
```

Beispiel:

```text
YubiKey removed
       |
       v
3 second grace period
       |
       v
still absent?
       |
       +--> terminate configured SSH processes
       |
       +--> lock Mac
```

Die genaue SSH-Funktionalität kann nach dem stabilen Locking implementiert werden.

---

# 29. SSH-Sicherheitsanforderungen

Keine automatische Prozessbeendigung in der ersten Minimalversion, sofern dies die Kernimplementierung unnötig verkompliziert.

Wenn implementiert:

- Feature standardmäßig OFF
- Benutzer muss es bewusst aktivieren
- klar anzeigen, welche Prozesse betroffen sind
- möglichst zunächst `SIGTERM`
- Fehler beim SSH-Kill dürfen den normalen Lock-Vorgang nicht verhindern

---

# 30. Verhalten bei App-Crash

Ein Crash darf keine gefährliche Persistenz erzeugen.

Nach Neustart gilt erneut:

```text
configured YubiKey present -> ARMED

configured YubiKey absent -> UNARMED
```

Es darf keinen persistenten Countdown geben.

Es darf keine automatische Lock-Aktion aus einem alten State heraus ausgeführt werden.

---

# 31. Verhalten bei Sleep/Wake

Sleep/Wake muss explizit getestet werden.

Mögliche Situation:

```text
ARMED
   |
Mac sleeps
   |
USB devices disappear / reconnect
   |
Mac wakes
```

Dies darf möglichst nicht zu einem Fehl-Lock führen.

Bevor bei Wake aufgrund eines Device-Removal-Events gesperrt wird, muss der aktuelle physische Zustand zuverlässig validiert werden.

Wenn der Zustand nicht eindeutig bestimmbar ist:

```text
UNARMED
```

bevorzugen.

---

# 32. Verhalten bei USB-Docks

Folgende Konstellationen müssen getestet werden:

- YubiKey direkt am Mac
- YubiKey an USB-C-Hub
- YubiKey an Thunderbolt-Dock
- Dock kurz getrennt
- Dock verliert temporär Strom
- USB-Bus wird neu enumeriert

Ein Dock-Reset kann technisch wie ein Device Removal aussehen.

Der 3-Sekunden-Grace-Period plus abschließende Revalidation soll Fehlalarme reduzieren.

---

# 33. Kein automatisches Lock beim initialen Fehlen

Folgender Fall darf niemals sperren:

```text
App starts
YubiKey absent
```

Ergebnis:

```text
UNARMED
```

Auch nach beliebig langer Zeit ohne YubiKey darf nichts passieren.

---

# 34. Kein Lock aufgrund eines unbekannten YubiKeys

Wenn ein anderer YubiKey angeschlossen oder entfernt wird:

```text
ignore
```

Nur der konfigurierte YubiKey darf die State Machine steuern.

---

# 35. Initiales Setup

Beim ersten Start gibt es noch keinen konfigurierten YubiKey.

State:

```text
UNARMED
```

Die Anwendung soll verfügbare YubiKeys anzeigen können.

Beispielsweise:

```text
No YubiKey configured.

Detected devices:

YubiKey 5C NFC
Serial: 12345678

[Use this YubiKey]
```

Erst nach bewusster Auswahl wird die Seriennummer gespeichert.

---

# 36. Einstellungen

Mögliche Settings:

```text
Configured YubiKey
    YubiKey 5C NFC
    Serial: ••••5678

Lock delay
    3 seconds

Start at Login
    On

Close SSH Sessions
    Off

Monitor Mode
    On/Off
```

Der Lock Delay soll intern konfigurierbar sein.

Für die erste Version gilt als Default und gewünschter Wert:

```text
3 seconds
```

---

# 37. Sicherheitsrelevante Nicht-Ziele

Das Projekt ist ausdrücklich **kein**:

- Ersatz für FileVault
- Ersatz für ein starkes Login-Passwort
- Login-Authentifizierungssystem
- PAM-Modul
- FIDO2 Login Provider
- Smartcard Login System
- MDM-System
- Endpoint Detection Tool
- Device Control System

Es soll nur eine einfache physische Sicherheitsautomatisierung bereitstellen:

```text
Key present
    ->
protection armed

Key removed
    ->
short delay
    ->
screen lock
```

---

# 38. Berechtigungen

Die Anwendung soll möglichst keine unnötigen Berechtigungen verlangen.

Insbesondere nach Möglichkeit keine:

- Full Disk Access
- Accessibility Permission
- Screen Recording
- Input Monitoring
- root privileges

Falls eine Berechtigung tatsächlich erforderlich wird, muss dokumentiert werden:

- warum
- wofür
- welche Alternative geprüft wurde

---

# 39. Keine Telemetrie

Die Anwendung soll keine Telemetrie enthalten.

Keine:

- Analytics
- Crash Uploads an externe Anbieter
- Usage Tracking
- Device Tracking
- Netzwerkkommunikation

Die Anwendung soll grundsätzlich offline funktionieren.

---

# 40. Netzwerk

Der Kern der Anwendung benötigt keinerlei Netzwerkzugriff.

Idealerweise öffnet der Prozess keine Netzwerkverbindungen.

---

# 41. Codequalität

Der Code soll:

- verständlich
- idiomatisch
- klein
- modular
- kommentiert, wo notwendig
- aber nicht überabstrahiert

sein.

Security-kritische Logik soll möglichst auf wenige, gut testbare Komponenten beschränkt bleiben.

Keine unnötigen Dependencies.

Wenn möglich:

```text
0 externe Runtime-Abhängigkeiten
```

---

# 42. Tests

Besonders die State Machine soll Unit Tests erhalten.

Mindestens folgende Szenarien testen.

## Test 1

```text
initial state
key absent
```

Erwartung:

```text
UNARMED
```

---

## Test 2

```text
UNARMED
key inserted
```

Erwartung:

```text
ARMED
```

---

## Test 3

```text
ARMED
key removed
```

Erwartung:

```text
PENDING_LOCK
```

---

## Test 4

```text
ARMED
key removed
2 seconds later key inserted
```

Erwartung:

```text
ARMED
no lock
```

---

## Test 5

```text
ARMED
key removed
3 seconds expire
key still absent
```

Erwartung:

```text
lock exactly once
UNARMED
```

---

## Test 6

```text
after app-triggered lock
user unlocks
key absent
```

Erwartung:

```text
UNARMED
no further lock
```

---

## Test 7

```text
app restart
key absent
```

Erwartung:

```text
UNARMED
```

---

## Test 8

```text
app restart
configured key present
```

Erwartung:

```text
ARMED
```

---

## Test 9

```text
wrong YubiKey inserted
```

Erwartung:

```text
no state change
```

---

## Test 10

```text
wrong YubiKey removed
```

Erwartung:

```text
no state change
```

---

## Test 11

```text
ARMED
configured key removed
USB reconnect happens during grace period
configured key is again present
```

Erwartung:

```text
no lock
ARMED
```

---

## Test 12

```text
lock backend unavailable
```

Erwartung:

```text
application must not arm
```

oder:

```text
state -> UNARMED
```

Es darf kein Logout oder anderer aggressiver Fallback stattfinden.

---

# 43. Manual Test Checklist

Vor einem Release testen:

```text
[ ] start without YubiKey
[ ] insert configured YubiKey
[ ] remove configured YubiKey
[ ] reconnect within 1 second
[ ] reconnect after 2.9 seconds
[ ] leave disconnected >3 seconds
[ ] unlock Mac without YubiKey
[ ] verify no lock loop
[ ] restart app without YubiKey
[ ] restart app with YubiKey
[ ] reboot Mac without YubiKey
[ ] reboot Mac with YubiKey
[ ] sleep with YubiKey attached
[ ] wake with YubiKey attached
[ ] sleep and remove YubiKey
[ ] USB-C dock reconnect
[ ] connect unrelated YubiKey
[ ] remove unrelated YubiKey
[ ] lock backend unavailable
[ ] monitor mode
```

---

# 44. UI-Farben und Accessibility

Farben sollen nicht die einzige Information transportieren.

Zusätzlich zur Farbe soll ein klarer Text vorhanden sein:

```text
Unarmed
Armed
Locking…
```

Damit bleibt der Status auch bei Farbsehschwächen verständlich.

---

# 45. Event-Reihenfolge und Race Conditions

USB-Notifications können schnell aufeinander folgen.

Beispiel:

```text
remove
insert
remove
```

Innerhalb weniger Millisekunden.

Die State Machine muss solche Events seriell verarbeiten.

Deshalb bevorzugt:

```swift
actor GuardStateMachine
```

Ein alter Timer darf niemals einen neueren Zustand überschreiben.

Jeder Pending-Lock-Task muss eindeutig zum State gehören, der ihn erzeugt hat.

Bei:

```text
PENDING_LOCK -> ARMED
```

muss der alte Lock-Task zuverlässig gecancelt werden.

---

# 46. Security Philosophy

Das Tool soll eher konservativ reagieren.

Bei einem Zweifel zwischen:

```text
Lock
```

und:

```text
Do nothing
```

soll in technisch unklaren Situationen bevorzugt **nicht gesperrt** werden.

Der Schutz soll nur aktiviert sein, wenn eindeutig festgestellt wurde:

```text
configured YubiKey is attached
```

Der Lock soll nur ausgelöst werden, wenn eindeutig festgestellt wurde:

```text
configured YubiKey was attached,
was removed,
3 seconds passed,
and the key is still absent.
```

---

# 47. Mögliche Projektstruktur

Beispielsweise:

```text
YubiKeyGuard/
├── App/
│   ├── YubiKeyGuardApp.swift
│   └── AppController.swift
│
├── Guard/
│   ├── GuardState.swift
│   ├── GuardEvent.swift
│   └── GuardStateMachine.swift
│
├── YubiKey/
│   ├── YubiKeyDevice.swift
│   ├── YubiKeyMonitor.swift
│   └── IOKitYubiKeyMonitor.swift
│
├── Lock/
│   ├── LockService.swift
│   └── MacOSLockService.swift
│
├── UI/
│   ├── StatusItemController.swift
│   ├── StatusMenu.swift
│   └── SettingsView.swift
│
├── Settings/
│   └── SettingsStore.swift
│
├── SSH/
│   └── SSHSessionService.swift
│
└── Tests/
    └── GuardStateMachineTests.swift
```

Dies ist nur ein Vorschlag.

Einfachheit ist wichtiger als das exakte Verzeichnislayout.

---

# 48. MVP

Die erste funktionsfähige Version soll bewusst klein bleiben.

## MVP muss enthalten

- Swift
- native macOS app
- Menüleisten-Icon
- IOKit-basierte Event-Erkennung
- Auswahl eines konkreten YubiKeys
- Identifikation anhand Seriennummer
- Zustände:
  - UNARMED
  - ARMED
  - PENDING_LOCK
- grün / gelb / rot Statusanzeige
- 3-Sekunden-Grace-Period
- cancellable Timer
- Revalidation vor Lock
- normaler macOS Screen Lock
- nach Lock -> UNARMED
- kein persistenter Armed-State
- Monitor Mode
- Logging
- State-Machine-Tests

## MVP noch nicht zwingend

- SSH kill
- aufwendige Preferences UI
- mehrere YubiKeys
- Auto Update
- notarized Release
- App Store Release

---

# 49. Spätere Erweiterungen

Mögliche spätere Features:

- mehrere erlaubte YubiKeys
- konfigurierbarer Lock Delay
- optional SSH-Prozesse schließen
- optional bestimmte SSH-Sessions schließen
- Notification vor Lock
- Sound optional
- Start at Login
- LaunchAgent/SMAppService
- signierte Releases
- notarized Releases
- Homebrew Cask
- optional CLI
- Event-History im UI

Diese Erweiterungen dürfen die zentrale Sicherheitsinvariante nicht verändern.

---

# 50. Wichtigster Acceptance Test

Dieser Ablauf muss immer funktionieren:

```text
1. Mac starten
2. Kein YubiKey angeschlossen
3. YubiKey Guard startet
4. Status ist GELB
5. Mac kann unbegrenzt normal benutzt werden
6. YubiKey anschließen
7. Status wird GRÜN
8. YubiKey entfernen
9. Status wird ROT
10. drei Sekunden warten
11. Mac wird gesperrt
12. YubiKey bleibt entfernt
13. Mac mit normalem Passwort oder Touch ID entsperren
14. Status ist GELB
15. Mac kann unbegrenzt weiter benutzt werden
16. keine erneute Sperre
17. YubiKey wieder anschließen
18. Status wird wieder GRÜN
```

Wenn insbesondere Schritt 13–16 nicht zuverlässig funktionieren, darf die Software nicht als sicher genug betrachtet werden.

---

# 51. Zusammenfassung für den Coding Agent

Baue eine kleine native macOS-Menüleisten-App in Swift.

Sie überwacht ereignisbasiert über IOKit einen konkreten YubiKey.

Die App beginnt grundsätzlich fail-open.

Ohne YubiKey:

```text
UNARMED
```

Wenn der konfigurierte YubiKey angeschlossen wird:

```text
ARMED
```

Wenn er entfernt wird:

```text
PENDING_LOCK
```

Dann 3 Sekunden warten.

Wenn er wieder angeschlossen wird:

```text
cancel lock
ARMED
```

Wenn er nach den 3 Sekunden weiterhin fehlt:

```text
lock macOS screen exactly once
UNARMED
```

Die Anwendung darf keinerlei Authentifizierungsabhängigkeit vom YubiKey erzeugen.

Der Benutzer muss den Rechner jederzeit ohne YubiKey starten, entsperren und verwenden können.

Keine PAM-Integration.

Kein Login-Hook.

Kein Root-Daemon.

Keine Sperrschleife.

Kein persistenter Armed-State.

Keine aggressive Fallback-Aktion.

Bei Unsicherheit: nicht sperren.

Das Projekt soll klein, verständlich, auditierbar und robust sein.
