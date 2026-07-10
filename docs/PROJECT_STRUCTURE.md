# Project Structure

This document explains where things live in the Loci repository.

## Top Level

```txt
.
├── Sources/Loci/                 # native macOS app
├── Tests/LociTests/              # Swift tests
├── BrowserExtension/             # Chrome/Edge extension
├── Support/                      # app bundle support files
├── scripts/                      # build, extraction, and vault helper scripts
├── docs/                         # product, release, privacy, and setup docs
├── Package.swift                 # Swift package manifest
├── Package.resolved              # resolved Swift package versions
├── README.md                     # GitHub landing page
├── LICENSE                       # MIT license
├── CONTRIBUTING.md               # contributor guide
└── SECURITY.md                   # security policy
```

## App Source

```txt
Sources/Loci/
├── LociApp.swift                 # app entry point and window setup
├── ContentView.swift             # main app shell and focused preview
├── ReferenceViews.swift          # grid, canvas, infinity, tiles, gestures
├── Graphics.swift                # thumbnail views and image cache
├── AppMotion.swift               # shared animation constants
├── Models.swift                  # library model, import coordination, graph helpers
├── PersistentStore.swift         # SQLite/GRDB persistence
├── LibraryLocation.swift         # local/portable library location management
├── LocalReferenceAPIServer.swift # loopback API for extension and integrations
├── XOAuthManager.swift           # X OAuth 2.0, token storage, bookmark sync
├── SettingsView.swift            # settings, privacy, integrations, X setup
├── LociTelemetry.swift           # opt-in allowlisted telemetry
├── LociImageLoader.swift         # bounded image decoding/downsampling
├── WebsiteSnapshotRenderer.swift # WebKit snapshot rendering
├── LociWebSession.swift          # shared WebKit request/session config
├── FileSystemWorkspaceView.swift # file browser workspace
├── VaultWorkspaceView.swift      # API/library workspace
├── MarkdownVault.swift           # Markdown vault writing and indexing
├── WikiCompiler.swift            # source package and wiki compilation helpers
├── LLMWikiCompiler.swift         # optional LLM wiki synthesis
├── VaultChatContext.swift        # local search context for question answering
├── VisualSearch.swift            # Vision feature-print search
├── ColorSearch.swift             # dominant color extraction/search
├── VisionOCR.swift               # OCR over image/PDF inputs
├── DocumentExtractor.swift       # document extraction process bridge
├── DocumentPreviewConverter.swift# document preview conversion
├── ExtendDocumentViewer.swift    # native preview/document viewer
├── GraphExplorerView.swift       # graph view
├── TimelineView.swift            # timeline workspace
├── ReviewQueueView.swift         # review queue UI
├── ReviewScheduler.swift         # review scheduling logic
├── AutoRulesEngine.swift         # import rules
├── AutoRulesView.swift           # rules UI
├── CapabilitiesView.swift        # capabilities/action surface
├── PatternLibraryView.swift      # prompt/pattern UI
├── PromptLibrary.swift           # built-in patterns
├── BatchOperations.swift         # batch library operations
├── BacklinksEngine.swift         # backlinks analysis
├── BacklinksPanel.swift          # backlinks UI
├── ScreenshotCapture.swift       # screenshot import
├── DocumentAnalytics.swift       # analytics derived from local docs
├── TableObserver.swift           # database change observation
├── VaultExporter.swift           # Obsidian export
├── XURLHelpers.swift             # X URL parsing helpers
└── Resources/                    # bundled app assets and helper scripts
```

## Browser Extension

```txt
BrowserExtension/
├── manifest.json
├── background.js
├── content.js
├── popup.html
├── popup.css
├── popup.js
├── auth.js
└── README.md
```

The extension saves pages, links, images, selected text, X posts, and notes to the native app through the local API.

## Scripts

```txt
scripts/
├── package-beta.sh       # build, sign, zip, DMG, notarize
├── loci-extract         # extraction wrapper
├── loci-extract.py      # extraction implementation
├── loci-vault-search    # vault search helper
└── loci-marp-render     # Marp render helper
```

`scripts/package-beta.sh` is the release packaging entry point.

## Docs

```txt
docs/
├── ARCHITECTURE.md
├── INTEGRATIONS.md
├── OPEN_SOURCE_READINESS.md
├── PROJECT_STRUCTURE.md
├── LOCI_BRANDING_AND_MARKETING.md
├── RELEASE_CHECKLIST.md
└── TELEMETRY_AND_PRIVACY.md
```

Documentation should be useful to contributors and maintainers. Do not put secrets, local library contents, or raw user data in docs.

## Generated Or Local-Only Paths

These paths are ignored for open-source publication:

```txt
.build/
build/
dist/
outputs/
tmp/
work/
external/
.env
loci.env
*.atlaslibrary/
```

Release artifacts belong in GitHub Releases, not in normal source commits.
