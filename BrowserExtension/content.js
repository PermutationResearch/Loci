let lastHoveredPost = null;
const extAPI = typeof browser !== "undefined" ? browser : chrome;

document.addEventListener("pointerover", event => {
  const post = event.target?.closest?.('article[data-testid="tweet"]');
  if (post) {
    lastHoveredPost = post;
  }
}, { passive: true });

extAPI.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.type === "loci-extract-page") {
    sendResponse(extractReferencePayload());
    return true;
  }

  if (message.type === "loci-bookmark-x-post") {
    bookmarkCurrentXPost();
    sendResponse({ ok: true });
    return true;
  }
});

function extractReferencePayload() {
  const selection = window.getSelection()?.toString().trim();
  const xPost = isXPage() ? extractXPost(selection) : null;
  const metadata = extractMetadata();
  const articleMarkdown = xPost?.threadText || extractArticleMarkdown();
  const imageURLs = extractImageURLs(metadata);
  const transcriptText = extractTranscriptText();
  const autoTags = detectAutoTags(metadata, articleMarkdown);

  return {
    url: xPost?.url || location.href,
    title: xPost?.title || metadata.title || document.title,
    selectedText: selection || xPost?.text || undefined,
    pageHTML: document.documentElement?.outerHTML?.slice(0, 120000),
    articleMarkdown,
    transcriptText,
    imageURLs,
    autoTags,
    source: xPost ? "x-post" : "browser-extension",
    faviconURL: metadata.faviconURL,
    ogImageURL: metadata.ogImageURL
  };
}

function extractMetadata() {
  const title =
    readMeta('meta[property="og:title"]') ||
    readMeta('meta[name="twitter:title"]') ||
    document.title;

  const ogImageURL =
    readMeta('meta[property="og:image"]') ||
    readMeta('meta[name="twitter:image"]');

  const favicon = document.querySelector('link[rel~="icon"], link[rel="apple-touch-icon"]');
  const faviconURL = favicon?.href ? new URL(favicon.href, location.href).href : `${location.origin}/favicon.ico`;

  return { title, faviconURL, ogImageURL };
}

function readMeta(selector) {
  return document.querySelector(selector)?.content?.trim();
}

function extractXPost(selection) {
  const post = postNearSelection() || lastHoveredPost || document.querySelector('article[data-testid="tweet"]');
  if (!post) {
    return null;
  }

  const text = post.innerText
    .split("\n")
    .filter(Boolean)
    .slice(0, 12)
    .join(" ")
    .trim();

  const statusLink = [...post.querySelectorAll('a[href*="/status/"]')]
    .map(anchor => anchor.href)
    .find(Boolean);

  const author = post.querySelector('[data-testid="User-Name"]')?.innerText
    ?.split("\n")
    ?.find(Boolean)
    ?.trim();

  return {
    url: statusLink || location.href,
    title: author ? `${author} on X` : "Saved X Post",
    text: selection || text,
    threadText: extractVisibleXThread(selection)
  };
}

function extractArticleMarkdown() {
  const root =
    document.querySelector("article") ||
    document.querySelector("main") ||
    document.body;
  if (!root) {
    return undefined;
  }

  const title = readMeta('meta[property="og:title"]') || document.title;
  const lines = [`# ${cleanText(title)}`, ""];
  const selectors = "h1,h2,h3,p,li,blockquote,pre,code";
  for (const node of [...root.querySelectorAll(selectors)].slice(0, 260)) {
    const text = cleanText(node.innerText || node.textContent || "");
    if (!text || text.length < 2) continue;
    const tag = node.tagName.toLowerCase();
    if (tag === "h1") lines.push(`# ${text}`);
    else if (tag === "h2") lines.push(`## ${text}`);
    else if (tag === "h3") lines.push(`### ${text}`);
    else if (tag === "li") lines.push(`- ${text}`);
    else if (tag === "blockquote") lines.push(`> ${text}`);
    else if (tag === "pre" || tag === "code") lines.push("```", text, "```");
    else lines.push(text);
    lines.push("");
  }

  const markdown = lines.join("\n").replace(/\n{3,}/g, "\n\n").trim();
  return markdown.length > 20 ? markdown.slice(0, 180000) : undefined;
}

