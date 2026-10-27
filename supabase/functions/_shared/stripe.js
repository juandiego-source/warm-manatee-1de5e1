// Stripe Checkout helpers for Sumak Ops.
// The secret key never leaves the Edge Function. Card numbers are entered
// on checkout.stripe.com. This file has no Deno-only APIs so the tests can
// import it from Node.

export const DEFAULT_FEE_PERCENT = 3;
export const APP_ORIGIN = 'https://warm-manatee-1de5e1.netlify.app';
export const CHECKOUT_HOST = 'checkout.stripe.com';
export const MIN_CHARGE_CENTS = 50;
export const MAX_FEE_PERCENT = 25;

export class StripeFlowError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.name = 'StripeFlowError';
    this.status = status;
  }
}

export function dollarsToCents(amount) {
  if (typeof amount === 'number') {
    if (!Number.isFinite(amount)) return null;
    return Math.round((amount + Number.EPSILON) * 100);
  }
  const text = String(amount ?? '').trim();
  if (!/^-?\d+(\.\d+)?$/.test(text)) return null;
  const negative = text.startsWith('-');
  const [whole, frac = ''] = text.replace('-', '').split('.');
  const head = (frac + '000').slice(0, 3);
  let cents = Number(whole) * 100 + Number(head.slice(0, 2));
  if (head[2] >= '5') cents += 1;
  if (!Number.isSafeInteger(cents)) return null;
  return negative ? -cents : cents;
}

export function centsToDollars(cents) {
  return Math.round(Number(cents)) / 100;
}

export function formatPercent(percent) {
  const rounded = Math.round(Number(percent) * 100) / 100;
  if (!Number.isFinite(rounded)) return '';
  return String(rounded);
}

// Fee is rounded to the nearest cent. 3% of $33.33 is $1.00.
export function cardFeeCents(balanceCents, percent = DEFAULT_FEE_PERCENT) {
  if (!Number.isInteger(balanceCents) || balanceCents < 0) {
    throw new StripeFlowError('Balance due is not a whole number of cents.');
  }
  const pct = Number(percent);
  if (!Number.isFinite(pct) || pct < 0 || pct > MAX_FEE_PERCENT) {
    throw new StripeFlowError(`Card fee percent must be between 0 and ${MAX_FEE_PERCENT}.`);
  }
  const basisPoints = Math.round(pct * 100);
  return Math.round((balanceCents * basisPoints) / 10000);
}

export function feePercentFromEnv(raw, fallback = DEFAULT_FEE_PERCENT) {
  if (raw == null || String(raw).trim() === '') return fallback;
  const pct = Number(String(raw).trim());
  if (!Number.isFinite(pct) || pct < 0 || pct > MAX_FEE_PERCENT) {
    throw new StripeFlowError('STRIPE_CARD_FEE_PERCENT must be a number from 0 to 25.', 500);
  }
  return Math.round(pct * 100) / 100;
}

export function assertSecretKey(secretKey) {
  const key = String(secretKey || '').trim();
  if (!key) throw new StripeFlowError('Stripe is not configured.', 500);
  if (key.startsWith('pk_')) {
    throw new StripeFlowError('Stripe is configured with the publishable key. The secret key stays on the server.', 500);
  }
  if (!/^sk_(test|live)_[A-Za-z0-9]+$/.test(key)) {
    throw new StripeFlowError('STRIPE_SECRET_KEY is not a Stripe secret key.', 500);
  }
  return key;
}

export function checkoutUrlOk(url) {
  try {
    const parsed = new URL(String(url || ''));
    return parsed.protocol === 'https:' && parsed.hostname === CHECKOUT_HOST;
  } catch (_err) {
    return false;
  }
}

function cleanLine(value, max) {
  return String(value || '').replace(/[\r\n]+/g, ' ').trim().slice(0, max);
}

function validEmail(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(value || '').trim());
}

