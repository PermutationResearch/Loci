<p align="center">
  <img src="Sources/Loci/Resources/AppIcon.png" width="128" height="128" alt="Loci app icon">
</p>

<h1 align="center">Loci</h1>

<p align="center">
  A local-first visual library for everything worth finding again.
</p>

<p align="center">
  <strong>Native macOS · SwiftUI · Local-first · MIT licensed</strong>
</p>

Loci brings websites, images, screenshots, X bookmarks, notes, PDFs, and documents into one fast visual workspace. Browse references as a grid, arrange them spatially, search by text or appearance, and build a local Markdown knowledge vault without giving up ownership of your library.

> [!NOTE]
> Loci is pre-1.0 software. The source is ready for contributors, while public binary distribution still requires signed and notarized release artifacts.

## Why Loci

Saving is easy. Finding the useful thing again is the hard part.

Loci keeps references visible and connected instead of scattering them across browser bookmarks, Downloads, screenshots, notes, and open tabs. The library stays on your Mac by default and can be moved to a folder-backed location you control.

## Highlights

- Capture by drag and drop, paste, screenshot, URL, browser extension, X bookmark sync, or local API.
- Browse in Grid, Canvas, and Infinity modes designed for visual memory.
- Search by text, dominant color, and visual similarity.
- Preview images, websites, PDFs, Office documents, and text files.
- Extract text with Vision OCR and optional document-processing helpers.
- Turn rendered websites into clean local Markdown, with optional curl.md fallback for weak extractions.
- Build and export an Obsidian-compatible Markdown vault.
- Use local search without an LLM, or optionally connect OpenRouter or Ollama.
- Keep telemetry off by default; when enabled, only allowlisted aggregate events are recorded.

## Requirements

- macOS 15 or newer
- Swift 6
- Xcode or Apple Command Line Tools

Optional integrations have their own requirements. See [Integrations](docs/INTEGRATIONS.md).

## Install Loci

Signed and notarized builds are published on the [GitHub Releases page](https://github.com/PermutationResearch/Loci/releases). Download the DMG, open it, and drag **Loci** to the **Applications** shortcut. Release assets include `SHA256SUMS.txt` so you can verify the download with:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

If the Releases page has no DMG yet, a public binary has not been published; use the source build below in the meantime.

## Quick Start

```sh
git clone <your-fork-or-repository-url>
cd Loci
swift build
swift test
swift run Loci
```

For optional local configuration:

```sh
cp .env.example .env
```

Never commit the resulting `.env` file.

## Privacy Model

Loci is local-first:

- Libraries, extracted text, thumbnails, and the Markdown vault remain local unless you deliberately use an external integration.
- X OAuth tokens are stored in the macOS Keychain.
- The local API binds to loopback by default and protects sensitive routes with a bearer token.
- Telemetry is disabled by default and excludes file contents, URLs, bookmark text, prompts, model responses, tokens, and local paths.
- LLM features are optional. Source text is sent only when you choose a configured external provider.
- Local website extraction is enabled by default and can be disabled; the optional curl.md fallback sends an eligible website URL only after you enable it.

Read the complete [Telemetry and Privacy](docs/TELEMETRY_AND_PRIVACY.md) and [Security](SECURITY.md) policies.

## Browser Extension

The unpacked Chrome/Edge WebExtension lives in [`BrowserExtension/`](BrowserExtension/). With Loci running:

1. Open `chrome://extensions`.
2. Enable Developer Mode.
3. Choose **Load unpacked**.
4. Select the `BrowserExtension` folder.

The extension talks only to Loci's local endpoint by default. See the [extension guide](BrowserExtension/README.md).

## Project Map

```text
.
├── Sources/Loci/       Native macOS application
├── Tests/LociTests/    Swift test suite
├── BrowserExtension/   Chrome and Edge WebExtension
├── Support/            Bundle metadata and icon sources
├── scripts/            Packaging and optional helper tools
├── docs/               Architecture, privacy, integrations, and releases
└── Package.swift       Swift package definition
```

Start with [Architecture](docs/ARCHITECTURE.md) for system boundaries or [Project Structure](docs/PROJECT_STRUCTURE.md) for the complete file map.

## Development

```sh
swift build
swift test
```

Create an ad-hoc local app package:

```sh
ALLOW_ADHOC=1 KEEP_APP=1 scripts/package-beta.sh
```

Signed and notarized distribution is documented in the [Release Checklist](docs/RELEASE_CHECKLIST.md).

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md), follow the [Code of Conduct](CODE_OF_CONDUCT.md), and use the issue templates for reproducible bug reports and focused proposals.

Security vulnerabilities should be reported privately according to [SECURITY.md](SECURITY.md), never through a public issue.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Integrations](docs/INTEGRATIONS.md)
- [Telemetry and Privacy](docs/TELEMETRY_AND_PRIVACY.md)
- [Project Structure](docs/PROJECT_STRUCTURE.md)
- [Release Checklist](docs/RELEASE_CHECKLIST.md)
- [Support](SUPPORT.md)

## License

Loci is available under the [MIT License](LICENSE).
