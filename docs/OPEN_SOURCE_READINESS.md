# Open Source Readiness

Loci is now structured for a public source release.

This document separates source readiness from binary release readiness. The source can be published before a signed/notarized app is available, but the README and release notes should be clear about that distinction.

## Source Release Ready

These pieces are in place:

- `README.md` explains the product, build flow, integrations, privacy model, and release status.
- `LICENSE` is present.
- `.gitignore` excludes local builds, release artifacts, local config, and runtime data.
- `.env.example` documents local configuration without secrets.
- `CONTRIBUTING.md` explains setup and pull request expectations.
- `SECURITY.md` explains the local API, OAuth, telemetry, and vulnerability reporting.
- `CODE_OF_CONDUCT.md` sets basic project behavior expectations.
- `.github/ISSUE_TEMPLATE/` includes bug, feature, and privacy/security templates.
- `docs/PROJECT_STRUCTURE.md` explains the repository layout.
- `docs/INTEGRATIONS.md` explains browser extension, X OAuth, local API, LLM, telemetry, and packaging.
- `docs/TELEMETRY_AND_PRIVACY.md` documents opt-in telemetry boundaries.
- `docs/RELEASE_CHECKLIST.md` documents public binary release gates.

## Still Required Before Public Binary Release

- Build with a valid Apple Developer ID Application certificate.
- Notarize and staple the DMG.
- Publish checksums for ZIP/DMG artifacts.
- Verify X OAuth from a fresh X Developer app and fresh user account.
- Verify first-run onboarding on a clean Mac.
- Verify large-library behavior at 500, 1,000, and 5,000 references.
- Verify iCloud Drive, Dropbox, Google Drive, and OneDrive library folders.
- Confirm no credentials, tokens, private screenshots, local files, or user data are in the public repository.
- Add public screenshots and a short demo video.
- Decide whether auto-update support is needed before the first public binary release.

## Do Not Commit

- `.env` or `loci.env`
- X access tokens or refresh tokens
- OpenRouter keys
- Local library folders
- `Loci.sqlite`
- Telemetry event queues
- `dist/`, `build/`, `outputs/`, `.build/`
- Screenshots containing OAuth URLs, bearer tokens, file paths, or private bookmarks

## Suggested GitHub Release Shape

For a first beta release:

```txt
Loci 0.1 beta 1

Artifacts:
- Loci-0.1-b1.dmg
- Loci-0.1-b1.zip
- SHA256SUMS.txt

Notes:
- Native macOS app for local-first visual reference libraries.
- Includes browser extension capture and X bookmark sync.
- Telemetry is off by default.
- X sync requires a user-provided X OAuth 2.0 client ID unless bundled by the release maintainer.
- This is a beta. Back up your library before testing cloud-folder sync.
```
