# AGENTS.md

This repository contains a small native macOS security utility that locks the Mac when a configured YubiKey is removed.

Read `PROJECT.md` before making architectural or behavioral changes.

## Core Security Invariant

The most important rule in this project is:

> A YubiKey may arm the application. The absence of a YubiKey must never arm the application.

The user must always be able to:

- boot the Mac without a YubiKey
- log in without a YubiKey
- unlock the Mac without a YubiKey
- use the Mac indefinitely without a YubiKey

This application must never make the YubiKey a requirement for authentication.

Do not implement:

- PAM integration
- loginwindow modification
- FileVault integration
- Smart Card login enforcement
- password modification
- root login hooks
- privileged authentication components

---

## Required State Model

Use an explicit state machine.

The primary states are:

```text
UNARMED
ARMED
PENDING_LOCK
```

Expected transitions:

```text
UNARMED
  |
  | configured YubiKey inserted
  v
ARMED
  |
  | configured YubiKey removed
  v
PENDING_LOCK
  |
  |-- key returns within the grace period --> ARMED
  |
  |-- grace period expires
          |
          v
      revalidate device
          |
          |-- present --> ARMED
          |
          |-- absent --> lock Mac exactly once
                            |
                            v
                         UNARMED
```

After an application-triggered lock, the state must always become:

```text
UNARMED
```

This prevents lock loops.

Never persist `ARMED` or `PENDING_LOCK`.

---

## Fail-Open Behavior

When the application cannot determine the device state reliably, prefer:

```text
UNARMED
```

When the lock backend is unavailable, do not arm.

When an unexpected error occurs, do not use aggressive fallback actions.

Never replace screen locking with:

- logout
- shutdown
- reboot
- killing `loginwindow`
- killing WindowServer

The worst acceptable failure mode is:

> The automatic lock does not occur.

An acceptable implementation must not create a situation where the user becomes repeatedly or permanently locked out.

---

## Device Monitoring

Do not implement continuous polling.

Do not periodically run:

```text
ioreg
system_profiler
```

Use event-driven macOS APIs, preferably IOKit notifications.

Monitor the physical USB device rather than individual YubiKey interfaces where possible.

YubiKeys are composite USB devices and may expose:

- HID
- FIDO
- OTP
- CCID

An interface reset must not automatically be treated as physical device removal.

---

## YubiKey Identification

The application should monitor one explicitly configured YubiKey.

Prefer identification using:

- Yubico vendor ID
- device serial number
- optional product ID

Known Yubico USB vendor ID:

```text
0x1050
```

Other YubiKeys must not affect the state machine.

---

## Removal Delay

The removal grace period is user-configurable. The default is:

```text
3 seconds
```

The user can choose from a fixed set of values (currently 0, 1, 3, 5, 10 and 15 seconds).
Persisting this setting is fine; it is a preference, not security state.

Whatever the value, including 0, the flow stays the same: `PENDING_LOCK`, timer,
final revalidation, at most one lock, then `UNARMED`. A shorter delay only tolerates
fewer USB or dock resets; it must never weaken the fail-open or anti-lock-loop rules.

A changed delay applies to the next removal. A running grace period keeps its delay.

Use a cancellable monotonic timer.

Prefer Swift Concurrency and `ContinuousClock`.

Do not base the timeout on wall-clock time.

Before locking, perform one final device revalidation.

This one-time revalidation is allowed and is not considered polling.

---

## Concurrency

USB events and timer expiry may occur concurrently.

The state machine must serialize these events safely.

Prefer:

```swift
actor GuardStateMachine
```

Do not implement the security state using a collection of loosely related booleans.

Prefer an explicit enum.

Old pending lock tasks must never be able to trigger after the state has already changed.

Always cancel obsolete pending tasks.

---

## Architecture

Keep security-sensitive components small and independent.

Preferred structure:

```text
YubiKeyMonitor
      |
      v
GuardStateMachine
      |
   +--+-----------+
   |              |
   v              v
LockService      UI
```

Additional components may include:

```text
SettingsStore
StatusItemController
SSHSessionService
```

