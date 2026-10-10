# Security Policy

MacLatch is a security tool, so reports are very welcome.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private vulnerability reporting:
repository → **Security** → **Report a vulnerability**.

Please include the macOS version, the YubiKey model and firmware, and steps to reproduce.

## Especially relevant

- Any way the Mac could become **unusable without the YubiKey**: lock loops, lockouts,
  arming without the key present.
- Any way MacLatch could **arm or lock because of a different YubiKey**.
- A removal of the configured key that silently does not lock while MacLatch shows **Armed**.

## Out of scope

- Missing an automatic lock in an uncertain situation. This is deliberate fail-open behavior
  and is documented in the README.
- Attacks that require the user's login password or physical access to an already unlocked Mac
  before the key was removed.
