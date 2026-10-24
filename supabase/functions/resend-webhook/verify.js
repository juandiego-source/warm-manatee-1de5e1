// Svix signature check for Resend webhooks.
// Signed content is `${id}.${timestamp}.${rawBody}`.
// The secret is whsec_ plus base64, or the base64 itself.
// Signatures are space-separated v1,<base64> values.

function decodeBase64(value) {
  const pad = String(value || '').replace(/-/g, '+').replace(/_/g, '/')
    + '='.repeat((4 - (String(value || '').length % 4)) % 4);
  const bin = atob(pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function secretBytes(secret) {
  const trimmed = String(secret || '').trim();
  const b64 = trimmed.startsWith('whsec_') ? trimmed.slice('whsec_'.length) : trimmed;
  if (!b64) return new Uint8Array();
  return decodeBase64(b64);
}

function timingSafeEqual(a, b) {
  if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array)) return false;
  if (a.length !== b.length || a.length === 0) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a[i] ^ b[i];
  return out === 0;
}

export async function verifySvixSignature({
  secret,
  id,
  timestamp,
  signature,
  body,
  nowMs = Date.now(),
  toleranceSec = 300,
}) {
  if (!secret || !id || !timestamp || !signature || body == null) {
    return { ok: false, reason: 'missing' };
  }
  const ts = Number(timestamp);
  if (!Number.isFinite(ts)) return { ok: false, reason: 'stale' };
  const skew = Math.abs(Math.floor(nowMs / 1000) - ts);
  if (skew > toleranceSec) return { ok: false, reason: 'stale' };
  const keyBytes = secretBytes(secret);
  if (!keyBytes.length) return { ok: false, reason: 'secret' };
  const key = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signed = new TextEncoder().encode(`${id}.${timestamp}.${body}`);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, signed));
  const parts = String(signature).split(' ').map((part) => part.trim()).filter(Boolean);
  for (const part of parts) {
    const comma = part.indexOf(',');
    if (comma < 1) continue;
    const version = part.slice(0, comma);
    if (version !== 'v1') continue;
    let got;
    try {
      got = decodeBase64(part.slice(comma + 1));
    } catch (_err) {
      continue;
    }
    if (timingSafeEqual(mac, got)) return { ok: true };
  }
  return { ok: false, reason: 'mismatch' };
}