The state machine should be testable without AppKit or real USB hardware.

---

## macOS UI

This is a native macOS menu bar application.

Prefer:

- Swift
- AppKit
- `NSStatusItem`
- SF Symbols
- native system APIs

Avoid:

- Electron
- Node.js runtime
- Python runtime
- web-based UI frameworks

The app should not require a Dock icon.

Required visual states:

```text
yellow = UNARMED
green  = ARMED
red    = PENDING_LOCK
```

Color must not be the only status indicator.

Also display text such as:

```text
Unarmed
Armed
Locking…
```

---

## Permissions

Keep permissions minimal.

Avoid requiring:

- root
- Full Disk Access
- Accessibility
- Screen Recording
- Input Monitoring
- kernel extensions
- system extensions

Do not introduce a privileged helper unless there is an extremely strong technical reason.

If a new permission is proposed, document why it is required before implementing it.

---

## Networking and Telemetry

The core application must work fully offline.

Do not add:

- analytics
- telemetry
- remote logging
- tracking
- cloud services
- unnecessary network access

---

## Dependencies

Prefer zero third-party runtime dependencies.

Use Apple frameworks where practical.

Do not add a dependency for functionality that can be implemented clearly with a small amount of native Swift.

Security-sensitive code should remain easy to audit.

---

## Logging

Use Apple unified logging where useful.

Logging may include:

- state transitions
- device insertion/removal
- timer creation/cancellation
- revalidation
- lock attempts
- errors

Do not log:

- secrets
- PINs
- credentials
- private keys

Avoid unnecessarily exposing the full YubiKey serial number in user-facing logs.

---

## SSH Handling

Closing SSH sessions is an optional feature and not part of the core security invariant.

If implemented:

- it must default to disabled
- use graceful termination first
- prefer `SIGTERM`
- SSH termination failures must not block the normal screen lock
- document that active SSH/SCP/SFTP work may be interrupted

Do not make the initial implementation more complex merely to support SSH process termination.

---

## Monitor Mode

A non-destructive monitor/test mode is strongly encouraged.

In monitor mode:

- USB events are processed normally
- state transitions occur normally
- planned lock actions are logged
- the Mac is not actually locked

Use this mode when validating behavior around:

- Sleep/Wake
- USB-C hubs
- Thunderbolt docks
- USB resets
- rapid disconnect/reconnect
- app restarts

---

## Tests

Do not change the security behavior without corresponding tests.

At minimum ensure tests cover:

```text
start without key -> UNARMED

insert configured key -> ARMED

remove configured key -> PENDING_LOCK

reinsert before timeout -> ARMED, no lock

timeout + key absent -> lock exactly once -> UNARMED

unlock while key remains absent -> stays UNARMED

app restart without key -> UNARMED

wrong YubiKey insertion/removal -> ignored

lock backend unavailable -> must not arm
```

The following behavior must never regress:

```text
lock
-> user unlocks without YubiKey
-> application remains UNARMED
-> no lock loop
```

---

## Code Style

Prefer code that is:

- small
- explicit
- idiomatic Swift
- readable
- testable
- minimally abstracted

Avoid cleverness in security-sensitive logic.

Prefer obvious code over compressed code.

Do not silently change security behavior while refactoring.

---

## Before Making Security-Relevant Changes

Before changing any of the following:

- state transitions
- YubiKey detection
- device identity
- lock behavior
- persistence
- startup behavior
- Sleep/Wake behavior

verify the change against the core invariant:

> The Mac must always remain usable without the YubiKey.

If a proposed design conflicts with this invariant, do not implement it.

---

## Definition of Done

A change affecting the core workflow is only complete when:

- the project builds
- relevant tests pass
- no persistent armed state exists
- no authentication dependency on the YubiKey was introduced
- removal still uses a cancellable grace period (default 3 seconds)
- final device revalidation still occurs before locking
- an application-triggered lock ends in `UNARMED`
- unlocking without the YubiKey cannot create a lock loop

When in doubt, preserve simplicity and fail open.