export function buildCheckoutBody({
  invoiceId,
  invoiceNumber,
  balanceCents,
  feeCents,
  feePercent,
  origin,
  email,
  address,
}) {
  if (!invoiceId) throw new StripeFlowError('Invoice is required.');
  if (!Number.isInteger(balanceCents) || balanceCents <= 0) {
    throw new StripeFlowError('This invoice has no balance due.');
  }
  if (!Number.isInteger(feeCents) || feeCents < 0) {
    throw new StripeFlowError('Card fee could not be calculated.');
  }
  const charge = balanceCents + feeCents;
  if (charge < MIN_CHARGE_CENTS) {
    throw new StripeFlowError('Stripe cannot charge less than $0.50.');
  }
  const root = String(origin || APP_ORIGIN).replace(/\/$/, '');
  const params = new URLSearchParams();
  params.set('mode', 'payment');
  params.set('success_url', `${root}/?card=paid`);
  params.set('cancel_url', `${root}/?card=cancelled`);
  params.set('client_reference_id', invoiceId);
  // Checkout shows the methods turned on for this Stripe account. Card is
  // one of them. Do not pin payment_method_types here.
  params.set('metadata[invoice_id]', invoiceId);
  params.set('metadata[invoice_number]', cleanLine(invoiceNumber, 40));
  params.set('metadata[balance_cents]', String(balanceCents));
  params.set('metadata[fee_cents]', String(feeCents));
  params.set('metadata[fee_percent]', formatPercent(feePercent));
  params.set('payment_intent_data[metadata][invoice_id]', invoiceId);
  params.set('payment_intent_data[metadata][balance_cents]', String(balanceCents));
  params.set('payment_intent_data[metadata][fee_cents]', String(feeCents));
  params.set('payment_intent_data[metadata][fee_percent]', formatPercent(feePercent));
  const who = String(email || '').trim();
  if (validEmail(who)) params.set('customer_email', who);
  const where = cleanLine(address, 180);
  addLine(params, 0, cleanLine(`Invoice ${invoiceNumber || ''}`.trim(), 120) || 'Invoice', where ? `Balance due · ${where}` : 'Balance due', balanceCents);
  if (feeCents > 0) {
    addLine(params, 1, `Card processing fee (${formatPercent(feePercent)}%)`, 'Added for card payments', feeCents);
  }
  return params;
}

function addLine(params, index, name, description, cents) {
  params.set(`line_items[${index}][quantity]`, '1');
  params.set(`line_items[${index}][price_data][currency]`, 'usd');
  params.set(`line_items[${index}][price_data][unit_amount]`, String(cents));
  params.set(`line_items[${index}][price_data][product_data][name]`, name);
  if (description) params.set(`line_items[${index}][price_data][product_data][description]`, description);
}

function stripeMessage(data, fallback, secretKey) {
  const err = data && data.error;
  const raw = err && (err.message || err) || fallback;
  let msg = String(raw || fallback || 'Stripe rejected the request.').slice(0, 240);
  if (secretKey && msg.includes(secretKey)) msg = msg.split(secretKey).join('[redacted]');
  return msg;
}

async function stripeRequest({ fetchImpl, secretKey, method, path, body, apiBase = 'https://api.stripe.com' }) {
  const res = await fetchImpl(`${apiBase}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${secretKey}`,
      ...(body ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}),
    },
    body: body ? body.toString() : undefined,
  });
  const text = await res.text();
  let data = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch (_err) {
    data = {};
  }
  return { ok: res.ok, status: res.status, data };
}

function sessionMatches(session, invoiceId, chargeCents, feeCents) {
  if (!session || session.status !== 'open') return false;
  if (Number(session.amount_total) !== chargeCents) return false;
  const meta = session.metadata || {};
  if (String(meta.invoice_id || '') !== String(invoiceId)) return false;
  if (String(meta.fee_cents || '') !== String(feeCents)) return false;
  return checkoutUrlOk(session.url);
}

