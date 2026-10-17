/** Base64 encoder that works inside the Figma plugin sandbox (no btoa/atob dependency). */

const CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function bytesToBase64(bytes: Uint8Array): string {
  let out = "";
  const len = bytes.length;
  for (let i = 0; i < len; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < len ? bytes[i + 1] : 0;
    const b2 = i + 2 < len ? bytes[i + 2] : 0;
    out += CHARS[b0 >> 2];
    out += CHARS[((b0 & 3) << 4) | (b1 >> 4)];
    out += i + 1 < len ? CHARS[((b1 & 15) << 2) | (b2 >> 6)] : "=";
    out += i + 2 < len ? CHARS[b2 & 63] : "=";
  }
  return out;
}

/** Encode a JS string as UTF-8, then base64 (for embedding JSON in a LYNK code). */
export function utf8ToBase64(str: string): string {
  const bytes: number[] = [];
  for (let i = 0; i < str.length; i++) {
    const code = str.charCodeAt(i);
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
      const next = str.charCodeAt(i + 1);
      const cp = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
      i++;
      bytes.push(
        0xf0 | (cp >> 18),
        0x80 | ((cp >> 12) & 0x3f),
        0x80 | ((cp >> 6) & 0x3f),
        0x80 | (cp & 0x3f)
      );
    } else {
      bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return bytesToBase64(new Uint8Array(bytes));
}

export function base64ToBytes(b64: string): Uint8Array {
  const clean = b64.replace(/[^A-Za-z0-9+/]/g, "");
  const len = clean.length;
  const bytesLength = Math.floor((len * 3) / 4);
  const bytes = new Uint8Array(bytesLength);
  let p = 0;
  for (let i = 0; i < len; i += 4) {
    const c0 = CHARS.indexOf(clean[i]);
    const c1 = CHARS.indexOf(clean[i + 1]);
    const c2 = i + 2 < len ? CHARS.indexOf(clean[i + 2]) : 0;
    const c3 = i + 3 < len ? CHARS.indexOf(clean[i + 3]) : 0;
    bytes[p++] = (c0 << 2) | (c1 >> 4);
    if (i + 2 < len) bytes[p++] = ((c1 & 15) << 4) | (c2 >> 2);
    if (i + 3 < len) bytes[p++] = ((c2 & 3) << 6) | c3;
  }
  return p === bytesLength ? bytes : bytes.slice(0, p);
}
