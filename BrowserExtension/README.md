# Loci Save Browser Extension

Save what sparks you. Loci will remember.

The extension stays inactive until you open its popup or choose a **Save to Loci** context-menu action. It can then save the current page, selected text, links, images, X posts, and a quick thought to the native Loci app through the local endpoint:

```txt
POST http://127.0.0.1:17641/references
```

## Load in Chrome or Edge

1. Build and run Loci.
2. Open `chrome://extensions`.
3. Enable Developer Mode.
4. Choose **Load unpacked**.
5. Select this `BrowserExtension` folder.

## What It Captures

- Page URL, title, favicon URL, Open Graph image URL, selected text, and limited page HTML.
- X/Twitter post URL and post text when saving from the feed.
- Optional note from the popup.
- Context menu saves for pages, links, images, and selected text.
- Optional best-effort X bookmark click when the checkbox is enabled.

## Permissions And Privacy

- **Active tab** — reads the page you explicitly save, not every page you visit.
- **Context menus** — adds page, selection, image, and link capture actions.
- **Scripting** — injects the extraction script only after an explicit save action.
- **Storage** — keeps the local pairing token needed to reach Loci.
- **Loopback host access** — sends captures only to Loci at `127.0.0.1:17641` or `localhost:17641`.
- **X/Twitter host access** — enables optional X post and bookmark capture when you invoke it.

The extension does not upload captures to a Loci-operated cloud service. External URLs and page content are sent only to the locally running Loci app; any later external processing is controlled by the app's configured integrations.

## Safari Path

This is written as a standard WebExtension. The next shipping step is to wrap it as a Safari Web Extension target in Xcode so it can be bundled with the macOS app and distributed through the normal Apple flow.