export function checkoutResult(session, invoice, feePercent, balanceCents, feeCents, reused) {
  if (!checkoutUrlOk(session && session.url) || !session.id) {
    throw new StripeFlowError('Stripe did not return a checkout link.', 502);
  }
  return {
    url: session.url,
    session_id: session.id,
    fee: centsToDollars(feeCents),
    fee_percent: feePercent,
    balance: centsToDollars(balanceCents),
    charge: centsToDollars(balanceCents + feeCents),
    reused: !!reused,
    invoice_number: invoice.invoice_number || null,
  };
}

export async function ensureCheckoutSession({
  fetchImpl = fetch,
  secretKey,
  invoice,
  feePercent,
  origin = APP_ORIGIN,
  apiBase = 'https://api.stripe.com',
}) {
  const key = assertSecretKey(secretKey);
  if (!invoice || !invoice.id) throw new StripeFlowError('Invoice not found.', 404);
  const status = String(invoice.status || '');
  if (status === 'Paid') throw new StripeFlowError('This invoice is already paid.', 409);
  if (status !== 'Unpaid' && status !== 'Overdue') {
    throw new StripeFlowError('Only an unpaid invoice can take a card payment.');
  }
  const balanceCents = dollarsToCents(invoice.total);
  if (balanceCents == null || balanceCents <= 0) throw new StripeFlowError('This invoice has no balance due.');
  const feeCents = cardFeeCents(balanceCents, feePercent);
  const chargeCents = balanceCents + feeCents;
  const existingId = String(invoice.stripe_checkout_session_id || '').trim();
  if (/^cs_(test|live)_[A-Za-z0-9]+$/.test(existingId)) {
    const got = await stripeRequest({
      fetchImpl,
      secretKey: key,
      method: 'GET',
      path: `/v1/checkout/sessions/${encodeURIComponent(existingId)}`,
      apiBase,
    });
    if (got.status === 401 || got.status === 403) {
      throw new StripeFlowError(stripeMessage(got.data, 'Stripe rejected the secret key.', key), 502);
    }
    const session = got.ok ? got.data : null;
    if (session && session.status === 'complete') {
      throw new StripeFlowError(
        session.payment_status === 'paid'
          ? 'Stripe already accepted a card payment for this invoice. It will mark paid when the webhook arrives.'
          : 'A card checkout for this invoice is already finishing. Wait for it to mark paid.',
        409,
      );
    }
    if (sessionMatches(session, invoice.id, chargeCents, feeCents)) {
      return checkoutResult(session, invoice, feePercent, balanceCents, feeCents, true);
    }
    if (session && session.status === 'open') {
      const expired = await stripeRequest({
        fetchImpl,
        secretKey: key,
        method: 'POST',
        path: `/v1/checkout/sessions/${encodeURIComponent(existingId)}/expire`,
        apiBase,
      });
      if (!expired.ok && expired.status !== 400) {
        throw new StripeFlowError(stripeMessage(expired.data, 'Could not replace the old card link.', key), 502);
      }
    }
  }
  const body = buildCheckoutBody({
    invoiceId: invoice.id,
    invoiceNumber: invoice.invoice_number,
    balanceCents,
    feeCents,
    feePercent,
    origin,
    email: invoice.customer_email,
    address: invoice.address,
  });
  const created = await stripeRequest({
    fetchImpl,
    secretKey: key,
    method: 'POST',
    path: '/v1/checkout/sessions',
    body,
    apiBase,
  });
  if (!created.ok) {
    throw new StripeFlowError(stripeMessage(created.data, 'Stripe did not create a checkout link.', key), 502);
  }
  return checkoutResult(created.data, invoice, feePercent, balanceCents, feeCents, false);
}

