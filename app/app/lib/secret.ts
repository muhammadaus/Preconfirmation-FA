import { keccak256, encodeAbiParameters, type Hex } from "viem";

/**
 * Generate a 128-bit (16-byte) random secret, returned as a 0x-prefixed
 * bytes32 (right-padded with zeros on-chain when passed as bytes32).
 *
 * Uses the Web Crypto API — available in browsers, Node 18+, and Vercel edge.
 * The secret NEVER leaves the sender's browser until they share it out-of-band.
 */
export function generateSecret(): Hex {
  const buf = new Uint8Array(16);
  crypto.getRandomValues(buf);
  // Pad to 32 bytes (bytes32 on-chain) — right-padded with zeros.
  const padded = new Uint8Array(32);
  padded.set(buf);
  return ("0x" + Array.from(padded, (b) => b.toString(16).padStart(2, "0")).join("")) as Hex;
}

/**
 * Compute the on-chain commitment: keccak256(abi.encode(id, secret)).
 * Mirrors PendingTransfers._computeCommit exactly.
 */
export function computeCommit(id: Hex, secret: Hex): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }],
      [id, secret]
    )
  );
}

// ─── Crockford base32 encoding ──────────────────────────────────────────
// Crockford base32 uses 0-9 A-V (no I, L, O, U to avoid ambiguity).
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/**
 * Encode raw bytes (Uint8Array) to Crockford base32 string.
 */
function toBase32(data: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of data) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += CROCKFORD[(value >>> bits) & 0x1f];
    }
  }
  if (bits > 0) {
    out += CROCKFORD[(value << (5 - bits)) & 0x1f];
  }
  return out;
}

/**
 * Decode a Crockford base32 string back to bytes.
 * Strips dashes and uppercases first. Handles common substitutions
 * (O→0, I/L→1) per the Crockford spec.
 */
function fromBase32(str: string): Uint8Array {
  const clean = str
    .replace(/-/g, "")
    .toUpperCase()
    .replace(/O/g, "0")
    .replace(/[IL]/g, "1");
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    const idx = CROCKFORD.indexOf(ch);
    if (idx === -1) throw new Error(`Invalid base32 char: ${ch}`);
    value = (value << 5) | idx;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      out.push((value >>> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}

/**
 * Format a 128-bit secret as a human-readable Crockford base32 short code.
 * Output: "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX" (~26 base32 chars, 6 groups).
 */
export function secretToShortCode(secret: Hex): string {
  // Only encode the first 16 bytes (128 bits of randomness).
  const hex = secret.slice(2, 34); // 32 hex chars = 16 bytes
  const bytes = new Uint8Array(
    hex.match(/.{2}/g)!.map((b) => parseInt(b, 16))
  );
  const raw = toBase32(bytes);
  // Chunk into groups of 4 for readability.
  return raw.match(/.{1,4}/g)!.join("-");
}

/**
 * Parse a short code back into a bytes32 secret (right-padded).
 */
export function shortCodeToSecret(code: string): Hex {
  const bytes = fromBase32(code);
  const padded = new Uint8Array(32);
  padded.set(bytes);
  return ("0x" + Array.from(padded, (b) => b.toString(16).padStart(2, "0")).join("")) as Hex;
}
