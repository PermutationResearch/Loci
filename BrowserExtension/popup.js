import { getAuthToken, clearAuthToken, postToLoci } from "./auth.js";

const api = typeof browser !== "undefined" ? browser : chrome;
const lociEndpoint = "http://127.0.0.1:17641/references";

const elements = {
  pageTitle: document.getElementById("pageTitle"),
  note: document.getElementById("note"),
  status: document.getElementById("status"),
  save: document.getElementById("saveButton"),
  cancel: document.getElementById("cancelButton"),
  more: document.getElementById("moreButton"),
  xBookmarkRow: document.getElementById("xBookmarkRow"),
  bookmarkOnX: document.getElementById("bookmarkOnX")
};

let activePayload = {};

boot();

async function boot() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  activePayload = {
    url: tab?.url,
    title: tab?.title,
    source: isXURL(tab?.url) ? "x" : "browser-extension"
  };

  try {
    const response = await extractFromTab(tab);
    activePayload = { ...activePayload, ...response };
  } catch {
    // Pages such as browser settings cannot run content scripts; tab metadata is enough.
  }

  elements.pageTitle.textContent = activePayload.title || activePayload.url || "Current page";
  elements.xBookmarkRow.hidden = !isXURL(activePayload.url);
  elements.note.focus();
}

elements.cancel.addEventListener("click", () => window.close());

elements.more.addEventListener("click", async () => {
  elements.status.textContent = "Connecting...";
  try {
    await clearAuthToken();
    await getAuthToken();
    elements.status.textContent = "Connected to Loci.";
  } catch {
    elements.status.textContent = "Open Loci, then try again.";
  }
});

elements.save.addEventListener("click", async () => {
  elements.save.disabled = true;
  elements.status.textContent = "Saving...";

  const payload = {
    ...activePayload,
    note: elements.note.value.trim() || undefined,
    alsoBookmarkOnX: elements.bookmarkOnX.checked || undefined
  };

  try {
    await postToLoci(lociEndpoint, payload);
    if (payload.alsoBookmarkOnX) {
      await requestXBookmark();
    }
    elements.status.textContent = "Saved to Loci.";
    setTimeout(() => window.close(), 260);
  } catch (error) {
    elements.save.disabled = false;
    elements.status.textContent = "Open Loci, then try again.";
  }
});

async function extractFromTab(tab) {
  if (!tab?.id) {
    throw new Error("Missing active tab");
  }

  try {
    return await api.tabs.sendMessage(tab.id, { type: "loci-extract-page" });
  } catch {
    await api.scripting.executeScript({
      target: { tabId: tab.id },
      files: ["content.js"]
    });
    return api.tabs.sendMessage(tab.id, { type: "loci-extract-page" });
  }
}

async function requestXBookmark() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  try {
    await api.tabs.sendMessage(tab.id, { type: "loci-bookmark-x-post" });
  } catch {
  // The post still saved to Loci; native X bookmarking is best-effort.
  }
}

function isXURL(url = "") {
  return /^https:\/\/(x|twitter)\.com\//.test(url);
}
