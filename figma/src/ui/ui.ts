/**
 * LYNK — Figma plugin UI iframe.
 *
 * Renders the scan/export flow, the generated Roblox code, the activity log
 * and settings. Talks to the plugin main thread exclusively via postMessage;
 * there is no networking here (or anywhere else in the plugin).
 */

// ---------------------------------------------------------------------------
// types for main <-> ui messages
// ---------------------------------------------------------------------------

type MainMsg =
  | { kind: "state"; state: string }
  | {
      kind: "scan-result";
      ok: boolean;
      summary?: ScanSummary;
      code?: string;
      name?: string;
      nodes?: number;
      message?: string;
      empty?: boolean;
    }
  | { kind: "activity"; entries: Array<{ time: number; text: string }> }
  | { kind: "error"; message: string }
  | { kind: "settings"; settings: Record<string, unknown> }
  | { kind: "export-code-result"; ok: boolean; code?: string; name?: string; nodes?: number; message?: string };

interface ScanSummary {
  nodeId: string;
  name: string;
  descendants: number;
  components: number;
  interactions: number;
  assets: number;
}

// ---------------------------------------------------------------------------
// persisted settings (localStorage inside the iframe)
// ---------------------------------------------------------------------------

const LS_KEY = "lynk-settings-v2";
interface UISettings {
  includeImageBytes: boolean;
}
const defaults: UISettings = {
  includeImageBytes: true,
};
let uiSettings: UISettings = { ...defaults };
try {
  const raw = localStorage.getItem(LS_KEY);
  if (raw) uiSettings = { ...defaults, ...JSON.parse(raw) };
} catch { /* ignore */ }
function saveSettings() {
  try { localStorage.setItem(LS_KEY, JSON.stringify(uiSettings)); } catch { /* ignore */ }
}

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------

let pluginState = "DISCONNECTED";
let currentSummary: ScanSummary | null = null;
let currentCode: string | null = null;
const activity: Array<{ time: number; text: string }> = [];

// ---------------------------------------------------------------------------
// dom helpers
// ---------------------------------------------------------------------------

const $ = <T extends HTMLElement = HTMLElement>(id: string): T => document.getElementById(id) as T;

function toMain(msg: unknown) {
  parent.postMessage({ pluginMessage: msg }, "*");
}

function show(screen: string) {
  for (const id of ["screen-idle", "screen-selection", "screen-settings"]) {
    $(id).classList.toggle("hidden", id !== screen);
  }
}

function setFooter(state: string) {
  $("footer-state").textContent = state;
}

function renderActivity() {
  const el = $("activity");
  el.innerHTML = "";
  for (const item of activity.slice(0, 30)) {
    const div = document.createElement("div");
    div.className = "activity-item";
    const t = document.createElement("span");
    t.className = "time";
    t.textContent = new Date(item.time).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
    const s = document.createElement("span");
    s.textContent = item.text;
    div.append(t, s);
    el.appendChild(div);
  }
}

function pushActivity(text: string) {
  activity.unshift({ time: Date.now(), text });
  if (activity.length > 60) activity.pop();
  renderActivity();
}

function showError(message: string) {
  const target = $("idle-scan-result");
  target.innerHTML = "";
  const banner = document.createElement("div");
  banner.className = "error-banner";
  banner.textContent = message;
  target.appendChild(banner);
  setTimeout(() => { if (target.contains(banner)) target.innerHTML = ""; }, 6000);
}

// ---------------------------------------------------------------------------
// generated code (shown at the top, and copied to the clipboard)
// ---------------------------------------------------------------------------

function setCodeStatus(text: string, ok: boolean) {
  const el = $("code-status");
  el.textContent = text;
  el.style.color = ok ? "var(--success)" : "var(--danger)";
}

