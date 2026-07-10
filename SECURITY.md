# Security Policy

## Supported Versions

Loci is pre-1.0. The current `main` branch is the only supported source version until versioned releases are published.

## Reporting a Vulnerability

Please do not open a public issue for secrets, token leakage, local API bypasses, OAuth problems, or privacy bugs.

Use GitHub's **Report a vulnerability** button on the repository Security page. It creates a private advisory visible only to repository maintainers.

If private vulnerability reporting is temporarily unavailable, open a public issue containing only the words “private security contact requested.” Do not include technical details, logs, proof-of-concept code, tokens, or affected user data. A maintainer will establish a private channel.

Include the affected component, impact, reproduction conditions, and a proposed mitigation when possible. You should receive an acknowledgement within seven days.

## Security Model

- The local API listens on port `17641`.
- The local API is loopback-only by default.
- Remote API access requires explicit opt-in with `LOCI_REMOTE_API=1` or the matching user setting.
- Protected local API routes require a bearer token.
- X access and refresh tokens are stored in the macOS Keychain.
- Telemetry is off by default and uses an allowlist.
- Raw user content must not be sent through telemetry.

## Before Public Release

- Rotate any tokens that appeared in chat, screenshots, logs, or local notes.
- Verify `.env`, `loci.env`, Keychain exports, local libraries, and release artifacts are not committed.
- Verify the shipped app is signed and notarized.
- Verify the OAuth callback URL and scopes from a fresh X Developer app.
- Enable GitHub private vulnerability reporting in repository settings.
