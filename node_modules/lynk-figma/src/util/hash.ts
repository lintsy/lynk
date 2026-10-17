/**
 * Deterministic 128-bit content hash (FNV-1a based, 4x32 lanes).
 * Used for node change detection and asset dedupe fallback.
 */

function fnv(bytes: Uint8Array, seed: number): number {
  let h = seed >>> 0;
  for (let i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

export function hashBytes(bytes: Uint8Array): string {
  const h0 = fnv(bytes, 0x811c9dc5);
  const h1 = fnv(bytes, 0x9e3779b1);
  const h2 = fnv(bytes, 0x85ebca6b);
  const h3 = fnv(bytes, 0xc2b2ae35);
  return [h0, h1, h2, h3].map((h) => h.toString(16).padStart(8, "0")).join("");
}

export function hashString(s: string): string {
  let bytes: Uint8Array;
  // encode as UTF-8
  const enc: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c < 0x80) enc.push(c);
    else if (c < 0x800) {
      enc.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const c2 = s.charCodeAt(++i);
      c = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
      enc.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    } else {
      enc.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
  }
  bytes = new Uint8Array(enc);
  return hashBytes(bytes);
}

/**
 * Stable JSON stringify: object keys sorted recursively so equal structures
 * always produce equal hashes.
 */
export function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value) ?? "null";
  if (Array.isArray(value)) return "[" + value.map(stableStringify).join(",") + "]";
  const obj = value as Record<string, unknown>;
  const keys = Object.keys(obj).sort();
  const parts: string[] = [];
  for (const k of keys) {
    const v = obj[k];
    if (v === undefined) continue;
    parts.push(JSON.stringify(k) + ":" + stableStringify(v));
  }
  return "{" + parts.join(",") + "}";
}

export function hashObject(value: unknown): string {
  return hashString(stableStringify(value));
}
