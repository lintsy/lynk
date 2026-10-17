/**
 * LYNK Figma Adapter — extracts a Figma node hierarchy into a LYNKUISchema.
 *
 * Honors the three data classes LYNK cares about:
 *   1. directly exposed by the Figma plugin API  (copied faithfully)
 *   2. inferable                                  (derived, flagged in metadata)
 *   3. runtime/gameplay behavior                  (NOT captured — Roblox owns it)
 */

import {
  type LYNKUISchema,
  type UINode,
  type LYNKNodeType,
  type LayoutData,
  type VisualData,
  type TypographyData,
  type PaintLike,
  type EffectLike,
  type RGBA,
  type ComponentInfo,
  type VariableBinding,
  type Interaction,
  type InteractionEvent,
  type InteractionAction,
  type UIAnimation,
  type AssetDef,
  type VariableDef,
  type VariableCollectionDef,
  SCHEMA_VERSION,
  LYNK_PLUGIN_VERSION,
} from "../../../shared/schema";
import { hashObject, hashString } from "../util/hash";
import { bytesToBase64 } from "../util/base64";

// ---------------------------------------------------------------------------
// typing helpers (Figma's SceneNode union is intentionally narrow per node)
// ---------------------------------------------------------------------------

function isMixed(v: unknown): v is typeof figma.mixed {
  return v === figma.mixed;
}

function num(v: unknown, fallback = 0): number {
  return typeof v === "number" && isFinite(v) ? v : fallback;
}

function getOpacity(n: SceneNode): number {
  return "opacity" in n ? num((n as BlendMixin).opacity, 1) : 1;
}

function getBlendMode(n: SceneNode): string {
  return "blendMode" in n ? String((n as BlendMixin).blendMode ?? "NORMAL") : "NORMAL";
}

function getRotation(n: SceneNode): number {
  return "rotation" in n ? num((n as LayoutMixin).rotation, 0) : 0;
}

function getLocked(n: SceneNode): boolean {
  return "locked" in n ? Boolean((n as { locked: boolean }).locked) : false;
}

function getEffects(n: SceneNode): readonly Effect[] {
  return "effects" in n ? (n as BlendMixin).effects : [];
}

function colorToRGBA(c: { r: number; g: number; b: number; a?: number }): RGBA {
  return { r: c.r, g: c.g, b: c.b, a: c.a === undefined ? 1 : c.a };
}

function mapType(figmaType: string): LYNKNodeType {
  switch (figmaType) {
    case "FRAME": return "FRAME";
    case "GROUP": return "GROUP";
    case "SECTION": return "SECTION";
    case "TEXT": return "TEXT";
    case "RECTANGLE": return "RECTANGLE";
    case "ELLIPSE": return "ELLIPSE";
    case "VECTOR": return "VECTOR";
    case "BOOLEAN_OPERATION": return "BOOLEAN_OPERATION";
    case "STAR": return "STAR";
    case "POLYGON": return "POLYGON";
    case "LINE": return "LINE";
    case "COMPONENT": return "COMPONENT";
    case "COMPONENT_SET": return "COMPONENT_SET";
    case "INSTANCE": return "INSTANCE";
    default: return "OTHER";
  }
}

// ---------------------------------------------------------------------------
// paints / effects
// ---------------------------------------------------------------------------