function hexToBytes(hex) {
  if (!/^[0-9a-f]+$/i.test(hex) || hex.length % 2 !== 0) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function timingSafeEqual(a, b) {
  if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array)) return false;
  if (a.length !== b.length || a.length === 0) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a[i] ^ b[i];
  return out === 0;
}

async function hmacHex(secret, payload) {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payload)));
  return [...mac].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function parseStripeSignatureHeader(header) {
  const out = { timestamp: '', signatures: [] };
  for (const part of String(header || '').split(',')) {
    const eq = part.indexOf('=');
    if (eq < 1) continue;
    const name = part.slice(0, eq).trim();
    const value = part.slice(eq + 1).trim();
    if (name === 't') out.timestamp = value;
    else if (name === 'v1' && value) out.signatures.push(value);
  }
  return out;
}

// Stripe signs `${timestamp}.${rawBody}` with HMAC SHA256.
// The webhook secret is the raw string, including the whsec_ prefix.
export async function verifyStripeSignature({
  secret,
  header,
  body,
  nowMs = Date.now(),
  toleranceSec = 300,
}) {
  const key = String(secret || '');
  if (!key || body == null) return { ok: false, reason: 'missing' };
  if (String(body).length > 200000) return { ok: false, reason: 'size' };
  const parsed = parseStripeSignatureHeader(header);
  if (!parsed.timestamp || !parsed.signatures.length) return { ok: false, reason: 'missing' };
  if (!/^\d+$/.test(parsed.timestamp)) return { ok: false, reason: 'stale' };
  const ts = Number(parsed.timestamp);
  const skew = Math.abs(Math.floor(nowMs / 1000) - ts);
  if (skew > toleranceSec) return { ok: false, reason: 'stale' };
  const expectedHex = await hmacHex(key, `${parsed.timestamp}.${body}`);
  const expected = hexToBytes(expectedHex);
  for (const signature of parsed.signatures) {
    const got = hexToBytes(signature);
    if (got && timingSafeEqual(expected, got)) return { ok: true };
  }
  return { ok: false, reason: 'mismatch' };
}

function metaNumber(meta, name) {
  if (!meta || meta[name] == null || meta[name] === '') return null;
  const n = Number(meta[name]);
  if (!Number.isInteger(n) || n < 0) return null;
  return n;
}

function paymentIntentId(value) {
  if (!value) return '';
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'object' && value.id) return String(value.id).trim();
  return '';
}

// A paid Checkout Session, or a succeeded PaymentIntent that carries the
// invoice id we stored in metadata. Anything else is ignored.
export function paymentFromCheckoutEvent(event) {
  const type = String(event && event.type || '');
  const object = event && event.data && event.data.object;
  if (!object || typeof object !== 'object') return { ignore: true, reason: 'empty' };
  if (type === 'checkout.session.completed' || type === 'checkout.session.async_payment_succeeded') {
    if (object.mode && object.mode !== 'payment') return { ignore: true, reason: 'mode' };
    if (object.payment_status !== 'paid') return { ignore: true, reason: 'unpaid' };
    return paymentFromMeta(object.metadata, {
      paymentIntentId: paymentIntentId(object.payment_intent),
      sessionId: String(object.id || ''),
      amount: object.amount_total,
      invoiceId: object.client_reference_id,
      currency: object.currency,
    });
  }
  if (type === 'payment_intent.succeeded') {
    if (object.status && object.status !== 'succeeded') return { ignore: true, reason: 'unpaid' };
    return paymentFromMeta(object.metadata, {
      paymentIntentId: paymentIntentId(object.id),
      sessionId: '',
      amount: object.amount_received != null ? object.amount_received : object.amount,
      invoiceId: null,
      currency: object.currency,
    });
  }
  return { ignore: true, reason: 'event' };
}

