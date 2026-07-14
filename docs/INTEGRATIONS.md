# Integrations

Loci is local-first, but it has several integrations that make capture and rediscovery easier.

## Configuration Sources

Loci can read config values from:

1. Process environment variables.
2. `.env` in the current working directory.
3. `loci.env` in the current working directory.
4. `.env` or `loci.env` inside the active library root.
5. Selected UserDefaults keys.

Start with:

```sh
cp .env.example .env
```

Never commit real credentials.

## Browser Extension

Folder:

```txt
BrowserExtension/
```

Local endpoint:

```txt
POST http://127.0.0.1:17641/references
```

The extension can save:

- Current page title and URL.
- Selected text.
- Links.
- Images.
- X posts.
- Optional notes.
- Favicon and Open Graph image URLs when available.

### Load In Chrome Or Edge

1. Build and run Loci.
2. Open `chrome://extensions`.
3. Enable Developer Mode.
4. Choose `Load unpacked`.
5. Select `BrowserExtension`.

## Local API

Loci starts a local HTTP API on port `17641`.

Default behavior:

- Loopback-only.
- Request body limit: 5 MB.
- Protected routes require `Authorization: Bearer <token>`.
- CORS is restricted to allowed local/browser-extension origins.

Remote access is off by default. To opt in:

```txt
LOCI_REMOTE_API=1
```

Use that only for trusted local development.

Useful routes:

```txt
GET  /health
GET  /pairing-token
POST /references
POST /compile/run
POST /compile/recompile-all
POST /x/bookmarks/sync
GET  /x/diagnostics
POST /ask
GET  /export/obsidian
POST /export/obsidian
GET  /references
GET  /references/stats
GET  /tags
GET  /review/due
GET  /review/stats
GET  /timeline
GET  /patterns
GET  /wiki/backlinks
```

The OAuth callback route is intentionally public on loopback:

```txt
GET /oauth/x/callback
```

It validates the OAuth state before exchanging the code.

## X Bookmark Sync

Loci uses OAuth 2.0 with PKCE.

Required X app setup:

```txt
App type: Native app or public client
Callback URI / Redirect URL: http://127.0.0.1:17641/oauth/x/callback
Website URL: http://127.0.0.1:17641
Scopes: tweet.read users.read bookmark.read offline.access
```

Do not URL-encode the callback URL in the X Developer Portal.

Correct:

```txt
http://127.0.0.1:17641/oauth/x/callback
```

Wrong:

```txt
http%3A%2F%2F127.0.0.1%3A17641%2Foauth%2Fx%2Fcallback
```

Local config:

```txt
LOCI_X_CLIENT_ID=YOUR_OAUTH2_CLIENT_ID
```

Release packaging:

```sh
LOCI_X_CLIENT_ID="YOUR_OAUTH2_CLIENT_ID" scripts/package-beta.sh
```

Security notes:

- Do not use an API key as the OAuth 2.0 client ID.
- Do not commit access tokens or refresh tokens.
- Tokens are stored in the macOS Keychain.
- Revoke leaked tokens in the X Developer Portal.

## Library Folder Sync

Default library location:

```txt
~/Library/Application Support/Loci
```

Portable library name:

```txt
Loci Library.atlaslibrary
```

The library can be placed in iCloud Drive, Dropbox, Google Drive, OneDrive, or a local folder.

Provider sync is outside the app's control, so test:

- Two machines editing the same library.
- Missing files.
- Moved folders.
- Sync conflicts.
- Offline edits.

## LLM Support

LLM support is optional.

OpenRouter:

```txt
OPENROUTER_API_KEY=
OPENROUTER_MODEL=openai/gpt-4o-mini
```

Ollama/local model:

```txt
LOCI_LLM_MODEL=
```

Loci also tries local vault search. If no LLM is configured, local search still works where possible.

Privacy rule:

- LLM workflows may send selected source text to the configured provider.
- Telemetry must never record prompts, model responses, source text, wiki content, or generated summaries.

## Document Extraction

Optional helper variables:

```txt
LOCI_PYTHON=
LOCI_EXTRACT_SCRIPT=
LOCI_LIBREOFFICE=
DOCLING_LIBREOFFICE_CMD=
```

The bundled extraction script lives in:

```txt
Sources/Loci/Resources/scripts/
```

## Website Markdown Extraction

When automatic extraction is enabled (the default), Loci locally renders imported websites with WebKit, removes common navigation and page chrome, selects the strongest content region, and converts semantic elements to Markdown before compilation. You can also start extraction explicitly. Local extraction is always the primary extraction path.

The raw package records:

- `downloaded-page.html` or `captured-page.html` — original response or browser-captured HTML for audit and reprocessing.
- `local-extracted.md` — the cleaned local candidate.
- `local-extraction-meta.json` — selection, word count, link density, quality score, removed-element count, and warnings.
- `extracted.md` — the source selected for downstream compilation.

Loci can optionally use [curl.md](https://curl.md) when the local result is missing or below the quality threshold. Enable it under **Settings → Extraction → Website Markdown**, or configure:

```txt
LOCI_CURLMD_ENABLED=1
CURLMD_API_KEY=
```

The API key is optional. Keys entered in Settings are stored in macOS Keychain; environment-provided keys remain in the developer's local environment. Authenticated requests receive higher service limits. `LOCI_CURLMD_BASE_URL` can point development builds at a self-hosted endpoint.

Behavior and privacy boundaries:

- Local WebKit is the primary extractor whenever website extraction runs, and it stays on the Mac.
- The curl.md fallback is off by default.
- Sends the imported URL to curl.md only after opt-in, only when the local result is weak, and only when it passes Loci's local privacy checks.
- Saves returned content as `raw/<reference>/extracted.md` and response metadata as `curlmd-meta.json`.
- Records a token-free `curlmd-error.txt` diagnostic when the service fails, then continues locally.
- Never sends localhost, single-label or common private-use hostnames, `.local`, literal IPv6, loopback, link-local, or non-public literal IPv4 targets.
- Never sends URLs containing common credential-like query parameters or token-bearing fragments.
- Does not resolve arbitrary hostnames before fallback; a hostname whose DNS later points to a private address is not classified locally.
- Falls back to Loci's existing local extraction when curl.md is unavailable or rejects a request.
- curl.md may retain URLs and request metadata according to its [privacy policy](https://curl.md/docs/privacy).

## Telemetry

Telemetry is off by default.

Settings can enable:

- Local event queue.
- Optional HTTPS ingest endpoint.

Allowed data is aggregate only. See [Telemetry and Privacy](TELEMETRY_AND_PRIVACY.md).

## Packaging

Local ad-hoc build:

```sh
ALLOW_ADHOC=1 scripts/package-beta.sh
```

Developer ID signed build:

```sh
CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package-beta.sh
```

Notarized build:

```sh
xcrun notarytool store-credentials loci-notary
NOTARY_PROFILE=loci-notary REQUIRE_NOTARIZATION=1 scripts/package-beta.sh
```

Release artifacts are written to `dist/`.