function serializePaint(paint: Paint): PaintLike {
  const base = {
    opacity: num((paint as { opacity?: number }).opacity, 1),
    visible: (paint as { visible?: boolean }).visible !== false,
    blendMode: String((paint as { blendMode?: string }).blendMode ?? "NORMAL"),
  };
  switch (paint.type) {
    case "SOLID":
      return { type: "SOLID", color: colorToRGBA(paint.color), ...base };
    case "GRADIENT_LINEAR":
    case "GRADIENT_RADIAL":
    case "GRADIENT_ANGULAR":
    case "GRADIENT_DIAMOND":
      return {
        type: paint.type,
        gradientTransform: paint.gradientTransform.map((row) => [...row]),
        stops: paint.gradientStops.map((s) => ({ position: s.position, color: colorToRGBA(s.color) })),
        ...base,
      };
    case "IMAGE":
      return {
        type: "IMAGE",
        imageHash: paint.imageHash ?? undefined,
        scaleMode: paint.scaleMode,
        imageTransform: paint.imageTransform ? paint.imageTransform.map((r) => [...r]) : undefined,
        scalingFactor: paint.scalingFactor,
        rotation: paint.rotation,
        ...base,
      };
    case "VIDEO":
      return { type: "VIDEO", ...(paint as unknown as Record<string, unknown>), ...base };
    default:
      return { type: (paint as { type: string }).type, ...base };
  }
}

