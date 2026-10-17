"use strict";
(() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropSymbols = Object.getOwnPropertySymbols;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __propIsEnum = Object.prototype.propertyIsEnumerable;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __spreadValues = (a, b) => {
    for (var prop in b || (b = {}))
      if (__hasOwnProp.call(b, prop))
        __defNormalProp(a, prop, b[prop]);
    if (__getOwnPropSymbols)
      for (var prop of __getOwnPropSymbols(b)) {
        if (__propIsEnum.call(b, prop))
          __defNormalProp(a, prop, b[prop]);
      }
    return a;
  };

  // src/ui/ui.ts
  var LS_KEY = "lynk-settings-v2";
  var defaults = {
    includeImageBytes: true
  };
  var uiSettings = __spreadValues({}, defaults);
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (raw) uiSettings = __spreadValues(__spreadValues({}, defaults), JSON.parse(raw));
  } catch (e) {
  }
  function saveSettings() {
    try {
      localStorage.setItem(LS_KEY, JSON.stringify(uiSettings));
    } catch (e) {
    }
  }
  var pluginState = "DISCONNECTED";
  var currentSummary = null;
  var currentCode = null;
  var activity = [];
  var $ = (id) => document.getElementById(id);
  function toMain(msg) {
    parent.postMessage({ pluginMessage: msg }, "*");
  }
  function show(screen) {
    for (const id of ["screen-idle", "screen-selection", "screen-settings"]) {
      $(id).classList.toggle("hidden", id !== screen);
    }
  }
  function setFooter(state) {
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
  function pushActivity(text) {
    activity.unshift({ time: Date.now(), text });
    if (activity.length > 60) activity.pop();
    renderActivity();
  }
  function showError(message) {
    const target = $("idle-scan-result");
    target.innerHTML = "";
    const banner = document.createElement("div");
    banner.className = "error-banner";
    banner.textContent = message;
    target.appendChild(banner);
    setTimeout(() => {
      if (target.contains(banner)) target.innerHTML = "";
    }, 6e3);
  }
  function setCodeStatus(text, ok) {
    const el = $("code-status");
    el.textContent = text;
    el.style.color = ok ? "var(--success)" : "var(--danger)";
  }
  async function copyToClipboard(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (e) {
      return false;
    }
  }
  async function showCode(code, label) {
    currentCode = code;
    $("code-display").textContent = code;
    $("code-panel").classList.remove("hidden");
    const copied = await copyToClipboard(code);
    setCodeStatus(copied ? `${label} \u2014 copied to clipboard \u2713` : `${label} \u2014 select the code and copy manually.`, copied);
  }
  window.onmessage = async (event) => {
    var _a, _b, _c;
    const msg = (_a = event.data) == null ? void 0 : _a.pluginMessage;
    if (!msg) return;
    switch (msg.kind) {
      case "state": {
        pluginState = msg.state;
        renderState();
        break;
      }
      case "scan-result": {
        if (!msg.ok) {
          if (!msg.empty) showError((_b = msg.message) != null ? _b : "Nothing selected.");
          currentSummary = null;
          renderState();
          break;
        }
        currentSummary = msg.summary;
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
        const s = msg.settings;
        Object.assign(uiSettings, s);
        syncSettingsForm();
        break;
      }
      case "export-code-result": {
        setExportBusy(false);
        if (!msg.ok || !msg.code) {
          showError((_c = msg.message) != null ? _c : "Could not export code.");
          break;
        }
        await showCode(msg.code, `Code for "${msg.name}" (${msg.nodes} nodes)`);
        pushActivity(`Exported code for "${msg.name}"`);
        break;
      }
      default:
        break;
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
          setFooter(`Selected \xB7 ${currentSummary.name}`);
        } else {
          show("screen-idle");
          setFooter("Disconnected");
        }
        break;
      }
      default:
        break;
    }
  }
  $("btn-scan").onclick = () => toMain({ kind: "scan" });
  $("btn-rescan").onclick = () => toMain({ kind: "scan" });
  var exportButtons = Array.from(document.querySelectorAll(".btn-export"));
  function setExportBusy(busy) {
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
    setCodeStatus(copied ? "Copied to clipboard \u2713" : "Copy failed \u2014 select the code and copy manually.", copied);
  };
  $("btn-hide-code").onclick = () => {
    $("code-panel").classList.add("hidden");
  };
  $("btn-settings").onclick = () => {
    syncSettingsForm();
    show("screen-settings");
  };
  $("btn-settings-back").onclick = () => renderState();
  function syncSettingsForm() {
    $("set-assets").checked = uiSettings.includeImageBytes;
  }
  function pushSettingsToMain() {
    toMain({
      kind: "settings",
      settings: {
        includeImageBytes: uiSettings.includeImageBytes
      }
    });
  }
  $("set-assets").addEventListener("change", () => {
    uiSettings.includeImageBytes = $("set-assets").checked;
    saveSettings();
    pushSettingsToMain();
  });
  syncSettingsForm();
  toMain({ kind: "ui-ready" });
})();
