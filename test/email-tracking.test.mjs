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

test('the tracking SQL does not alter storage and keeps events admin-only', () => {
  const sql = readFileSync(new URL('../sql/2026-10-24-email-tracking.sql', import.meta.url), 'utf8');
  assert.equal(/ALTER\s+TABLE\s+storage\.objects/i.test(sql), false);
  assert.equal(sql.includes('email_events_admin_select'), true);
  assert.equal(sql.includes('GRANT SELECT ON TABLE public.email_events TO authenticated'), true);
  assert.equal(sql.includes('GRANT INSERT'), false);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.record_outgoing_email/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.apply_resend_event/);
});