async function copyToClipboard(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

async function showCode(code: string, label: string) {
  currentCode = code;
  $("code-display").textContent = code;
  $("code-panel").classList.remove("hidden");
  const copied = await copyToClipboard(code);
  setCodeStatus(copied ? `${label} — copied to clipboard ✓` : `${label} — select the code and copy manually.`, copied);
}

// ---------------------------------------------------------------------------
// main-thread message handling
// ---------------------------------------------------------------------------

window.onmessage = async (event: MessageEvent) => {
  const msg = event.data?.pluginMessage as MainMsg | undefined;
  if (!msg) return;
  switch (msg.kind) {
    case "state": {
      pluginState = msg.state;
      renderState();
      break;
    }
    case "scan-result": {
      if (!msg.ok) {
        if (!msg.empty) showError(msg.message ?? "Nothing selected.");
        currentSummary = null;
        renderState();
        break;
      }
      currentSummary = msg.summary!;
      if (msg.code) await showCode(msg.code, "Code");
      renderState();
      break;
    }
    case "activity": {
      activity.length = 0;
      for (const e of msg.entries) activity.push(e);
      renderActivity();
      break;
    }
    case "error": {
      showError(msg.message);
      break;
    }
    case "settings": {
      const s = msg.settings as Partial<UISettings>;
      Object.assign(uiSettings, s);
      syncSettingsForm();
      break;
    }
    case "export-code-result": {
      setExportBusy(false);
      if (!msg.ok || !msg.code) {
        showError(msg.message ?? "Could not export code.");
        break;
      }
      await showCode(msg.code, `Code for "${msg.name}" (${msg.nodes} nodes)`);
      pushActivity(`Exported code for "${msg.name}"`);
      break;
    }
    default: break;
  }
};

function renderState() {
  switch (pluginState) {
    case "DISCONNECTED": {
      show("screen-idle");
      setFooter(currentCode ? "Code ready" : "Disconnected");
      break;
    }
    case "SCANNED": {
      if (currentSummary) {
        $("sel-name").textContent = currentSummary.name;
        $("sel-nodes").textContent = String(currentSummary.descendants);
        $("sel-components").textContent = String(currentSummary.components);
        $("sel-interactions").textContent = String(currentSummary.interactions);
        $("sel-assets").textContent = String(currentSummary.assets);
        show("screen-selection");
        setFooter(`Selected · ${currentSummary.name}`);
      } else {
        show("screen-idle");
        setFooter("Disconnected");
      }
      break;
    }
    default: break;
  }
}

// ---------------------------------------------------------------------------
// buttons
// ---------------------------------------------------------------------------

$("btn-scan").onclick = () => toMain({ kind: "scan" });
$("btn-rescan").onclick = () => toMain({ kind: "scan" });

// "Copy code for Roblox" (import-only flow)
const exportButtons = Array.from(document.querySelectorAll<HTMLButtonElement>(".btn-export"));
function setExportBusy(busy: boolean) {
  for (const b of exportButtons) b.disabled = busy;
}
for (const b of exportButtons) {
  b.onclick = () => {
    setExportBusy(true);
    toMain({ kind: "export-code" });
  };
}

$("btn-copy-code").onclick = async () => {
  if (!currentCode) return;
  const copied = await copyToClipboard(currentCode);
  setCodeStatus(copied ? "Copied to clipboard ✓" : "Copy failed — select the code and copy manually.", copied);
};

$("btn-hide-code").onclick = () => {
  $("code-panel").classList.add("hidden");
};

// settings screen
$("btn-settings").onclick = () => {
  syncSettingsForm();
  show("screen-settings");
};
$("btn-settings-back").onclick = () => renderState();

function syncSettingsForm() {
  ($("set-assets") as HTMLInputElement).checked = uiSettings.includeImageBytes;
}

function pushSettingsToMain() {
  toMain({
    kind: "settings",
    settings: {
      includeImageBytes: uiSettings.includeImageBytes,
    },
  });
}

$("set-assets").addEventListener("change", () => {
  uiSettings.includeImageBytes = ($("set-assets") as HTMLInputElement).checked;
  saveSettings();
  pushSettingsToMain();
});

// ---------------------------------------------------------------------------
// boot
// ---------------------------------------------------------------------------

syncSettingsForm();
toMain({ kind: "ui-ready" });
