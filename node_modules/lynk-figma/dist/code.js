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
  var __objRest = (source, exclude) => {
    var target = {};
    for (var prop in source)
      if (__hasOwnProp.call(source, prop) && exclude.indexOf(prop) < 0)
        target[prop] = source[prop];
    if (source != null && __getOwnPropSymbols)
      for (var prop of __getOwnPropSymbols(source)) {
        if (exclude.indexOf(prop) < 0 && __propIsEnum.call(source, prop))
          target[prop] = source[prop];
      }
    return target;
  };

  // ../shared/schema.ts
  var SCHEMA_VERSION = "1.0.0";
  var LYNK_PLUGIN_VERSION = "1.0.0";

  // src/util/hash.ts
  function fnv(bytes, seed) {
    let h = seed >>> 0;
    for (let i = 0; i < bytes.length; i++) {
      h ^= bytes[i];
      h = Math.imul(h, 16777619) >>> 0;
    }
    return h >>> 0;
  }
  function hashBytes(bytes) {
    const h0 = fnv(bytes, 2166136261);
    const h1 = fnv(bytes, 2654435761);
    const h2 = fnv(bytes, 2246822507);
    const h3 = fnv(bytes, 3266489909);
    return [h0, h1, h2, h3].map((h) => h.toString(16).padStart(8, "0")).join("");
  }
  function hashString(s) {
    let bytes;
    const enc = [];
    for (let i = 0; i < s.length; i++) {
      let c = s.charCodeAt(i);
      if (c < 128) enc.push(c);
      else if (c < 2048) {
        enc.push(192 | c >> 6, 128 | c & 63);
      } else if (c >= 55296 && c <= 56319 && i + 1 < s.length) {
        const c2 = s.charCodeAt(++i);
        c = 65536 + (c - 55296 << 10) + (c2 - 56320);
        enc.push(240 | c >> 18, 128 | c >> 12 & 63, 128 | c >> 6 & 63, 128 | c & 63);
      } else {
        enc.push(224 | c >> 12, 128 | c >> 6 & 63, 128 | c & 63);
      }
    }
    bytes = new Uint8Array(enc);
    return hashBytes(bytes);
  }
  function stableStringify(value) {
    var _a;
    if (value === null || typeof value !== "object") return (_a = JSON.stringify(value)) != null ? _a : "null";
    if (Array.isArray(value)) return "[" + value.map(stableStringify).join(",") + "]";
    const obj = value;
    const keys = Object.keys(obj).sort();
    const parts = [];
    for (const k of keys) {
      const v = obj[k];
      if (v === void 0) continue;
      parts.push(JSON.stringify(k) + ":" + stableStringify(v));
    }
    return "{" + parts.join(",") + "}";
  }
  function hashObject(value) {
    return hashString(stableStringify(value));
  }

  // src/util/base64.ts
  var CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  function bytesToBase64(bytes) {
    let out = "";
    const len = bytes.length;
    for (let i = 0; i < len; i += 3) {
      const b0 = bytes[i];
      const b1 = i + 1 < len ? bytes[i + 1] : 0;
      const b2 = i + 2 < len ? bytes[i + 2] : 0;
      out += CHARS[b0 >> 2];
      out += CHARS[(b0 & 3) << 4 | b1 >> 4];
      out += i + 1 < len ? CHARS[(b1 & 15) << 2 | b2 >> 6] : "=";
      out += i + 2 < len ? CHARS[b2 & 63] : "=";
    }
    return out;
  }
  function utf8ToBase64(str) {
    const bytes = [];
    for (let i = 0; i < str.length; i++) {
      const code = str.charCodeAt(i);
      if (code < 128) {
        bytes.push(code);
      } else if (code < 2048) {
        bytes.push(192 | code >> 6, 128 | code & 63);
      } else if (code >= 55296 && code <= 56319 && i + 1 < str.length) {
        const next = str.charCodeAt(i + 1);
        const cp = 65536 + (code - 55296 << 10) + (next - 56320);
        i++;
        bytes.push(
          240 | cp >> 18,
          128 | cp >> 12 & 63,
          128 | cp >> 6 & 63,
          128 | cp & 63
        );
      } else {
        bytes.push(224 | code >> 12, 128 | code >> 6 & 63, 128 | code & 63);
      }
    }
    return bytesToBase64(new Uint8Array(bytes));
  }

  // src/figma/extractor.ts
  function isMixed(v) {
    return v === figma.mixed;
  }
  function num(v, fallback = 0) {
    return typeof v === "number" && isFinite(v) ? v : fallback;
  }
  function getOpacity(n) {
    return "opacity" in n ? num(n.opacity, 1) : 1;
  }
  function getBlendMode(n) {
    var _a;
    return "blendMode" in n ? String((_a = n.blendMode) != null ? _a : "NORMAL") : "NORMAL";
  }
  function getRotation(n) {
    return "rotation" in n ? num(n.rotation, 0) : 0;
  }
  function getLocked(n) {
    return "locked" in n ? Boolean(n.locked) : false;
  }
  function getEffects(n) {
    return "effects" in n ? n.effects : [];
  }
  function colorToRGBA(c) {
    return { r: c.r, g: c.g, b: c.b, a: c.a === void 0 ? 1 : c.a };
  }
  function mapType(figmaType) {
    switch (figmaType) {
      case "FRAME":
        return "FRAME";
      case "GROUP":
        return "GROUP";
      case "SECTION":
        return "SECTION";
      case "TEXT":
        return "TEXT";
      case "RECTANGLE":
        return "RECTANGLE";
      case "ELLIPSE":
        return "ELLIPSE";
      case "VECTOR":
        return "VECTOR";
      case "BOOLEAN_OPERATION":
        return "BOOLEAN_OPERATION";
      case "STAR":
        return "STAR";
      case "POLYGON":
        return "POLYGON";
      case "LINE":
        return "LINE";
      case "COMPONENT":
        return "COMPONENT";
      case "COMPONENT_SET":
        return "COMPONENT_SET";
      case "INSTANCE":
        return "INSTANCE";
      default:
        return "OTHER";
    }
  }
  function serializePaint(paint) {
    var _a, _b;
    const base = {
      opacity: num(paint.opacity, 1),
      visible: paint.visible !== false,
      blendMode: String((_a = paint.blendMode) != null ? _a : "NORMAL")
    };
    switch (paint.type) {
      case "SOLID":
        return __spreadValues({ type: "SOLID", color: colorToRGBA(paint.color) }, base);
      case "GRADIENT_LINEAR":
      case "GRADIENT_RADIAL":
      case "GRADIENT_ANGULAR":
      case "GRADIENT_DIAMOND":
        return __spreadValues({
          type: paint.type,
          gradientTransform: paint.gradientTransform.map((row) => [...row]),
          stops: paint.gradientStops.map((s) => ({ position: s.position, color: colorToRGBA(s.color) }))
        }, base);
      case "IMAGE":
        return __spreadValues({
          type: "IMAGE",
          imageHash: (_b = paint.imageHash) != null ? _b : void 0,
          scaleMode: paint.scaleMode,
          imageTransform: paint.imageTransform ? paint.imageTransform.map((r) => [...r]) : void 0,
          scalingFactor: paint.scalingFactor,
          rotation: paint.rotation
        }, base);
      case "VIDEO":
        return __spreadValues(__spreadValues({ type: "VIDEO" }, paint), base);
      default:
        return __spreadValues({ type: paint.type }, base);
    }
  }
  function serializeEffects(effects) {
    var _a;
    const out = [];
    for (const e of effects) {
      if (e.type === "DROP_SHADOW" || e.type === "INNER_SHADOW") {
        out.push({
          type: e.type,
          color: colorToRGBA(e.color),
          offset: { x: e.offset.x, y: e.offset.y },
          radius: e.radius,
          spread: num(e.spread, 0),
          visible: e.visible !== false,
          blendMode: String((_a = e.blendMode) != null ? _a : "NORMAL")
        });
      } else if (e.type === "LAYER_BLUR" || e.type === "BACKGROUND_BLUR") {
        out.push({ type: e.type, radius: e.radius, visible: e.visible !== false });
      } else {
        out.push(e);
      }
    }
    return out;
  }
  function extractLayout(node) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _i, _j;
    if (!("layoutMode" in node)) return null;
    const n = node;
    const lm = n.layoutMode;
    if (!lm) return null;
    const layout = {
      mode: lm,
      itemSpacing: num(n.itemSpacing, 0),
      padding: {
        top: num(n.paddingTop, 0),
        right: num(n.paddingRight, 0),
        bottom: num(n.paddingBottom, 0),
        left: num(n.paddingLeft, 0)
      },
      primaryAxisAlignItems: String((_a = n.primaryAxisAlignItems) != null ? _a : "MIN"),
      counterAxisAlignItems: String((_b = n.counterAxisAlignItems) != null ? _b : "MIN"),
      primaryAxisSizingMode: String((_c = n.primaryAxisSizingMode) != null ? _c : "AUTO"),
      counterAxisSizingMode: String((_d = n.counterAxisSizingMode) != null ? _d : "AUTO"),
      layoutGrow: num(n.layoutGrow, 0),
      layoutAlign: String((_e = n.layoutAlign) != null ? _e : "INHERIT"),
      absolute: n.layoutPositioning === "ABSOLUTE",
      wrap: n.layoutWrap,
      counterAxisSpacing: num(n.counterAxisSpacing, 0),
      minWidth: (_f = n.minWidth) != null ? _f : null,
      minHeight: (_g = n.minHeight) != null ? _g : null,
      maxWidth: (_h = n.maxWidth) != null ? _h : null,
      maxHeight: (_i = n.maxHeight) != null ? _i : null,
      clipsContent: n.clipsContent,
      constraints: { vertical: n.constraints.vertical, horizontal: n.constraints.horizontal },
      aspectRatio: (_j = n.aspectRatio) != null ? _j : null
    };
    return layout;
  }
  function extractVisual(node) {
    var _a;
    const hasFills = "fills" in node;
    const hasStrokes = "strokes" in node;
    if (!hasFills && !hasStrokes && !("effects" in node)) return null;
    const gm = node;
    const v = {
      fills: hasFills && !isMixed(gm.fills) ? gm.fills.map(serializePaint) : [],
      strokes: hasStrokes && !isMixed(gm.strokes) ? gm.strokes.map(serializePaint) : [],
      strokeWeight: 0,
      strokeAlign: "INSIDE",
      effects: serializeEffects(getEffects(node)),
      opacity: getOpacity(node),
      blendMode: getBlendMode(node)
    };
    if (hasStrokes) {
      if (!isMixed(gm.strokeWeight)) {
        v.strokeWeight = num(gm.strokeWeight, 0);
      } else {
        const s = gm;
        v.strokeWeight = {
          top: num(s.strokeTopWeight, 0),
          right: num(s.strokeRightWeight, 0),
          bottom: num(s.strokeBottomWeight, 0),
          left: num(s.strokeLeftWeight, 0)
        };
      }
      v.strokeAlign = String((_a = gm.strokeAlign) != null ? _a : "INSIDE");
      if ("strokeJoin" in gm) v.strokeJoin = String(gm.strokeJoin);
      const dash = gm.strokeDashPattern;
      if (dash && dash.length) v.strokeDashPattern = [...dash];
    }
    if ("cornerRadius" in node) {
      const r = node;
      if (!isMixed(r.cornerRadius)) {
        v.cornerRadius = num(r.cornerRadius, 0);
      } else {
        v.cornerRadius = null;
        v.rectangleCornerRadii = [
          num(r.topLeftRadius, 0),
          num(r.topRightRadius, 0),
          num(r.bottomRightRadius, 0),
          num(r.bottomLeftRadius, 0)
        ];
      }
    }
    if ("backgrounds" in node && !isMixed(node.backgrounds)) {
      const bgs = node.backgrounds;
      if (bgs.length) v.background = bgs.map(serializePaint);
    }
    return v;
  }
  function extractTypography(node) {
    const t = {
      characters: node.characters,
      fontFamily: "unknown",
      fontStyle: "unknown",
      fontWeight: 400,
      fontSize: num(node.fontSize, 14),
      lineHeight: { unit: "AUTO", value: null },
      letterSpacing: { unit: "PIXELS", value: 0 },
      paragraphSpacing: num(node.paragraphSpacing, 0),
      textAlignHorizontal: String(node.textAlignHorizontal),
      textAlignVertical: String(node.textAlignVertical),
      textCase: isMixed(node.textCase) ? "ORIGINAL" : String(node.textCase),
      textDecoration: isMixed(node.textDecoration) ? "NONE" : String(node.textDecoration),
      textAutoResize: String(node.textAutoResize),
      hasMissingFont: node.hasMissingFont
    };
    if (!isMixed(node.fontName)) {
      t.fontFamily = node.fontName.family;
      t.fontStyle = node.fontName.style;
    } else {
      t.mixed = true;
      try {
        const first = node.getRangeFontName(0, Math.min(1, node.characters.length));
        if (first && !isMixed(first)) {
          t.fontFamily = first.family;
          t.fontStyle = first.style;
        }
      } catch (e) {
      }
    }
    if (!isMixed(node.fontWeight)) t.fontWeight = num(node.fontWeight, 400);
    if (!isMixed(node.lineHeight)) {
      const lh = node.lineHeight;
      t.lineHeight = { unit: lh.unit, value: lh.unit === "AUTO" ? null : lh.value };
    } else {
      t.mixed = true;
    }
    if (!isMixed(node.letterSpacing)) {
      t.letterSpacing = { unit: node.letterSpacing.unit, value: node.letterSpacing.value };
    } else {
      t.mixed = true;
    }
    if (typeof node.paragraphIndent === "number") t.paragraphIndent = node.paragraphIndent;
    t.hangingPunctuation = node.hangingPunctuation;
    t.hangingList = node.hangingList;
    return t;
  }
  async function extractComponent(node) {
    if (node.type === "INSTANCE") {
      const inst = node;
      const info = { kind: "INSTANCE" };
      try {
        const main = await inst.getMainComponentAsync();
        if (main) {
          info.componentId = main.id;
          info.componentName = main.name;
          info.remote = main.remote;
          const set = main.parent;
          if (set && set.type === "COMPONENT_SET") {
            info.componentSetId = set.id;
            info.componentSetName = set.name;
          }
        }
      } catch (e) {
      }
      const vp = inst.variantProperties;
      if (vp) info.variantProperties = __spreadValues({}, vp);
      const props = inst.componentProperties;
      if (props) {
        info.componentProperties = {};
        for (const key of Object.keys(props)) {
          info.componentProperties[key] = {
            type: props[key].type,
            value: props[key].value
          };
        }
      }
      return info;
    }
    if (node.type === "COMPONENT") {
      const c = node;
      const info = { kind: "COMPONENT", componentId: c.id, componentName: c.name };
      if (c.variantProperties) info.variantProperties = __spreadValues({}, c.variantProperties);
      const set = c.parent;
      if (set && set.type === "COMPONENT_SET") {
        info.componentSetId = set.id;
        info.componentSetName = set.name;
      }
      return info;
    }
    if (node.type === "COMPONENT_SET") {
      const set = node;
      return {
        kind: "COMPONENT_SET",
        componentSetId: set.id,
        componentName: set.name,
        variants: set.children.map((c) => c.name)
      };
    }
    return null;
  }
  async function loadLocalVariables() {
    var _a;
    const byId = /* @__PURE__ */ new Map();
    const collections = {};
    try {
      const vars = await figma.variables.getLocalVariablesAsync();
      const colls = await figma.variables.getLocalVariableCollectionsAsync();
      for (const c of colls) {
        collections[c.id] = {
          id: c.id,
          name: c.name,
          modes: c.modes.map((m) => ({ modeId: m.modeId, name: m.name })),
          defaultModeId: c.defaultModeId
        };
      }
      for (const v of vars) {
        const values = {};
        for (const [modeId, value] of Object.entries(v.valuesByMode)) values[modeId] = value;
        byId.set(v.id, {
          id: v.id,
          name: v.name,
          collectionId: v.variableCollectionId,
          collectionName: (_a = collections[v.variableCollectionId]) == null ? void 0 : _a.name,
          resolvedType: v.resolvedType,
          valuesByMode: values,
          scopes: [...v.scopes],
          description: v.description
        });
      }
    } catch (e) {
    }
    return { byId, collections };
  }
  function collectBoundVariables(node, ctxVars) {
    var _a;
    const out = [];
    const bv = node.boundVariables;
    if (!bv) return out;
    for (const [field, alias] of Object.entries(bv)) {
      if (!alias) continue;
      const aliases = Array.isArray(alias) ? alias : [alias];
      for (const a of aliases) {
        const id = a == null ? void 0 : a.id;
        if (!id) continue;
        out.push({ field, variableId: id, resolvedValue: (_a = ctxVars.get(id)) == null ? void 0 : _a.valuesByMode });
      }
    }
    return out;
  }
  function getReactions(node) {
    const r = node.reactions;
    return r != null ? r : [];
  }
  function mapTriggerEvent(trigger) {
    const type = trigger ? trigger.type : "";
    switch (type) {
      case "ON_CLICK":
        return "click";
      case "ON_HOVER":
        return "whileHovering";
      case "ON_PRESS":
        return "press";
      case "ON_DRAG":
        return "drag";
      case "ON_KEY_DOWN":
        return "keyDown";
      case "AFTER_TIMEOUT":
        return "afterDelay";
      case "MOUSE_ENTER":
        return "mouseEnter";
      case "MOUSE_LEAVE":
        return "mouseLeave";
      case "MOUSE_UP":
        return "mouseUp";
      case "MOUSE_DOWN":
        return "mouseDown";
      case "ON_MEDIA_HIT":
        return "mediaHit";
      default:
        return "other";
    }
  }
  function serializeTransition(t, id, nodeId) {
    var _a, _b, _c;
    if (!t) return null;
    const anim = {
      id,
      nodeId,
      type: String(t.type),
      duration: num(t.duration, 0),
      easing: { type: String((_b = (_a = t.easing) == null ? void 0 : _a.type) != null ? _b : "EASE_OUT") },
      raw: t
    };
    const bez = (_c = t.easing) == null ? void 0 : _c.easingFunctionCubicBezier;
    if (bez) {
      anim.easing = {
        type: "CUSTOM_CUBIC_BEZIER",
        easingFunctionCubicBezier: [bez.x1, bez.y1, bez.x2, bez.y2]
      };
    }
    if (t.direction) {
      anim.targetFields = [`direction:${t.direction}`];
    }
    return anim;
  }
  function mapAction(action, schema2) {
    var _a, _b;
    if (!action) return { type: "unknown" };
    switch (action.type) {
      case "BACK":
        return { type: "back", raw: action };
      case "CLOSE":
        return { type: "closeOverlay", raw: action };
      case "URL":
        return { type: "url", url: action.url, raw: action };
      case "UPDATE_MEDIA_RUNTIME":
        return { type: "unknown", raw: action };
      case "SET_VARIABLE":
        return {
          type: "setVariable",
          variableAssignment: {
            variableId: (_a = action.variableId) != null ? _a : "",
            value: action.variableValue
          },
          raw: action
        };
      case "SET_VARIABLE_MODE":
        return { type: "setVariable", raw: action };
      case "CONDITIONAL":
        return { type: "conditional", raw: action };
      case "NODE": {
        const destId = (_b = action.destinationId) != null ? _b : void 0;
        const payload = {
          type: action.navigation === "OVERLAY" ? "openOverlay" : "navigate",
          target: destId,
          navigation: action.navigation,
          raw: action
        };
        if (destId && schema2.nodes[destId]) payload.targetName = schema2.nodes[destId].name;
        if (action.navigation === "OVERLAY" && action.overlayRelativePosition) {
          payload.overlayRelativePosition = {
            x: action.overlayRelativePosition.x,
            y: action.overlayRelativePosition.y
          };
        }
        return payload;
      }
      default:
        return { type: "unknown", raw: action };
    }
  }
  function extractInteractions(node, schema2, animations) {
    var _a, _b;
    const reactions = getReactions(node);
    const ids = [];
    let order = 0;
    for (const r of reactions) {
      const event = mapTriggerEvent(r.trigger);
      const actions = (_a = r.actions) != null ? _a : r.action ? [r.action] : [];
      if (actions.length === 0) {
        const interaction = {
          id: `${node.id}#rx${order}`,
          nodeId: node.id,
          event,
          action: { type: "unknown" },
          trigger: r.trigger,
          raw: r
        };
        schema2.interactions[interaction.id] = interaction;
        ids.push(interaction.id);
        order++;
        continue;
      }
      for (const a of actions) {
        const interaction = {
          id: `${node.id}#rx${order++}`,
          nodeId: node.id,
          event,
          action: mapAction(a, schema2),
          trigger: r.trigger,
          raw: r
        };
        const transition = (_b = a.transition) != null ? _b : r.transition;
        if (transition) {
          const anim = serializeTransition(transition, `${node.id}#anim${order}`, node.id);
          if (anim) {
            animations[anim.id] = anim;
            interaction.animation = anim;
          }
        }
        schema2.interactions[interaction.id] = interaction;
        ids.push(interaction.id);
      }
    }
    return ids;
  }
  function collectImageAssets(node, visual, ctx) {
    var _a;
    const ids = [];
    if (!visual) return ids;
    const paints = [...visual.fills, ...(_a = visual.background) != null ? _a : []];
    for (const paint of paints) {
      if (paint.type !== "IMAGE") continue;
      const p = paint;
      const hash = p.imageHash;
      if (!hash) continue;
      let assetId = ctx.byHash.get(hash);
      if (!assetId) {
        assetId = `asset_img_${hash.slice(0, 16)}`;
        ctx.byHash.set(hash, assetId);
        ctx.assets[assetId] = {
          assetId,
          sourceNodeId: node.id,
          assetHash: hash,
          assetType: "image",
          format: "PNG",
          name: node.name,
          width: Math.round(node.width),
          height: Math.round(node.height),
          status: "PENDING"
        };
        ctx.exportQueue.push({ nodeId: node.id, assetId });
      }
      p.assetId = assetId;
      if (!ids.includes(assetId)) ids.push(assetId);
    }
    return ids;
  }
  function shouldExportVectorIcon(node) {
    const t = node.type;
    return (t === "VECTOR" || t === "BOOLEAN_OPERATION" || t === "STAR" || t === "POLYGON" || t === "ELLIPSE" || t === "LINE") && node.width <= 512 && node.height <= 512;
  }
  async function extractHierarchy(root, opts) {
    var _a, _b, _c;
    const schema2 = {
      schemaVersion: SCHEMA_VERSION,
      metadata: {
        name: root.name,
        rootId: root.id,
        capturedAt: Date.now(),
        pluginVersion: LYNK_PLUGIN_VERSION,
        schemaVersion: SCHEMA_VERSION,
        nodeCount: 0,
        interactionCount: 0,
        assetCount: 0
      },
      nodes: {},
      assets: {},
      variables: {},
      variableCollections: {},
      components: {},
      interactions: {},
      animations: {},
      revisions: [{ revision: 0, timestamp: Date.now(), source: "figma", summary: `Captured "${root.name}"` }],
      revision: 0
    };
    try {
      schema2.metadata.figmaFileName = figma.root.name;
    } catch (e) {
    }
    try {
      const key = (_a = figma.fileKey) != null ? _a : null;
      if (key) schema2.metadata.figmaFileKey = key;
    } catch (e) {
    }
    const { byId: varById, collections } = await loadLocalVariables();
    schema2.variableCollections = collections;
    for (const [id, v] of varById) schema2.variables[id] = v;
    const assetCtx = { byHash: /* @__PURE__ */ new Map(), assets: schema2.assets, exportQueue: [] };
    const externalTargets = [];
    const stack = [
      { node: root, parentId: null, index: 0 }
    ];
    const order = [];
    while (stack.length) {
      const { node, parentId, index } = stack.pop();
      const layout = extractLayout(node);
      const visual = extractVisual(node);
      const typography = node.type === "TEXT" ? extractTypography(node) : null;
      const component = await extractComponent(node);
      const variables = collectBoundVariables(node, varById);
      const uiNode = {
        id: node.id,
        parentId,
        name: node.name,
        type: mapType(node.type),
        figmaType: node.type,
        index,
        visible: node.visible,
        locked: getLocked(node),
        opacity: getOpacity(node),
        blendMode: getBlendMode(node),
        x: num(node.x),
        y: num(node.y),
        width: num(node.width),
        height: num(node.height),
        rotation: getRotation(node),
        layout,
        visual,
        typography,
        assets: [],
        component,
        variables,
        events: [],
        children: [],
        hash: "",
        metadata: {}
      };
      if ("absoluteBoundingBox" in node && node.absoluteBoundingBox) {
        const b = node.absoluteBoundingBox;
        uiNode.absolute = { x: b.x, y: b.y, width: b.width, height: b.height };
      }
      if ((component == null ? void 0 : component.kind) === "COMPONENT" && component.componentId) {
        schema2.components[component.componentId] = {
          id: component.componentId,
          name: (_b = component.componentName) != null ? _b : node.name,
          setId: component.componentSetId,
          setName: component.componentSetName,
          variantProperties: component.variantProperties,
          remote: component.remote,
          rootNodeId: node.id
        };
      } else if ((component == null ? void 0 : component.kind) === "COMPONENT_SET" && component.componentSetId) {
        schema2.components[component.componentSetId] = {
          id: component.componentSetId,
          name: (_c = component.componentName) != null ? _c : node.name,
          rootNodeId: node.id
        };
      }
      schema2.nodes[node.id] = uiNode;
      order.push(node.id);
      uiNode.assets = collectImageAssets(node, visual, assetCtx);
      if (shouldExportVectorIcon(node) && opts.includeImageBytes) {
        const assetId = `asset_vec_${hashString(node.id + "|" + node.name + "|" + node.width + "x" + node.height).slice(0, 12)}`;
        if (!assetCtx.byHash.has(assetId)) {
          assetCtx.byHash.set(assetId, assetId);
          schema2.assets[assetId] = {
            assetId,
            sourceNodeId: node.id,
            assetHash: hashString(node.id),
            assetType: "vector",
            format: "PNG",
            name: node.name,
            width: Math.round(node.width),
            height: Math.round(node.height),
            status: "PENDING"
          };
          assetCtx.exportQueue.push({ nodeId: node.id, assetId });
        }
        uiNode.assets.push(assetId);
      }
      if ("children" in node) {
        const kids = node.children;
        uiNode.children = kids.map((c) => c.id);
        for (let i = kids.length - 1; i >= 0; i--) {
          stack.push({ node: kids[i], parentId: node.id, index: i });
        }
      }
      uiNode.hash = hashObject(stripForHash(uiNode));
    }
    for (const id of order) {
      const uiNode = schema2.nodes[id];
      const figmaNode = findFigmaNode(root, id);
      if (!figmaNode) continue;
      uiNode.events = extractInteractions(figmaNode, schema2, schema2.animations);
      for (const iid of uiNode.events) {
        const inter = schema2.interactions[iid];
        const target = inter.action.target;
        if (target && !schema2.nodes[target]) {
          externalTargets.push({ nodeId: id, targetId: target });
          try {
            const t = figma.getNodeById(target);
            if (t && "name" in t) inter.action.targetName = t.name;
          } catch (e) {
          }
        }
      }
    }
    if (opts.includeImageBytes) {
      for (const job of assetCtx.exportQueue) {
        const asset = schema2.assets[job.assetId];
        if (!asset || asset.base64) continue;
        try {
          const figmaNode = findFigmaNode(root, job.nodeId);
          if (!figmaNode) continue;
          const bytes = await exportNodeBytes(figmaNode, asset, opts.maxImageBytes);
          if (bytes) {
            asset.base64 = bytesToBase64(bytes);
            asset.byteLength = bytes.length;
          } else {
            asset.status = "FAILED";
          }
        } catch (e) {
          asset.status = "FAILED";
        }
      }
    }
    schema2.metadata.nodeCount = Object.keys(schema2.nodes).length;
    schema2.metadata.interactionCount = Object.keys(schema2.interactions).length;
    schema2.metadata.assetCount = Object.keys(schema2.assets).length;
    schema2.metadata.variableCount = Object.keys(schema2.variables).length;
    return { schema: schema2, externalTargets };
  }
  var PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
  var MAX_EDITABLE_DIMENSION = 1024;
  function isDecoderSafePng(bytes) {
    if (bytes.length < 29) return false;
    for (let i = 0; i < 8; i++) {
      if (bytes[i] !== PNG_SIGNATURE[i]) return false;
    }
    const bitDepth = bytes[24];
    const colorType = bytes[25];
    const interlace = bytes[28];
    if (bitDepth !== 8) return false;
    if (colorType !== 0 && colorType !== 2 && colorType !== 4 && colorType !== 6) return false;
    if (interlace !== 0) return false;
    return true;
  }
  function pngDimensions(bytes) {
    if (bytes.length < 24) return null;
    const width = (bytes[16] << 24 | bytes[17] << 16 | bytes[18] << 8 | bytes[19]) >>> 0;
    const height = (bytes[20] << 24 | bytes[21] << 16 | bytes[22] << 8 | bytes[23]) >>> 0;
    return { width, height };
  }
  async function exportNodeBytes(node, asset, maxBytes) {
    if (asset.assetType === "image" && "fills" in node) {
      const gm = node;
      if (!isMixed(gm.fills)) {
        const fills = gm.fills;
        const img = fills.find((f) => f.type === "IMAGE" && f.imageHash);
        if (img == null ? void 0 : img.imageHash) {
          const image = figma.getImageByHash(img.imageHash);
          if (image) {
            const bytes2 = await image.getBytesAsync();
            if (bytes2.length <= maxBytes && isDecoderSafePng(bytes2)) {
              const dims = pngDimensions(bytes2);
              if (dims && dims.width <= MAX_EDITABLE_DIMENSION && dims.height <= MAX_EDITABLE_DIMENSION) {
                return bytes2;
              }
            }
          }
        }
      }
    }
    const scale = Math.max(0.1, Math.min(4, 512 / Math.max(1, Math.max(node.width, node.height))));
    let bytes = await node.exportAsync({
      format: "PNG",
      constraint: { type: "SCALE", value: scale }
    });
    if (bytes.length > maxBytes) {
      bytes = await node.exportAsync({
        format: "PNG",
        constraint: { type: "SCALE", value: Math.max(0.1, scale / 2) }
      });
    }
    return bytes;
  }
  function findFigmaNode(root, id) {
    if (root.id === id) return root;
    if (!("children" in root)) return null;
    for (const child of root.children) {
      const found = findFigmaNode(child, id);
      if (found) return found;
    }
    return null;
  }
  function stripForHash(node) {
    const _a2 = node, { hash: _h, metadata: _m, events: _e, assets: _a } = _a2, rest = __objRest(_a2, ["hash", "metadata", "events", "assets"]);
    return rest;
  }

  // src/code.ts
  var state = "DISCONNECTED";
  var schema = null;
  var settings = {
    includeImageBytes: true
  };
  var history = [];
  function post(msg) {
    figma.ui.postMessage(msg);
  }
  function setState(next) {
    state = next;
    post({ kind: "state", state });
  }
  function logActivity(text) {
    history.unshift({ time: Date.now(), text });
    if (history.length > 60) history.pop();
    post({ kind: "activity", entries: history.slice(0, 30) });
  }
  function currentSelectionRoot() {
    const sel = figma.currentPage.selection;
    if (sel.length !== 1) return null;
    const node = sel[0];
    if (!("children" in node) && node.type !== "TEXT") return null;
    return node;
  }
  function summarizeSelection(root, s) {
    let components = 0;
    for (const n of Object.values(s.nodes)) if (n.component) components++;
    return {
      nodeId: root.id,
      name: root.name,
      descendants: Object.keys(s.nodes).length - 1,
      components,
      interactions: Object.keys(s.interactions).length,
      assets: Object.keys(s.assets).length
    };
  }
  async function scanSelection() {
    const root = currentSelectionRoot();
    if (!root) return null;
    const { schema: s } = await extractHierarchy(root, {
      includeImageBytes: settings.includeImageBytes,
      maxImageBytes: 8 * 1024 * 1024
    });
    return s;
  }
  function encodeCode(s) {
    return "LYNK1:" + utf8ToBase64(JSON.stringify(s));
  }
  figma.ui.onmessage = async (msg) => {
    var _a, _b;
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
          summary: summarizeSelection(currentSelectionRoot(), s),
          code: encodeCode(s),
          name: s.metadata.name,
          nodes: nodeCount
        });
        logActivity(`Scanned "${s.metadata.name}" (${nodeCount} nodes)`);
        break;
      }
      case "export-code": {
        try {
          const root = (_a = currentSelectionRoot()) != null ? _a : schema ? figma.getNodeById(schema.metadata.rootId) : null;
          if (!root) {
            post({
              kind: "export-code-result",
              ok: false,
              message: "Select a single UI element to export."
            });
            break;
          }
          const { schema: fresh } = await extractHierarchy(root, {
            includeImageBytes: settings.includeImageBytes,
            maxImageBytes: 8 * 1024 * 1024
          });
          schema = fresh;
          const code = encodeCode(fresh);
          const nodeCount = Object.keys(fresh.nodes).length;
          post({
            kind: "export-code-result",
            ok: true,
            code,
            name: fresh.metadata.name,
            nodes: nodeCount
          });
          logActivity(`Exported code for "${fresh.metadata.name}" (${nodeCount} nodes)`);
        } catch (e) {
          post({ kind: "export-code-result", ok: false, message: String(e) });
        }
        break;
      }
      case "settings": {
        Object.assign(settings, (_b = msg.settings) != null ? _b : {});
        break;
      }
      default:
        break;
    }
  };
  figma.showUI(__html__, { width: 340, height: 520, themeColors: true });
  figma.on("selectionchange", () => {
    if (state === "DISCONNECTED" || state === "SCANNED") {
      const root = currentSelectionRoot();
      if (!root) {
        setState("DISCONNECTED");
        post({ kind: "scan-result", ok: false, empty: true });
      }
    }
  });
})();
