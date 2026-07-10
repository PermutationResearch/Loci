import { getAuthToken, clearAuthToken, postToLoci } from "./auth.js";

const api = typeof browser !== "undefined" ? browser : chrome;
const lociEndpoint = "http://127.0.0.1:17641/references";

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.create({
    id: "save-page",
    title: "Save page to Loci",
    contexts: ["page"]
  });

  api.contextMenus.create({
    id: "save-selection",
    title: "Save selection to Loci",
    contexts: ["selection"]
  });

  api.contextMenus.create({
    id: "save-image",
    title: "Save image to Loci",
    contexts: ["image"]
  });

  api.contextMenus.create({
    id: "save-link",
    title: "Save link to Loci",
    contexts: ["link"]
  });
});

api.contextMenus.onClicked.addListener(async (info, tab) => {
  const payload = {
    url: info.linkUrl || info.srcUrl || tab?.url,
    title: info.selectionText || tab?.title || info.linkUrl || info.srcUrl,
    selectedText: info.selectionText,
    source: contextSource(info)
  };

  try {
    await postToLoci(lociEndpoint, payload);
  } catch {
    // Context menu saves are fire-and-forget; popup saves surface errors to the user.
  }
});

function contextSource(info) {
  if (info.srcUrl) return "browser-image";
  if (info.linkUrl) return "browser-link";
  if (info.selectionText) return "browser-selection";
  return "browser-context-menu";
}
