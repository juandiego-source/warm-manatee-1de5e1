// Sumak Ops — start a card checkout for one invoice.
//
// The link the client keeps is https://warm-manatee-1de5e1.netlify.app/pay/<invoice_id>.
// Netlify's pay function calls this one, then redirects to the Stripe URL
// returned here. Stripe Checkout itself expires after 24 hours. This link
// does not: each visit creates a session or reuses one that is still open.
// The card fee stays 3% (STRIPE_CARD_FEE_PERCENT) and is its own line.
//
// Deploy (Juand, from a machine logged into the Supabase CLI):
//   supabase functions deploy pay-invoice --project-ref nrnnpprcshkgroghhbro
//
// Leave the gateway JWT check on. The Netlify function sends the anon key,
// which is a JWT, so the gateway lets the call through. This function does
// not treat that caller as the office. It only starts checkout for an
// unpaid or overdue invoice. The secret key stays in the function env.
//
// Body: { invoice_id }
// On success: { url, session_id, fee, fee_percent, balance, charge, reused }
// The url is always https://checkout.stripe.com/...

import { createClient } from 'npm:@supabase/supabase-js@2';
import {
  APP_ORIGIN,
  StripeFlowError,
  ensureCheckoutSession,
  feePercentFromEnv,
} from '../_shared/stripe.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

function adminClient() {
  const url = Deno.env.get('SUPABASE_URL') || '';
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!url || !key) throw new Error('Supabase service role is not available in this function.');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

function customerEmail(row) {
  const cust = row && row.customers;
  const one = Array.isArray(cust) ? cust[0] : cust;
  if (!one) return '';
  return String(one.billing_email || one.email || '').trim();
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'POST only.' });
  let body = {};
  try {
    body = await req.json();
  } catch (_err) {
    return json(400, { error: 'JSON body required.' });
  }
  try {
    const invoiceId = String(body.invoice_id || '').trim();
    if (!UUID.test(invoiceId)) return json(400, { error: 'Invoice is required.' });
    let feePercent;
    try {
      feePercent = feePercentFromEnv(Deno.env.get('STRIPE_CARD_FEE_PERCENT'));
    } catch (err) {
      return json(err.status || 500, { error: err.message });
    }
    const admin = adminClient();
    const { data: row, error } = await admin
      .from('invoices')
      .select('id, invoice_number, status, total, address, stripe_checkout_session_id, customers(email, billing_email)')
      .eq('id', invoiceId)
      .maybeSingle();
    if (error) {
      const missing = /stripe_checkout_session_id|card_fee/i.test(error.message || '');
      return json(500, {
        error: missing
          ? 'Card payments are not available on this invoice yet.'
          : 'Could not load the invoice.',
      });
    }
    if (!row) return json(404, { error: 'That invoice was not found.' });
    const result = await ensureCheckoutSession({
      secretKey: Deno.env.get('STRIPE_SECRET_KEY') || '',
      invoice: { ...row, customer_email: customerEmail(row) },
      feePercent,
      origin: APP_ORIGIN,
    });
    const saved = await admin
      .from('invoices')
      .update({
        stripe_checkout_session_id: result.session_id,
        stripe_checkout_url: result.url,
        card_fee_percent: result.fee_percent,
      })
      .eq('id', invoiceId)
      .in('status', ['Unpaid', 'Overdue'])
      .select('id')
      .maybeSingle();
    if (saved.error) {
      return json(500, { error: 'The link was created, but it was not saved on the invoice.' });
    }
    if (!saved.data) return json(409, { error: 'This invoice is already paid.' });
    return json(200, result);
  } catch (err) {
    if (err instanceof StripeFlowError) return json(err.status || 400, { error: err.message });
    console.error('pay-invoice', err?.message || err);
    return json(500, { error: 'Could not open card checkout.' });
  }
});