function serializeEffects(effects: readonly Effect[]): EffectLike[] {
  const out: EffectLike[] = [];
  for (const e of effects) {
    if (e.type === "DROP_SHADOW" || e.type === "INNER_SHADOW") {
      out.push({
        type: e.type,
        color: colorToRGBA(e.color),
        offset: { x: e.offset.x, y: e.offset.y },
        radius: e.radius,
        spread: num(e.spread, 0),
        visible: e.visible !== false,
        blendMode: String(e.blendMode ?? "NORMAL"),
      });
    } else if (e.type === "LAYER_BLUR" || e.type === "BACKGROUND_BLUR") {
      out.push({ type: e.type, radius: e.radius, visible: e.visible !== false });
    } else {
      out.push(e as unknown as EffectLike);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// layout
// ---------------------------------------------------------------------------

function extractLayout(node: SceneNode): LayoutData | null {
  if (!("layoutMode" in node)) return null;
  const n = node as FrameNode;
  const lm = n.layoutMode;
  if (!lm) return null;
  const layout: LayoutData = {
    mode: lm as LayoutData["mode"],
    itemSpacing: num(n.itemSpacing, 0),
    padding: {
      top: num(n.paddingTop, 0),
      right: num(n.paddingRight, 0),
      bottom: num(n.paddingBottom, 0),
      left: num(n.paddingLeft, 0),
    },
    primaryAxisAlignItems: String(n.primaryAxisAlignItems ?? "MIN"),
    counterAxisAlignItems: String(n.counterAxisAlignItems ?? "MIN"),
    primaryAxisSizingMode: String(n.primaryAxisSizingMode ?? "AUTO"),
    counterAxisSizingMode: String(n.counterAxisSizingMode ?? "AUTO"),
    layoutGrow: num(n.layoutGrow, 0),
    layoutAlign: String(n.layoutAlign ?? "INHERIT"),
    absolute: n.layoutPositioning === "ABSOLUTE",
    wrap: n.layoutWrap as LayoutData["wrap"],
    counterAxisSpacing: num(n.counterAxisSpacing, 0),
    minWidth: n.minWidth ?? null,
    minHeight: n.minHeight ?? null,
    maxWidth: n.maxWidth ?? null,
    maxHeight: n.maxHeight ?? null,
    clipsContent: n.clipsContent,
    constraints: { vertical: n.constraints.vertical, horizontal: n.constraints.horizontal },
    aspectRatio: (n as unknown as { aspectRatio?: number | null }).aspectRatio ?? null,
  };
  return layout;
}

// ---------------------------------------------------------------------------
// visual
// ---------------------------------------------------------------------------

function extractVisual(node: SceneNode): VisualData | null {
  const hasFills = "fills" in node;
  const hasStrokes = "strokes" in node;
  if (!hasFills && !hasStrokes && !("effects" in node)) return null;

  const gm = node as GeometryMixin;
  const v: VisualData = {
    fills: hasFills && !isMixed(gm.fills) ? (gm.fills as readonly Paint[]).map(serializePaint) : [],
    strokes: hasStrokes && !isMixed(gm.strokes) ? (gm.strokes as readonly Paint[]).map(serializePaint) : [],
    strokeWeight: 0,
    strokeAlign: "INSIDE",
    effects: serializeEffects(getEffects(node)),
    opacity: getOpacity(node),
    blendMode: getBlendMode(node),
  };

  if (hasStrokes) {
    if (!isMixed(gm.strokeWeight)) {
      v.strokeWeight = num(gm.strokeWeight, 0);
    } else {
      const s = gm as unknown as {
        strokeTopWeight?: number; strokeRightWeight?: number;
        strokeBottomWeight?: number; strokeLeftWeight?: number;
      };
      v.strokeWeight = {
        top: num(s.strokeTopWeight, 0),
        right: num(s.strokeRightWeight, 0),
        bottom: num(s.strokeBottomWeight, 0),
        left: num(s.strokeLeftWeight, 0),
      };
    }
    v.strokeAlign = String(gm.strokeAlign ?? "INSIDE");
    if ("strokeJoin" in gm) v.strokeJoin = String((gm as { strokeJoin: string }).strokeJoin);
    const dash = (gm as unknown as { strokeDashPattern?: readonly number[] }).strokeDashPattern;
    if (dash && dash.length) v.strokeDashPattern = [...dash];
  }

  if ("cornerRadius" in node) {
    const r = node as RectangleNode | FrameNode | ComponentNode | InstanceNode;
    if (!isMixed(r.cornerRadius)) {
      v.cornerRadius = num(r.cornerRadius, 0);
    } else {
      v.cornerRadius = null;
      v.rectangleCornerRadii = [
        num(r.topLeftRadius, 0),
        num(r.topRightRadius, 0),
        num(r.bottomRightRadius, 0),
        num(r.bottomLeftRadius, 0),
      ];
    }
  }

  if ("backgrounds" in node && !isMixed((node as FrameNode).backgrounds)) {
    const bgs = (node as FrameNode).backgrounds as readonly Paint[];
    if (bgs.length) v.background = bgs.map(serializePaint);
  }
  return v;
}

// ---------------------------------------------------------------------------
// typography
// ---------------------------------------------------------------------------

function extractTypography(node: TextNode): TypographyData {
  const t: TypographyData = {
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
    hasMissingFont: node.hasMissingFont,
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
    } catch { /* empty text node */ }
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

// ---------------------------------------------------------------------------
// components
// ---------------------------------------------------------------------------

async function extractComponent(node: SceneNode): Promise<ComponentInfo | null> {
  if (node.type === "INSTANCE") {
    const inst = node as InstanceNode;
    const info: ComponentInfo = { kind: "INSTANCE" };
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
    } catch { /* library component unavailable */ }
    const vp = inst.variantProperties;
    if (vp) info.variantProperties = { ...vp };
    const props = inst.componentProperties;
    if (props) {
      info.componentProperties = {};
      for (const key of Object.keys(props)) {
        info.componentProperties[key] = {
          type: props[key].type,
          value: props[key].value as string | boolean,
        };
      }
    }
    return info;
  }
  if (node.type === "COMPONENT") {
    const c = node as ComponentNode;
    const info: ComponentInfo = { kind: "COMPONENT", componentId: c.id, componentName: c.name };
    if (c.variantProperties) info.variantProperties = { ...c.variantProperties };
    const set = c.parent;
    if (set && set.type === "COMPONENT_SET") {
      info.componentSetId = set.id;
      info.componentSetName = set.name;
    }
    return info;
  }
  if (node.type === "COMPONENT_SET") {
    const set = node as ComponentSetNode;
    return {
      kind: "COMPONENT_SET",
      componentSetId: set.id,
      componentName: set.name,
      variants: set.children.map((c) => c.name),
    };
  }
  return null;
}

// ---------------------------------------------------------------------------
// variables
// ---------------------------------------------------------------------------

async function loadLocalVariables(): Promise<{
  byId: Map<string, VariableDef>;
  collections: Record<string, VariableCollectionDef>;
}> {
  const byId = new Map<string, VariableDef>();
  const collections: Record<string, VariableCollectionDef> = {};
  try {
    const vars = await figma.variables.getLocalVariablesAsync();
    const colls = await figma.variables.getLocalVariableCollectionsAsync();
    for (const c of colls) {
      collections[c.id] = {
        id: c.id,
        name: c.name,
        modes: c.modes.map((m) => ({ modeId: m.modeId, name: m.name })),
        defaultModeId: c.defaultModeId,
      };
    }
    for (const v of vars) {
      const values: Record<string, unknown> = {};
      for (const [modeId, value] of Object.entries(v.valuesByMode)) values[modeId] = value;
      byId.set(v.id, {
        id: v.id,
        name: v.name,
        collectionId: v.variableCollectionId,
        collectionName: collections[v.variableCollectionId]?.name,
        resolvedType: v.resolvedType,
        valuesByMode: values,
        scopes: [...v.scopes],
        description: v.description,
      });
    }
  } catch { /* variables API unavailable */ }
  return { byId, collections };
}

function collectBoundVariables(node: SceneNode, ctxVars: Map<string, VariableDef>): VariableBinding[] {
  const out: VariableBinding[] = [];
  const bv = (node as unknown as { boundVariables?: Record<string, unknown> }).boundVariables;
  if (!bv) return out;
  for (const [field, alias] of Object.entries(bv)) {
    if (!alias) continue;
    const aliases = Array.isArray(alias) ? alias : [alias];
    for (const a of aliases) {
      const id = (a as { id?: string })?.id;
      if (!id) continue;
      out.push({ field, variableId: id, resolvedValue: ctxVars.get(id)?.valuesByMode });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// interactions
// ---------------------------------------------------------------------------

type ReactionLike = { trigger?: Trigger | null; action?: Action; actions?: Action[]; transition?: Transition | null };

function getReactions(node: SceneNode): readonly ReactionLike[] {
  const r = (node as unknown as { reactions?: readonly ReactionLike[] }).reactions;
  return r ?? [];
}

function mapTriggerEvent(trigger: Trigger | null | undefined): InteractionEvent {
  const type = trigger ? (trigger as { type: string }).type : "";
  switch (type) {
    case "ON_CLICK": return "click";
    case "ON_HOVER": return "whileHovering";
    case "ON_PRESS": return "press";
    case "ON_DRAG": return "drag";
    case "ON_KEY_DOWN": return "keyDown";
    case "AFTER_TIMEOUT": return "afterDelay";
    case "MOUSE_ENTER": return "mouseEnter";
    case "MOUSE_LEAVE": return "mouseLeave";
    case "MOUSE_UP": return "mouseUp";
    case "MOUSE_DOWN": return "mouseDown";
    case "ON_MEDIA_HIT": return "mediaHit";
    default: return "other";
  }
}

function serializeTransition(t: Transition | null | undefined, id: string, nodeId: string): UIAnimation | null {
  if (!t) return null;
  const anim: UIAnimation = {
    id,
    nodeId,
    type: String(t.type),
    duration: num(t.duration, 0),
    easing: { type: String(t.easing?.type ?? "EASE_OUT") },
    raw: t,
  };
  const bez = t.easing?.easingFunctionCubicBezier;
  if (bez) {
    anim.easing = {
      type: "CUSTOM_CUBIC_BEZIER",
      easingFunctionCubicBezier: [bez.x1, bez.y1, bez.x2, bez.y2],
    };
  }
  if ((t as { direction?: string }).direction) {
    anim.targetFields = [`direction:${(t as { direction?: string }).direction}`];
  }
  return anim;
}

function mapAction(action: Action | undefined, schema: LYNKUISchema): InteractionAction {
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
          variableId: action.variableId ?? "",
          value: action.variableValue,
        },
        raw: action,
      };
    case "SET_VARIABLE_MODE":
      return { type: "setVariable", raw: action };
    case "CONDITIONAL":
      return { type: "conditional", raw: action };
    case "NODE": {
      const destId = action.destinationId ?? undefined;
      const payload: InteractionAction = {
        type: action.navigation === "OVERLAY" ? "openOverlay" : "navigate",
        target: destId,
        navigation: action.navigation,
        raw: action,
      };
      if (destId && schema.nodes[destId]) payload.targetName = schema.nodes[destId].name;
      if (action.navigation === "OVERLAY" && action.overlayRelativePosition) {
        payload.overlayRelativePosition = {
          x: action.overlayRelativePosition.x,
          y: action.overlayRelativePosition.y,
        };
      }
      return payload;
    }
    default:
      return { type: "unknown", raw: action };
  }
}

function extractInteractions(
  node: SceneNode,
  schema: LYNKUISchema,
  animations: Record<string, UIAnimation>
): string[] {
  const reactions = getReactions(node);
  const ids: string[] = [];
  let order = 0;
  for (const r of reactions) {
    const event = mapTriggerEvent(r.trigger);
    const actions = r.actions ?? (r.action ? [r.action] : []);
    if (actions.length === 0) {
      // trigger with no action: still record the event definition
      const interaction: Interaction = {
        id: `${node.id}#rx${order}`,
        nodeId: node.id,
        event,
        action: { type: "unknown" },
        trigger: r.trigger,
        raw: r,
      };
      schema.interactions[interaction.id] = interaction;
      ids.push(interaction.id);
      order++;
      continue;
    }
    for (const a of actions) {
      const interaction: Interaction = {
        id: `${node.id}#rx${order++}`,
        nodeId: node.id,
        event,
        action: mapAction(a, schema),
        trigger: r.trigger,
        raw: r,
      };
      const transition =
        (a as { transition?: Transition | null }).transition ??
        (r.transition as Transition | null | undefined);
      if (transition) {
        const anim = serializeTransition(transition, `${node.id}#anim${order}`, node.id);
        if (anim) {
          animations[anim.id] = anim;
          interaction.animation = anim;
        }
      }
      schema.interactions[interaction.id] = interaction;
      ids.push(interaction.id);
    }
  }
  return ids;
}

// ---------------------------------------------------------------------------
// assets
// ---------------------------------------------------------------------------

interface AssetCtx {
  byHash: Map<string, string>;
  assets: Record<string, AssetDef>;
  exportQueue: Array<{ nodeId: string; assetId: string }>;
}

function collectImageAssets(node: SceneNode, visual: VisualData | null, ctx: AssetCtx): string[] {
  const ids: string[] = [];
  if (!visual) return ids;
  const paints = [...visual.fills, ...(visual.background ?? [])];
  for (const paint of paints) {
    if (paint.type !== "IMAGE") continue;
    const p = paint as Extract<PaintLike, { type: "IMAGE" }>;
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
        status: "PENDING",
      };
      ctx.exportQueue.push({ nodeId: node.id, assetId });
    }
    p.assetId = assetId;
    if (!ids.includes(assetId)) ids.push(assetId);
  }
  return ids;
}

function shouldExportVectorIcon(node: SceneNode): boolean {
  const t = node.type;
  return (
    (t === "VECTOR" || t === "BOOLEAN_OPERATION" || t === "STAR" || t === "POLYGON" || t === "ELLIPSE" || t === "LINE") &&
    node.width <= 512 && node.height <= 512
  );
}

// ---------------------------------------------------------------------------
// main extraction
// ---------------------------------------------------------------------------

export interface ExtractOptions {
  includeImageBytes: boolean;
  maxImageBytes: number;
}

export interface ExtractResult {
  schema: LYNKUISchema;
  externalTargets: Array<{ nodeId: string; targetId: string }>;
}

export async function extractHierarchy(root: SceneNode, opts: ExtractOptions): Promise<ExtractResult> {
  const schema: LYNKUISchema = {
    schemaVersion: SCHEMA_VERSION,
    metadata: {
      name: root.name,
      rootId: root.id,
      capturedAt: Date.now(),
      pluginVersion: LYNK_PLUGIN_VERSION,
      schemaVersion: SCHEMA_VERSION,
      nodeCount: 0,
      interactionCount: 0,
      assetCount: 0,
    },
    nodes: {},
    assets: {},
    variables: {},
    variableCollections: {},
    components: {},
    interactions: {},
    animations: {},
    revisions: [{ revision: 0, timestamp: Date.now(), source: "figma", summary: `Captured "${root.name}"` }],
    revision: 0,
  };

  try {
    schema.metadata.figmaFileName = figma.root.name;
  } catch { /* ignore */ }
  try {
    const key = (figma.fileKey ?? null) as string | null;
    if (key) schema.metadata.figmaFileKey = key;
  } catch { /* plugins running in drafts have no fileKey */ }

  const { byId: varById, collections } = await loadLocalVariables();
  schema.variableCollections = collections;
  for (const [id, v] of varById) schema.variables[id] = v;

  const assetCtx: AssetCtx = { byHash: new Map(), assets: schema.assets, exportQueue: [] };
  const externalTargets: Array<{ nodeId: string; targetId: string }> = [];

  // ---- pass 1: nodes
  const stack: Array<{ node: SceneNode; parentId: string | null; index: number }> = [
    { node: root, parentId: null, index: 0 },
  ];
  const order: string[] = [];
  while (stack.length) {
    const { node, parentId, index } = stack.pop()!;
    const layout = extractLayout(node);
    const visual = extractVisual(node);
    const typography = node.type === "TEXT" ? extractTypography(node as TextNode) : null;
    const component = await extractComponent(node);
    const variables = collectBoundVariables(node, varById);

    const uiNode: UINode = {
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
      metadata: {},
    };

    if ("absoluteBoundingBox" in node && node.absoluteBoundingBox) {
      const b = node.absoluteBoundingBox;
      uiNode.absolute = { x: b.x, y: b.y, width: b.width, height: b.height };
    }

    if (component?.kind === "COMPONENT" && component.componentId) {
      schema.components[component.componentId] = {
        id: component.componentId,
        name: component.componentName ?? node.name,
        setId: component.componentSetId,
        setName: component.componentSetName,
        variantProperties: component.variantProperties,
        remote: component.remote,
        rootNodeId: node.id,
      };
    } else if (component?.kind === "COMPONENT_SET" && component.componentSetId) {
      schema.components[component.componentSetId] = {
        id: component.componentSetId,
        name: component.componentName ?? node.name,
        rootNodeId: node.id,
      };
    }

    schema.nodes[node.id] = uiNode;
    order.push(node.id);

    uiNode.assets = collectImageAssets(node, visual, assetCtx);

    if (shouldExportVectorIcon(node) && opts.includeImageBytes) {
      const assetId = `asset_vec_${hashString(node.id + "|" + node.name + "|" + node.width + "x" + node.height).slice(0, 12)}`;
      if (!assetCtx.byHash.has(assetId)) {
        assetCtx.byHash.set(assetId, assetId);
        schema.assets[assetId] = {
          assetId,
          sourceNodeId: node.id,
          assetHash: hashString(node.id),
          assetType: "vector",
          format: "PNG",
          name: node.name,
          width: Math.round(node.width),
          height: Math.round(node.height),
          status: "PENDING",
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

  // ---- pass 2: interactions
  for (const id of order) {
    const uiNode = schema.nodes[id];
    const figmaNode = findFigmaNode(root, id);
    if (!figmaNode) continue;
    uiNode.events = extractInteractions(figmaNode, schema, schema.animations);
    for (const iid of uiNode.events) {
      const inter = schema.interactions[iid];
      const target = inter.action.target;
      if (target && !schema.nodes[target]) {
        externalTargets.push({ nodeId: id, targetId: target });
        try {
          const t = figma.getNodeById(target);
          if (t && "name" in t) inter.action.targetName = (t as { name: string }).name;
        } catch { /* external node */ }
      }
    }
  }

  // ---- pass 3: asset bytes
  if (opts.includeImageBytes) {
    for (const job of assetCtx.exportQueue) {
      const asset = schema.assets[job.assetId];
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
      } catch {
        asset.status = "FAILED";
      }
    }
  }

  schema.metadata.nodeCount = Object.keys(schema.nodes).length;
  schema.metadata.interactionCount = Object.keys(schema.interactions).length;
  schema.metadata.assetCount = Object.keys(schema.assets).length;
  schema.metadata.variableCount = Object.keys(schema.variables).length;

  return { schema, externalTargets };
}

const PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];

/** Roblox `EditableImage` cannot exceed 1024x1024 and cannot be resized. */
const MAX_EDITABLE_DIMENSION = 1024;

/**
 * The Roblox-side decoder only understands 8-bit, non-interlaced PNG with the
 * truecolor/grayscale color types (no palette). Raw `getBytesAsync()` bytes can
 * be JPEG/GIF or a palette/16-bit/interlaced PNG, which would fail to upload.
 * Only pass raw bytes through when we know the decoder can handle them.
 */
function isDecoderSafePng(bytes: Uint8Array): boolean {
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

/** Reads width/height from the PNG IHDR chunk (bytes 16-23, big-endian). */
function pngDimensions(bytes: Uint8Array): { width: number; height: number } | null {
  if (bytes.length < 24) return null;
  const width = ((bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19]) >>> 0;
  const height = ((bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23]) >>> 0;
  return { width, height };
}

async function exportNodeBytes(node: SceneNode, asset: AssetDef, maxBytes: number): Promise<Uint8Array | null> {
  if (asset.assetType === "image" && "fills" in node) {
    const gm = node as GeometryMixin;
    if (!isMixed(gm.fills)) {
      const fills = gm.fills as readonly Paint[];
      const img = fills.find((f) => f.type === "IMAGE" && f.imageHash) as ImagePaint | undefined;
      if (img?.imageHash) {
        const image = figma.getImageByHash(img.imageHash);
        if (image) {
          const bytes = await image.getBytesAsync();
          if (bytes.length <= maxBytes && isDecoderSafePng(bytes)) {
            const dims = pngDimensions(bytes);
            if (dims && dims.width <= MAX_EDITABLE_DIMENSION && dims.height <= MAX_EDITABLE_DIMENSION) {
              return bytes;
            }
          }
        }
      }
    }
  }
  const scale = Math.max(0.1, Math.min(4, 512 / Math.max(1, Math.max(node.width, node.height))));
  let bytes = await node.exportAsync({
    format: "PNG",
    constraint: { type: "SCALE", value: scale },
  });
  if (bytes.length > maxBytes) {
    bytes = await node.exportAsync({
      format: "PNG",
      constraint: { type: "SCALE", value: Math.max(0.1, scale / 2) },
    });
  }
  return bytes;
}

function findFigmaNode(root: SceneNode, id: string): SceneNode | null {
  if (root.id === id) return root;
  if (!("children" in root)) return null;
  for (const child of root.children) {
    const found = findFigmaNode(child, id);
    if (found) return found;
  }
  return null;
}

function stripForHash(node: UINode): unknown {
  const { hash: _h, metadata: _m, events: _e, assets: _a, ...rest } = node;
  return rest;
}

// ---------------------------------------------------------------------------
// single-node snapshot (change detection)
// ---------------------------------------------------------------------------

export function snapshotNode(node: SceneNode): unknown {
  return {
    name: node.name,
    visible: node.visible,
    locked: getLocked(node),
    opacity: getOpacity(node),
    blendMode: getBlendMode(node),
    x: num(node.x),
    y: num(node.y),
    width: num(node.width),
    height: num(node.height),
    rotation: getRotation(node),
    layout: extractLayout(node),
    visual: extractVisual(node),
    typography: node.type === "TEXT" ? extractTypography(node as TextNode) : null,
    children: "children" in node ? node.children.map((c) => c.id) : [],
  };
}

export { extractLayout, extractVisual, extractTypography, serializePaint, serializeEffects, mapType };
