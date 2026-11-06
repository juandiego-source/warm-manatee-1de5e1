import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { verifySvixSignature } from '../supabase/functions/resend-webhook/verify.js';

const secretBytes = crypto.getRandomValues(new Uint8Array(24));
const secret = `whsec_${Buffer.from(secretBytes).toString('base64')}`;

async function sign(id, timestamp, body) {
  const key = await crypto.subtle.importKey(
    'raw',
    secretBytes,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = new Uint8Array(await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(`${id}.${timestamp}.${body}`),
  ));
  return Buffer.from(mac).toString('base64');
}

test('a matching Svix signature is accepted', async () => {
  const body = JSON.stringify({ type: 'email.delivered', data: { email_id: 're_1' } });
  const timestamp = String(Math.floor(Date.now() / 1000));
  const signature = `v1,${await sign('msg_1', timestamp, body)}`;
  const result = await verifySvixSignature({ secret, id: 'msg_1', timestamp, signature, body });
  assert.equal(result.ok, true);
});

test('a second v1 signature in the header can match', async () => {
  const body = '{"type":"email.bounced"}';
  const timestamp = String(Math.floor(Date.now() / 1000));
  const good = await sign('msg_2', timestamp, body);
  const result = await verifySvixSignature({
    secret,
    id: 'msg_2',
    timestamp,
    signature: `v1,aaaa v1,${good}`,
    body,
  });
  assert.equal(result.ok, true);
});

test('a bad signature, a tampered body, and a stale timestamp are rejected', async () => {
  const body = '{"type":"email.opened"}';
  const timestamp = String(Math.floor(Date.now() / 1000));
  const signature = `v1,${await sign('msg_3', timestamp, body)}`;
  assert.equal((await verifySvixSignature({
    secret,
    id: 'msg_3',
    timestamp,
    signature: 'v1,bm90LXRoZS1zaWduYXR1cmU',
    body,
  })).ok, false);
  assert.equal((await verifySvixSignature({
    secret,
    id: 'msg_3',
    timestamp,
    signature,
    body: `${body} `,
  })).reason, 'mismatch');
  assert.equal((await verifySvixSignature({
    secret,
    id: 'msg_3',
    timestamp: String(Math.floor(Date.now() / 1000) - 600),
    signature,
    body,
  })).reason, 'stale');
});

test('the app keeps the recipient when a send is stamped, and a Resend error does not mark it sent', () => {
  const app = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
  assert.equal(app.includes('delete slim.sent_to'), false);
  assert.equal(app.includes('Direct send failed'), false);
  assert.equal(app.includes('Opened is approximate'), true);
  assert.equal(app.includes('openEmailProblem'), true);
  const invoice = app.slice(app.indexOf('async function emailInvoice'), app.indexOf('async function markInvoiceSent'));
  assert.equal(invoice.includes('markInvoiceSent'), true);
  assert.equal(invoice.includes("kind:'invoice'"), true);
  const catchAt = invoice.indexOf('}catch(e){');
  assert.equal(invoice.slice(catchAt).includes('markInvoiceSent'), false);
  const estimate = app.slice(app.indexOf('async function emailEstimate'), app.indexOf('async function stampSent'));
  const estimateCatch = estimate.indexOf('}catch(e){');
  assert.equal(estimate.slice(estimateCatch).includes('stampSent'), false);
  assert.equal(estimate.includes("kind:'estimate'"), true);
});

test('a send stays quiet on failure, and Sent is not painted on before the provider confirms', () => {
  const app = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
  const invoice = app.slice(app.indexOf('async function emailInvoice'), app.indexOf('async function markInvoiceSent'));
  assert.equal(invoice.includes('outboundSendKeys'), true);
  assert.equal(invoice.includes("kind:'invoice'"), true);
  assert.match(invoice, /idempotency_key:sendAttemptId\('invoice',id\)/);
  assert.equal(invoice.indexOf('markInvoiceSent') < invoice.indexOf('}catch(e){'), true);
  const estimate = app.slice(app.indexOf('async function emailEstimate'), app.indexOf('async function stampSent'));
  assert.equal(estimate.indexOf('stampSent') < estimate.indexOf('}catch(e){'), true);
  assert.match(estimate, /idempotency_key:sendAttemptId\('estimate',id\)/);
  assert.equal(app.includes("if(sendNow&&(status==='Draft'))status='Sent'"), false);
  const timeline = app.slice(app.indexOf('function estimateTimelineHTML'), app.indexOf('async function openEstDetail'));
  assert.equal(timeline.includes("e.status!=='Draft'"), false);
  assert.equal(timeline.includes("e.status==='Sent'"), false);
  const vis = app.slice(app.indexOf("document.addEventListener('visibilitychange'"), app.lastIndexOf('</script>'));
  assert.match(vis, /if\(sendBusy\(\)\)return;/);
  const auth = app.slice(app.indexOf('db.auth.onAuthStateChange'), app.indexOf('async function initNotifications'));
  assert.match(auth, /TOKEN_REFRESHED/);
  assert.match(auth, /sendBusy\(\)/);
  const route = app.slice(app.indexOf('async function applyRoute'), app.indexOf('function historyBack'));
  assert.match(route, /if\(sendBusy\(\)\)/);
  const price = app.slice(app.indexOf('function updateLineItemField'), app.indexOf('function commitLineItemPrice'));
  assert.match(price, /if\(priceEl&&field!=='price'&&reprices\)priceEl\.value=/);
  assert.equal(/oninput="updateLineItemField\('\$\{arr\}',\$\{i\},'price'/.test(app) && app.includes('onblur="commitLineItemPrice'), true);
  assert.match(app, /onblur="commitLineItemPrice/);
  const pay = app.slice(app.indexOf('function stableCardPayUrl'), app.indexOf('async function emailInvoice'));
  assert.match(pay, /\/pay\//);
  assert.equal(pay.includes('stripe_checkout_url'), false);
  assert.equal(pay.includes('checkout.stripe.com'), false);
  assert.equal(invoice.includes('createCardPaymentLink'), false);
  const sql = readFileSync(new URL('../sql/2026-10-24-email-tracking.sql', import.meta.url), 'utf8');
  assert.match(sql, /WHEN status IS NULL OR status = 'Draft' THEN 'Sent'/);
});

test('the tracking SQL does not alter storage and keeps events admin-only', () => {
  const sql = readFileSync(new URL('../sql/2026-10-24-email-tracking.sql', import.meta.url), 'utf8');
  assert.equal(/ALTER\s+TABLE\s+storage\.objects/i.test(sql), false);
  assert.equal(sql.includes('email_events_admin_select'), true);
  assert.equal(sql.includes('GRANT SELECT ON TABLE public.email_events TO authenticated'), true);
  assert.equal(sql.includes('GRANT INSERT'), false);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.record_outgoing_email/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.apply_resend_event/);
});
