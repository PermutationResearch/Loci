import http from "node:http";

const port = Number(process.argv[2] ?? 9223);
const action = process.argv[3] ?? "status";
const base = `http://127.0.0.1:${port}`;
const timeoutMs = 15000;

function get(url) {
  return new Promise((resolve, reject) => {
    const request = http.get(url, (response) => {
      let body = "";
      response.on("data", (chunk) => {
        body += chunk;
      });
      response.on("end", () => resolve(body));
    });
    request.setTimeout(timeoutMs, () => request.destroy(new Error("HTTP timeout")));
    request.on("error", reject);
  });
}

async function getPage() {
  const pages = JSON.parse(await get(`${base}/json/list`));
  const page = pages.find((item) => item.url.includes("hud-overlay")) ?? pages[0];
  if (!page?.webSocketDebuggerUrl) {
    throw new Error(`No OpenScreen renderer on ${base}`);
  }
  return page;
}

async function evaluate(expression) {
  const page = await getPage();
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(page.webSocketDebuggerUrl);
    const id = 1;
    const timer = setTimeout(() => reject(new Error("WebSocket timeout")), timeoutMs);
    socket.onopen = () => {
      socket.send(
        JSON.stringify({
          id,
          method: "Runtime.evaluate",
          params: {
            expression,
            awaitPromise: true,
            returnByValue: true,
          },
        }),
      );
    };
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id !== id) return;
      clearTimeout(timer);
      socket.close();
      if (message.exceptionDetails) {
        reject(new Error(JSON.stringify(message.exceptionDetails, null, 2)));
      } else {
        resolve(message.result?.result?.value ?? message.result?.result ?? message);
      }
    };
    socket.onerror = (event) => {
      clearTimeout(timer);
      reject(event.error ?? new Error("WebSocket error"));
    };
  });
}

const sourceExpression = `
(async () => {
  try {
    const sources = await window.electronAPI.getSources({
      types: ["screen", "window"],
      thumbnailSize: { width: 80, height: 45 },
      fetchWindowIcons: true
    });
    return {
      ok: true,
      sources: sources.map((source) => ({
        id: source.id,
        name: source.name,
        display_id: source.display_id,
        hasThumbnail: Boolean(source.thumbnail),
        hasIcon: Boolean(source.appIcon)
      }))
    };
  } catch (error) {
    return { ok: false, error: String(error), stack: error?.stack ?? null };
  }
})()
`;

function startExpression(preferredName) {
  return `
(async () => {
  const sources = await window.electronAPI.getSources({
    types: ["screen", "window"],
    thumbnailSize: { width: 80, height: 45 },
    fetchWindowIcons: true
  });
  const preferred = ${JSON.stringify(preferredName ?? "")}.toLowerCase();
  const source =
    sources.find((item) => preferred && item.name.toLowerCase().includes(preferred)) ??
    sources.find((item) => item.id.startsWith("screen:")) ??
    sources[0];
  if (!source) return { ok: false, error: "No capture sources available" };

  await window.electronAPI.selectSource({
    id: source.id,
    name: source.name,
    display_id: source.display_id,
    thumbnail: source.thumbnail ?? null,
    appIcon: source.appIcon ?? null
  });

  const sourceType = source.id.startsWith("window:") ? "window" : "display";
  const displayId = Number(source.display_id) || Number((source.id.match(/^screen:(\\d+)/) || [])[1]);
  const windowId = Number((source.id.match(/^window:(\\d+)/) || [])[1]);
  const recordingId = Date.now();
  const request = {
    schemaVersion: 1,
    recordingId,
    source: {
      type: sourceType,
      sourceId: source.id,
      ...(displayId ? { displayId } : {}),
      ...(windowId ? { windowId } : {})
    },
    video: {
      fps: 60,
      width: 1920,
      height: 1080,
      bitrate: 16000000,
      hideSystemCursor: false
    },
    audio: {
      system: { enabled: false },
      microphone: { enabled: false, deviceId: null, deviceName: null, gain: 1 }
    },
    webcam: {
      enabled: false,
      deviceId: null,
      deviceName: null,
      width: 0,
      height: 0,
      fps: 30
    },
    cursor: { mode: "system" },
    outputs: { screenPath: "" }
  };
  const result = await window.electronAPI.startNativeMacRecording(request);
  return { ok: Boolean(result?.success), selected: { id: source.id, name: source.name, display_id: source.display_id }, request, result };
})()
`;
}

const stopExpression = `
(async () => {
  const result = await window.electronAPI.stopNativeMacRecording(false);
  return { ok: Boolean(result?.success), result };
})()
`;

try {
  if (action === "status") {
    const permission = await evaluate("window.electronAPI.requestScreenAccess()");
    const platform = await evaluate("window.electronAPI.getPlatform()");
    const nativeMac = await evaluate("window.electronAPI.isNativeMacCaptureAvailable()");
    const sources = await evaluate(sourceExpression);
    console.log(JSON.stringify({ permission, platform, nativeMac, sources }, null, 2));
  } else if (action === "sources") {
    console.log(JSON.stringify(await evaluate(sourceExpression), null, 2));
  } else if (action === "start") {
    console.log(JSON.stringify(await evaluate(startExpression(process.argv[4] ?? "Loci")), null, 2));
  } else if (action === "stop") {
    console.log(JSON.stringify(await evaluate(stopExpression), null, 2));
  } else {
    throw new Error(`Unknown action: ${action}`);
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
