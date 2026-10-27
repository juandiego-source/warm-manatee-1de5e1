// Sumak Ops — Stripe webhook. Marks an invoice paid after a card payment.
//
// Deploy (Juand, from a machine logged into the Supabase CLI):
//   supabase functions deploy stripe-webhook --project-ref nrnnpprcshkgroghhbro --no-verify-jwt
//
// The gateway JWT check stays off. Stripe does not send a Supabase JWT.
// This function rejects any body whose Stripe-Signature does not match
// STRIPE_WEBHOOK_SECRET. After that check it compares event.livemode with
// the mode from STRIPE_EXPECTED_LIVEMODE or STRIPE_LIVEMODE, or from the
// STRIPE_SECRET_KEY prefix (sk_live_ / sk_test_). The key is not logged.
//
// In the Stripe dashboard (Developers → Webhooks), add an endpoint:
//   https://nrnnpprcshkgroghhbro.supabase.co/functions/v1/stripe-webhook
// Events:
//   checkout.session.completed
//   checkout.session.async_payment_succeeded
// payment_intent.succeeded is also accepted when it carries the invoice
// metadata this app stored. A repeated event is idempotent.
//
// Put the signing secret (whsec_...) in:
//   supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_... --project-ref nrnnpprcshkgroghhbro
//
// Run sql/2026-10-27-stripe-card-payments.sql before the first payment.
// On success the invoice is Paid, payment method is Card (Stripe),
// payment reference is the payment intent id, and card_fee is the fee.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { expectedStripeLivemode, markInvoiceFromStripeEvent, verifyStripeSignature } from '../_shared/stripe.js';

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function adminClient() {
  const url = Deno.env.get('SUPABASE_URL') || '';
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!url || !key) throw new Error('Supabase service role is not available in this function.');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'POST only.' });
  const secret = Deno.env.get('STRIPE_WEBHOOK_SECRET') || '';
  if (!secret) return json(500, { error: 'Webhook secret is not set.' });
  const raw = await req.text();
  const verified = await verifyStripeSignature({
    secret,
    header: req.headers.get('stripe-signature') || '',
    body: raw,
  });
  if (!verified.ok) return json(400, { error: 'Invalid signature.' });
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (_err) {
    return json(400, { error: 'JSON body required.' });
  }
  try {
    const expectedLivemode = expectedStripeLivemode({
      secretKey: Deno.env.get('STRIPE_SECRET_KEY') || '',
      expectedRaw: Deno.env.get('STRIPE_EXPECTED_LIVEMODE') || Deno.env.get('STRIPE_LIVEMODE') || '',
    });
    const result = await markInvoiceFromStripeEvent({
      event: payload,
      admin: adminClient(),
      expectedLivemode,
    });
    return json(result.status, result.body);
  } catch (err) {
    console.error('stripe-webhook', err?.message || err);
    return json(500, { error: 'Could not record the payment.' });
  }
});
