/**
 * LYNK Normalized UI Schema — the versioned intermediate representation
 * shared between the Figma plugin and the Roblox Studio plugin.
 *
 * Figma Adapter → LYNKUISchema → LYNK1 export code → Roblox Adapter → Roblox Instances/React source
 */

export const SCHEMA_VERSION = "1.0.0";
export const LYNK_PLUGIN_VERSION = "1.0.0";

// ---------------------------------------------------------------------------
// Colors & paints
// ---------------------------------------------------------------------------

export interface RGB { r: number; g: number; b: number }
export interface RGBA { r: number; g: number; b: number; a: number }

export type SolidPaint = {
  type: "SOLID";
  color: RGBA;
  opacity: number;
  visible: boolean;
  blendMode: string;
};

export type GradientPaint = {
  type: "GRADIENT_LINEAR" | "GRADIENT_RADIAL" | "GRADIENT_ANGULAR" | "GRADIENT_DIAMOND";
  /** 2x3 affine transform from Figma (gradient space → node space) */
  gradientTransform: number[][];
  stops: Array<{ position: number; color: RGBA }>;
  opacity: number;
  visible: boolean;
  blendMode: string;
};

export type ImagePaint = {
  type: "IMAGE";
  /** LYNK asset id (see assets map). Present when the image bytes are tracked. */
  assetId?: string;
  /** Native Figma imageHash — stable across the file, used for dedupe. */
  imageHash?: string;
  scaleMode: "FILL" | "FIT" | "CROP" | "TILE";
  /** Present when scaleMode === "CROP" */
  imageTransform?: number[][];
  scalingFactor?: number;
  rotation?: number;
  opacity: number;
  visible: boolean;
  blendMode: string;
};

export type PaintLike = SolidPaint | GradientPaint | ImagePaint | { type: string; [k: string]: unknown };

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

export interface ShadowEffect {
  type: "DROP_SHADOW" | "INNER_SHADOW";
  color: RGBA;
  offset: { x: number; y: number };
  radius: number;
  spread: number;
  visible: boolean;
  blendMode: string;
}

export interface BlurEffect {
  type: "LAYER_BLUR" | "BACKGROUND_BLUR";
  radius: number;
  visible: boolean;
}

export type EffectLike = ShadowEffect | BlurEffect | { type: string; [k: string]: unknown };

// ---------------------------------------------------------------------------
// Node data blocks
// ---------------------------------------------------------------------------

export interface LayoutData {
  /** Figma auto-layout: NONE | HORIZONTAL | VERTICAL */
  mode: "NONE" | "HORIZONTAL" | "VERTICAL";
  wrap?: "NO_WRAP" | "WRAP";
  itemSpacing: number;
  counterAxisSpacing?: number;
  padding: { top: number; right: number; bottom: number; left: number };
  primaryAxisAlignItems: string;
  counterAxisAlignItems: string;
  primaryAxisSizingMode: string;
  counterAxisSizingMode: string;
  minWidth?: number | null;
  minHeight?: number | null;
  maxWidth?: number | null;
  maxHeight?: number | null;
  layoutGrow: number;
  layoutAlign: string;
  /** true when positioned absolutely inside an auto-layout parent */
  absolute: boolean;
  constraints?: { vertical: string; horizontal: string };
  clipsContent?: boolean;
  aspectRatio?: number | null;
}

export interface VisualData {
  fills: PaintLike[];
  strokes: PaintLike[];
  strokeWeight: number | { top: number; right: number; bottom: number; left: number };
  strokeAlign: string;
  strokeJoin?: string;
  strokeDashPattern?: number[];
  cornerRadius?: number | null;
  /** individual TL, TR, BR, BL */
  rectangleCornerRadii?: [number, number, number, number];
  effects: EffectLike[];
  opacity: number;
  blendMode: string;
  background?: PaintLike[];
}

export interface TypographyData {
  characters: string;
  fontFamily: string;
  fontStyle: string;
  fontWeight: number;
  fontSize: number;
  lineHeight: { unit: "PIXELS" | "PERCENT" | "AUTO"; value: number | null };
  letterSpacing: { unit: "PIXELS" | "PERCENT"; value: number };
  paragraphSpacing: number;
  paragraphIndent?: number;
  textAlignHorizontal: string;
  textAlignVertical: string;
  textCase: string;
  textDecoration: string;
  textAutoResize: string;
  hangingPunctuation?: boolean;
  hangingList?: boolean;
  hasMissingFont: boolean;
  /** flattened runs when styles differ inside the text node */
  mixed?: boolean;
}

export interface ComponentInfo {
  kind: "COMPONENT" | "COMPONENT_SET" | "INSTANCE";
  componentId?: string;
  componentName?: string;
  componentSetId?: string;
  componentSetName?: string;
  /** e.g. { Variant: "Primary", State: "Hover", Size: "Large" } */
  variantProperties?: Record<string, string>;
  /** exposed component properties (text/boolean/instance-swap) */
  componentProperties?: Record<string, { type: string; value: string | boolean }>;
  remote?: boolean;
  /** variant children names when kind === COMPONENT_SET */
  variants?: string[];
}

export interface VariableBinding {
  /** dotted property path on the node, e.g. "visual.fills[0].color" */
  field: string;
  variableId: string;
  resolvedValue?: unknown;
}

// ---------------------------------------------------------------------------
// Interactions / animations
// ---------------------------------------------------------------------------

export type InteractionEvent =
  | "click" | "tap" | "hover" | "whileHovering" | "mouseEnter" | "mouseLeave"
  | "mouseDown" | "mouseUp" | "press" | "release" | "drag" | "keyDown"
  | "afterDelay" | "mediaHit" | "other";

