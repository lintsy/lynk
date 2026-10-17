/**
 * LYNK — Figma plugin main thread.
 *
 * Responsibilities:
 *   - selection scanning & normalized schema extraction (Figma Adapter)
 *   - building the LYNK export code (LYNK1:<base64 JSON schema>)
 *   - activity log
 *
 * Import-only pipeline: there is no networking, pairing or live sync. The UI
 * iframe only renders and copies the code the user pastes into Roblox Studio.
 */

import { type LYNKUISchema } from "../../shared/schema";
import { extractHierarchy } from "./figma/extractor";
import { utf8ToBase64 } from "./util/base64";

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------

type PluginState = "DISCONNECTED" | "SCANNED";

interface ScanSummary {
  nodeId: string;
  name: string;
  descendants: number;
  components: number;
  interactions: number;
  assets: number;
}

interface Settings {
  includeImageBytes: boolean;
}

let state: PluginState = "DISCONNECTED";
let schema: LYNKUISchema | null = null;

const settings: Settings = {
  includeImageBytes: true,
};

const history: Array<{ time: number; text: string }> = [];

// ---------------------------------------------------------------------------
// ui messaging
// ---------------------------------------------------------------------------

function post(msg: unknown) {
  figma.ui.postMessage(msg);
}

function setState(next: PluginState) {
  state = next;
  post({ kind: "state", state });
}

function logActivity(text: string) {
  history.unshift({ time: Date.now(), text });
  if (history.length > 60) history.pop();
  post({ kind: "activity", entries: history.slice(0, 30) });
}

// ---------------------------------------------------------------------------
// selection scanning
// ---------------------------------------------------------------------------

function currentSelectionRoot(): SceneNode | null {
  const sel = figma.currentPage.selection;
  if (sel.length !== 1) return null;
  const node = sel[0];
  if (!("children" in node) && node.type !== "TEXT") return null;
  return node as SceneNode;
}

function summarizeSelection(root: SceneNode, s: LYNKUISchema): ScanSummary {
  let components = 0;
  for (const n of Object.values(s.nodes)) if (n.component) components++;
  return {
    nodeId: root.id,
    name: root.name,
    descendants: Object.keys(s.nodes).length - 1,
    components,
    interactions: Object.keys(s.interactions).length,
    assets: Object.keys(s.assets).length,
  };
}

/** Extract the current selection into a schema. */
async function scanSelection(): Promise<LYNKUISchema | null> {
  const root = currentSelectionRoot();
  if (!root) return null;
  const { schema: s } = await extractHierarchy(root, {
    includeImageBytes: settings.includeImageBytes,
    maxImageBytes: 8 * 1024 * 1024,
  });
  return s;
}

/** LYNK1:<base64(JSON schema)> — what the Roblox Studio plugin pastes. */
function encodeCode(s: LYNKUISchema): string {
  return "LYNK1:" + utf8ToBase64(JSON.stringify(s));
}

// ---------------------------------------------------------------------------
// ui message handler
// ---------------------------------------------------------------------------

figma.ui.onmessage = async (msg: Record<string, unknown>) => {
  switch (msg.kind) {
    case "ui-ready": {
      post({ kind: "state", state });
      post({ kind: "activity", entries: history.slice(0, 30) });
      post({ kind: "settings", settings });
      break;
    }
    case "scan": {
      const s = await scanSelection();
      if (!s) {
        setState("DISCONNECTED");
        post({ kind: "scan-result", ok: false, message: "Select a single UI element first." });
        break;
      }
      schema = s;
      setState("SCANNED");
      const nodeCount = Object.keys(s.nodes).length;
      post({
        kind: "scan-result",
        ok: true,
        summary: summarizeSelection(currentSelectionRoot()!, s),
        code: encodeCode(s),
        name: s.metadata.name,
        nodes: nodeCount,
      });
      logActivity(`Scanned "${s.metadata.name}" (${nodeCount} nodes)`);
      break;
    }
    case "export-code": {
      try {
        const root =
          currentSelectionRoot() ??
          (schema ? (figma.getNodeById(schema.metadata.rootId) as SceneNode | null) : null);
        if (!root) {
          post({
            kind: "export-code-result",
            ok: false,
            message: "Select a single UI element to export.",
          });
          break;
        }
        const { schema: fresh } = await extractHierarchy(root, {
          includeImageBytes: settings.includeImageBytes,
          maxImageBytes: 8 * 1024 * 1024,
        });
        schema = fresh;
        const code = encodeCode(fresh);
        const nodeCount = Object.keys(fresh.nodes).length;
        post({
          kind: "export-code-result",
          ok: true,
          code,
          name: fresh.metadata.name,
          nodes: nodeCount,
        });
        logActivity(`Exported code for "${fresh.metadata.name}" (${nodeCount} nodes)`);
      } catch (e) {
        post({ kind: "export-code-result", ok: false, message: String(e) });
      }
      break;
    }
    case "settings": {
      Object.assign(settings, msg.settings ?? {});
      break;
    }
    default:
      break;
  }
};

// ---------------------------------------------------------------------------
// boot
// ---------------------------------------------------------------------------

figma.showUI(__html__, { width: 340, height: 520, themeColors: true });

// Keep the selection panel in sync as the user moves around the canvas.
figma.on("selectionchange", () => {
  if (state === "DISCONNECTED" || state === "SCANNED") {
    const root = currentSelectionRoot();
    if (!root) {
      setState("DISCONNECTED");
      post({ kind: "scan-result", ok: false, empty: true });
    }
  }
});
