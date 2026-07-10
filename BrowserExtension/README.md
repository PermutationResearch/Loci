# Loci Save Browser Extension

Save what sparks you. Loci will remember.

The extension stays quiet in the browser until needed. It can save the current page, selected text, links, images, X posts, and a quick thought to the native Loci app through the local endpoint:

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

## Safari Path

This is written as a standard WebExtension. The next shipping step is to wrap it as a Safari Web Extension target in Xcode so it can be bundled with the macOS app and distributed through the normal Apple flow.