function extractImageURLs(metadata) {
  const urls = new Set([metadata.ogImageURL, metadata.faviconURL].filter(Boolean));
  for (const image of [...document.images].slice(0, 80)) {
    const source = image.currentSrc || image.src;
    if (!source) continue;
    const width = image.naturalWidth || image.width || 0;
    const height = image.naturalHeight || image.height || 0;
    if (width < 120 || height < 80) continue;
    try {
      urls.add(new URL(source, location.href).href);
    } catch {
      // Ignore malformed page-provided image URLs.
    }
  }
  return [...urls].slice(0, 24);
}

function extractTranscriptText() {
  const transcriptSelectors = [
    "ytd-transcript-segment-renderer",
    "[data-testid='transcript']",
    ".transcript",
    "[aria-label*='Transcript' i]"
  ];
  const segments = transcriptSelectors.flatMap(selector =>
    [...document.querySelectorAll(selector)].map(node => cleanText(node.innerText || node.textContent || ""))
  ).filter(Boolean);
  return segments.length ? segments.slice(0, 800).join("\n") : undefined;
}

function extractVisibleXThread(selection) {
  const posts = [...document.querySelectorAll('article[data-testid="tweet"]')]
    .slice(0, 24)
    .map(post => cleanText(post.innerText || ""))
    .filter(Boolean);
  if (selection) {
    posts.unshift(selection);
  }
  return posts.length ? posts.join("\n\n---\n\n").slice(0, 120000) : undefined;
}

function cleanText(value) {
  return value.replace(/\s+/g, " ").trim();
}

function postNearSelection() {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) {
    return null;
  }

  let node = selection.getRangeAt(0).startContainer;
  if (node.nodeType === Node.TEXT_NODE) {
    node = node.parentElement;
  }

  return node?.closest?.('article[data-testid="tweet"]') || null;
}

function bookmarkCurrentXPost() {
  const post = postNearSelection() || lastHoveredPost || document.querySelector('article[data-testid="tweet"]');
  const bookmarkButton = post?.querySelector('[data-testid="bookmark"]');
  bookmarkButton?.click();
}

function isXPage() {
  return location.hostname === "x.com" || location.hostname === "twitter.com";
}

function detectAutoTags(metadata, articleMarkdown) {
  const tags = new Set();
  const host = location.hostname.replace("www.", "");
  const text = (metadata.title + " " + (articleMarkdown || "")).toLowerCase();

  const siteTags = {
    "arxiv.org": "paper", "scholar.google.com": "paper", "semanticscholar.org": "paper",
    "github.com": "code", "gitlab.com": "code", "stackoverflow.com": "code",
    "medium.com": "article", "substack.com": "newsletter", "dev.to": "article",
    "youtube.com": "video", "vimeo.com": "video",
    "figma.com": "design", "dribbble.com": "design", "behance.net": "design",
    "news.ycombinator.com": "news", "reddit.com": "discussion",
    "docs.google.com": "document", "notion.so": "document",
    "x.com": "social", "twitter.com": "social", "linkedin.com": "social",
  };
  for (const [site, tag] of Object.entries(siteTags)) {
    if (host.includes(site)) tags.add(tag);
  }

  const contentTags = [
    ["research", /\b(study|research|findings|methodology|hypothesis|experiment|dataset)\b/],
    ["tutorial", /\b(tutorial|how.to|step.by.step|guide|walkthrough|getting.started)\b/],
    ["review", /\b(review|comparison|versus|benchmark|evaluation)\b/],
    ["news", /\b(breaking|announced|launched|released|updated)\b/],
    ["opinion", /\b(I think|in my opinion|I believe|personally|frankly)\b/],
    ["data", /\b(dataset|statistics|metrics|analysis|numbers|survey)\b/],
    ["design", /\b(UI|UX|design|prototype|wireframe|layout|typography)\b/],
    ["security", /\b(security|vulnerability|exploit|CVE|breach|encryption)\b/],
    ["AI", /\b(machine learning|deep learning|neural|LLM|GPT|transformer|AI)\b/],
  ];
  for (const [tag, regex] of contentTags) {
    if (regex.test(text)) tags.add(tag);
  }

  return [...tags].slice(0, 8);
}
