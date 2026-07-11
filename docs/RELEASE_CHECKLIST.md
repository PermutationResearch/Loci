# Loci Release Checklist

Use this checklist before calling a build market-ready. A local ad-hoc DMG is useful for testing, but it is not a shippable public build.

## P0: Release Blockers

- Install a valid Apple Developer ID Application certificate on the release Mac.
- For GitHub releases, configure these Actions secrets:
  - `DEVELOPER_ID_P12_BASE64`
  - `DEVELOPER_ID_P12_PASSWORD`
  - `APPLE_ID`
  - `APPLE_APP_SPECIFIC_PASSWORD`
  - `APPLE_TEAM_ID`
  - `LOCI_X_CLIENT_ID` (optional)
- Package without ad-hoc signing:
  `scripts/package-beta.sh`
- Set the bundled X OAuth client ID for release builds:
  `LOCI_X_CLIENT_ID="..." scripts/package-beta.sh`
- Configure notarization:
  `xcrun notarytool store-credentials loci-notary`
- Produce a notarized build:
  `NOTARY_PROFILE=loci-notary REQUIRE_NOTARIZATION=1 scripts/package-beta.sh`
- Verify the DMG and ZIP:
  `hdiutil verify dist/Loci-0.1-b1.dmg`
  `unzip -t dist/Loci-0.1-b1.zip`
  `(cd dist && shasum -a 256 -c SHA256SUMS.txt)`
- Confirm the packaged executable contains both supported architectures:
  `lipo -archs dist/Loci.app/Contents/MacOS/Loci`
- Revoke and regenerate any X tokens that were pasted into chat, screenshots, logs, or local notes.
- Confirm the committed license is still the intended license for the release.
- Publish `docs/TELEMETRY_AND_PRIVACY.md` with the release.

## P0: X Sync Acceptance

- X Developer Portal callback URL is exactly:
  `http://127.0.0.1:17641/oauth/x/callback`
- The callback URL is not URL-encoded when entered in the portal.
- OAuth scopes include:
  `tweet.read users.read bookmark.read offline.access`
- Connect X from Settings, close the app, reopen it, and confirm the account remains connected.
- Run Sync Bookmarks and confirm real X bookmarks appear in the X Bookmarks library.
- Confirm refresh-token recovery works after the access token expires.
- Confirm auth failures show a useful repair action instead of disconnecting silently.

## P0: Product Quality Gates

- No blank white screen on launch or mode switch.
- No low-opacity placeholder state before the grid, canvas, inbox, or X bookmarks become usable.
- Inbox, All, Canvas, Grid, and Infinite mode switches feel instant with a large library.
- X bookmark cards show rich title, author, media preview when available, date, link, and source context.
- Scrolling works naturally inside the inbox and opened X/web previews.
- The app never asks for the Mac password repeatedly during normal X connect/sync.

## P0: Telemetry and Privacy Acceptance

- Telemetry is off by default on a clean install.
- Settings -> Privacy clearly explains what is collected and what is not collected.
- Settings -> Privacy can record a snapshot only after telemetry is enabled.
- The ingest endpoint must be HTTPS.
- The local telemetry queue can be cleared.
- Events include only aggregate counts and feature usage.
- Events never include file names, file paths, file contents, URLs, X bookmark text, prompts, model responses, graph node names, API keys, OAuth tokens, or local library paths.

## P1: Beta Readiness

- Run `swift build`.
- Run `swift test`.
- Test with 500, 1,000, and 5,000 references.
- Test first-run onboarding with an empty library.
- Test library storage in iCloud Drive, Dropbox, or Google Drive.
- Confirm the app handles missing files, moved library files, and sync conflicts gracefully.
- Review `docs/TELEMETRY_AND_PRIVACY.md` against the app behavior.
- Prepare App icon, screenshots, one-line positioning, landing page copy, and beta feedback channel.

## Ship Decision

Loci is market-ready only when the signed/notarized package, X sync, large-library performance, first-run onboarding, and privacy/security checks all pass on a clean Mac.

## Publish Through GitHub Actions

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Support/Loci.Info.plist`.
2. Merge the version change to `main` and confirm CI passes.
3. Create and push a matching tag, for example `v0.1` for version `0.1`.
4. The `Release macOS app` workflow builds a universal app, signs and notarizes it, staples the app and DMG, verifies Gatekeeper acceptance, generates checksums, and publishes the GitHub Release.
5. Download the release DMG on a different Mac and complete a clean install before announcing the release.