function paymentFromMeta(metadata, source) {
  const meta = metadata && typeof metadata === 'object' ? metadata : {};
  const invoiceId = String(meta.invoice_id || source.invoiceId || '').trim();
  const pi = source.paymentIntentId;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(invoiceId)) {
    return { ignore: true, reason: 'invoice' };
  }
  if (!/^pi_[A-Za-z0-9]+$/.test(pi)) return { ignore: true, reason: 'payment_intent' };
  const balance = metaNumber(meta, 'balance_cents');
  const fee = metaNumber(meta, 'fee_cents');
  if (balance == null || fee == null) return { ignore: true, reason: 'fee' };
  if (source.currency && String(source.currency).toLowerCase() !== 'usd') {
    return { ignore: true, reason: 'currency' };
  }
  if (source.amount != null && Number(source.amount) !== balance + fee) {
    return { ignore: true, reason: 'amount' };
  }
  const percentRaw = meta.fee_percent;
  const percent = percentRaw == null || percentRaw === '' ? null : Number(percentRaw);
  if (percent != null && (!Number.isFinite(percent) || percent < 0 || percent > MAX_FEE_PERCENT)) {
    return { ignore: true, reason: 'fee' };
  }
  const sessionId = /^cs_(test|live)_[A-Za-z0-9]+$/.test(source.sessionId) ? source.sessionId : null;
  return {
    ignore: false,
    invoiceId,
    paymentIntentId: pi,
    balanceCents: balance,
    feeCents: fee,
    feePercent: percent,
    sessionId,
  };
}

// STRIPE_EXPECTED_LIVEMODE (or STRIPE_LIVEMODE) wins when set.
// Otherwise sk_live_ is live and sk_test_ is test. Anything else is unset.
export function expectedStripeLivemode({ secretKey = '', expectedRaw = '' } = {}) {
  const raw = String(expectedRaw || '').trim().toLowerCase();
  if (raw) {
    if (raw === '1' || raw === 'true' || raw === 'yes' || raw === 'live') return true;
    if (raw === '0' || raw === 'false' || raw === 'no' || raw === 'test') return false;
    return null;
  }
  const key = String(secretKey || '').trim();
  if (key.startsWith('sk_live_')) return true;
  if (key.startsWith('sk_test_')) return false;
  return null;
}

export async function markInvoiceFromStripeEvent({ event, admin, expectedLivemode }) {
  if (typeof expectedLivemode !== 'boolean') {
    return { status: 500, body: { error: 'Stripe mode is not configured.' } };
  }
  if (!event || typeof event.livemode !== 'boolean' || event.livemode !== expectedLivemode) {
    return { status: 400, body: { error: 'Stripe mode does not match this server.' } };
  }
  const parsed = paymentFromCheckoutEvent(event);
  if (parsed.ignore) return { status: 200, body: { ok: true, ignored: true, reason: parsed.reason || null } };
  const { data, error } = await admin.rpc('apply_stripe_invoice_payment', {
    p_invoice_id: parsed.invoiceId,
    p_payment_intent_id: parsed.paymentIntentId,
    p_fee: centsToDollars(parsed.feeCents),
    p_fee_percent: parsed.feePercent,
    p_session_id: parsed.sessionId,
    p_paid_on: null,
    p_balance_cents: parsed.balanceCents,
    p_livemode: event.livemode,
    p_expected_livemode: expectedLivemode,
  });
  if (error) {
    console.error('apply_stripe_invoice_payment', error.message || error);
    return { status: 500, body: { error: 'Could not record the payment.' } };
  }
  if (!data || data.ok === false) {
    if (data && data.error === 'not_found') {
      console.error('stripe invoice missing', parsed.invoiceId);
      return { status: 200, body: { ok: true, ignored: true, reason: 'not_found' } };
    }
    console.error('stripe payment was not recorded', data && data.error);
    return { status: 500, body: { error: 'Could not record the payment.' } };
  }
  return {
    status: 200,
    body: { ok: true, already: !!data.already, ignored: !!data.ignored, invoice_id: parsed.invoiceId },
  };
}
