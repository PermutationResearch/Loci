# Contributing to Loci

Thanks for helping improve Loci. Contributions that make the app faster, clearer, safer, or easier to maintain are welcome.

## Before You Start

- Search existing issues before opening a new one.
- Use an issue for substantial features or architecture changes before investing in a large implementation.
- Keep pull requests focused. Unrelated cleanup makes behavior and privacy changes harder to review.
- Never include credentials, private library data, personal screenshots, generated release artifacts, or copied third-party code without a compatible license.

## Local Setup

Requirements:

- macOS 15 or newer
- Swift 6
- Xcode or Apple Command Line Tools

After cloning your fork:

```sh
cd Loci
cp .env.example .env
swift build
swift test
swift run Loci
```

The empty `.env` copy is optional. Do not commit it after adding local credentials.

## Development Principles

- Keep user data local by default.
- Preserve existing libraries and migration paths.
- Do not add telemetry that captures raw content or user identifiers.
- Keep network use explicit and tied to a user-configured integration.
- Keep expensive work outside SwiftUI view evaluation.
- Prefer targeted database observation and bounded in-memory projections.
- Use shared design, typography, and motion tokens instead of new literals.
- Add or update tests when changing import, sync, storage, telemetry, search, or graph behavior.

Read [Architecture](docs/ARCHITECTURE.md) before changing cross-cutting state, persistence, imports, or external integrations.

## Pull Requests

1. Create a branch from `main`.
2. Make the smallest coherent change that solves the problem.
3. Add tests for behavior that can be verified automatically.
4. Run the baseline checks:

   ```sh
   swift build
   swift test
   ```

5. Manually check affected UI states when applicable.
6. Explain user-visible behavior, compatibility risk, and follow-up work in the pull request.

UI pull requests should include before/after screenshots without private library content or local paths.

## High-Risk Areas

Changes in these areas require extra verification:

- X bookmark sync, OAuth state validation, and token refresh
- Local API authentication, origin checks, and remote access
- Library moves, schema migrations, and cloud-folder conflicts
- Grid, Canvas, and Infinity performance with thousands of references
- Telemetry allowlists and upload behavior
- LLM prompt, source-context, and output handling
- Packaging, signing, entitlements, and notarization

## Packaging a Local App

```sh
ALLOW_ADHOC=1 KEEP_APP=1 scripts/package-beta.sh
```

This creates a local testing build. Public distribution has additional signing and notarization requirements documented in the [Release Checklist](docs/RELEASE_CHECKLIST.md).

## Reporting Security Issues

Do not disclose vulnerabilities in a public issue. Follow [SECURITY.md](SECURITY.md).
