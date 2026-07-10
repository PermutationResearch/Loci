# Telemetry and Privacy

Loci is local-first. User libraries, files, extracted text, X bookmark content, graph nodes, prompts, and model answers stay on the user's computer unless the user deliberately sends them to an external service such as OpenRouter or X OAuth.

## Default

Telemetry is off by default.

Users can enable it in Settings -> Privacy. A production release can set an HTTPS ingest endpoint in the same panel.

## What Telemetry Can Collect

When enabled, Loci records only aggregate product analytics:

- Anonymous install ID
- App version and build
- Launch and feature usage events
- Active reference count, collection count, tag count, asset count, import job count
- Storage size totals for database, originals, and thumbnails
- Import source and import count
- X bookmark sync totals: total, imported, updated
- Graph scale: node count and edge count
- LLM usage metadata: success/failure, whether an LLM was used, source count, history turn count, provider family, write count

## What Telemetry Must Not Collect

Loci telemetry must not collect:

- File names, file paths, file contents, extracted text, OCR text, or thumbnails
- Website URLs or page HTML
- X bookmark text, author handles, media URLs, access tokens, refresh tokens, or OAuth client secrets
- User prompts, chat history text, model responses, wiki content, or generated summaries
- Graph node names, graph edge labels, collection IDs, note text, tags created by users, or local library paths

## Model Improvement Data

Aggregate telemetry can show which product areas matter and where LLM workflows fail. It is not a training dataset.

If Loci later needs model-improvement data, add a separate explicit export flow that lets users review the exact records before sharing them. Do not reuse anonymous telemetry for raw model training data.

## Implementation

Telemetry events are built through `LociTelemetry`, which allowlists property names before writing or uploading an event. Events are stored locally as JSON Lines at:

`~/Library/Application Support/Loci/Telemetry/events.jsonl`

Only HTTPS endpoints are accepted for upload.