export interface InteractionAction {
  type:
    | "navigate" | "openOverlay" | "swapOverlay" | "closeOverlay" | "back"
    | "setVariable" | "setVariableMode" | "conditional" | "url" | "node"
    | "unknown";
  /** destination node id (navigate/overlay targets) */
  target?: string;
  targetName?: string;
  /** overlay settings when relevant */
  overlayRelativePosition?: { x: number; y: number };
  navigation?: string;
  url?: string;
  variableAssignment?: { variableId: string; value: unknown };
  /** original Figma action object, preserved verbatim */
  raw?: unknown;
}

export interface UIAnimation {
  id: string;
  nodeId?: string;
  /** SIMPLE | SMART_ANIMATE | SCROLL_ANIMATE | other */
  type: string;
  duration: number;
  delay?: number;
  easing: { type: string; easingFunctionCubicBezier?: [number, number, number, number] };
  /** properties targeted by smart animate, when inferable */
  targetFields?: string[];
  raw?: unknown;
}

export interface Interaction {
  id: string;
  nodeId: string;
  event: InteractionEvent;
  action: InteractionAction;
  animation?: UIAnimation;
  /** raw Figma trigger object */
  trigger?: unknown;
  /** raw Figma reaction object, preserved verbatim */
  raw?: unknown;
}

// ---------------------------------------------------------------------------
// Assets
// ---------------------------------------------------------------------------

export type AssetStatus = "PENDING" | "UPLOADING" | "UPLOADED" | "RESOLVED" | "FAILED" | "REUSED";

export interface AssetDef {
  assetId: string;
  sourceNodeId: string;
  /** Figma imageHash when available, otherwise LYNK content hash */
  assetHash: string;
  assetType: "image" | "vector";
  format: "PNG" | "JPG" | "SVG" | "UNKNOWN";
  name: string;
  width: number;
  height: number;
  byteLength?: number;
  /** base64 payload — only present in transfer messages, stripped after import */
  base64?: string;
  /** filled in by the Roblox side after upload/resolve */
  robloxAssetId?: string;
  status: AssetStatus;
}

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

export interface VariableDef {
  id: string;
  name: string;
  collectionId: string;
  collectionName?: string;
  resolvedType: "COLOR" | "FLOAT" | "STRING" | "BOOLEAN" | "VARIABLE_ALIAS" | string;
  valuesByMode: Record<string, unknown>;
  scopes?: string[];
  description?: string;
  /** set by Roblox side when mapped to a theme/token */
  robloxToken?: string;
}

export interface VariableCollectionDef {
  id: string;
  name: string;
  modes: Array<{ modeId: string; name: string }>;
  defaultModeId: string;
}

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

export interface ComponentDef {
  id: string;
  name: string;
  setId?: string;
  setName?: string;
  variantProperties?: Record<string, string>;
  description?: string;
  remote?: boolean;
  rootNodeId?: string;
}

// ---------------------------------------------------------------------------
// Nodes
// ---------------------------------------------------------------------------

export type LYNKNodeType =
  | "FRAME" | "GROUP" | "SECTION" | "TEXT" | "RECTANGLE" | "ELLIPSE"
  | "VECTOR" | "BOOLEAN_OPERATION" | "STAR" | "POLYGON" | "LINE"
  | "COMPONENT" | "COMPONENT_SET" | "INSTANCE" | "OTHER";

export interface UINode {
  /** stable id — the native Figma node id (e.g. "12:345") */
  id: string;
  parentId: string | null;
  name: string;
  type: LYNKNodeType;
  /** original Figma type string, preserved for fidelity */
  figmaType: string;
  /** sibling index (z-order) */
  index: number;
  visible: boolean;
  locked: boolean;
  opacity: number;
  blendMode: string;
  x: number;
  y: number;
  width: number;
  height: number;
  rotation: number;
  /** absolute bounding box in page space */
  absolute?: { x: number; y: number; width: number; height: number };
  layout: LayoutData | null;
  visual: VisualData | null;
  typography: TypographyData | null;
  /** asset ids referenced by this node's fills / exports */
  assets: string[];
  component: ComponentInfo | null;
  variables: VariableBinding[];
  /** ids into schema.interactions */
  events: string[];
  children: string[];
  /** content hash used for change detection */
  hash: string;
  /** anything the schema could not classify is preserved here */
  metadata: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Schema root
// ---------------------------------------------------------------------------

export interface RevisionEntry {
  revision: number;
  timestamp: number;
  source: "figma" | "roblox" | "server";
  summary: string;
  messageId?: string;
}

export interface SchemaMetadata {
  name: string;
  rootId: string;
  figmaFileName?: string;
  figmaFileKey?: string;
  capturedAt: number;
  pluginVersion: string;
  schemaVersion: string;
  nodeCount: number;
  interactionCount: number;
  assetCount: number;
  variableCount?: number;
}

export interface LYNKUISchema {
  schemaVersion: string;
  metadata: SchemaMetadata;
  nodes: Record<string, UINode>;
  assets: Record<string, AssetDef>;
  variables: Record<string, VariableDef>;
  variableCollections: Record<string, VariableCollectionDef>;
  components: Record<string, ComponentDef>;
  interactions: Record<string, Interaction>;
  animations: Record<string, UIAnimation>;
  revisions: RevisionEntry[];
  /** monotonically increasing revision of the whole document state */
  revision: number;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

export function emptySchema(name: string, rootId: string): LYNKUISchema {
  return {
    schemaVersion: SCHEMA_VERSION,
    metadata: {
      name,
      rootId,
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
    revisions: [],
    revision: 0,
  };
}
