// Sumak Ops — create a Stripe Checkout link for one invoice.
//
// Deploy (Juand, from a machine logged into the Supabase CLI):
//   supabase functions deploy stripe-checkout --project-ref nrnnpprcshkgroghhbro
//
// Leave the gateway JWT check on. The signed-in office user calls this
// from the app. A subcontractor login is rejected.
//
// Secrets (Edge Function secrets only — never in the browser or in git):
//   STRIPE_SECRET_KEY=sk_test_... or sk_live_...
//   STRIPE_CARD_FEE_PERCENT=3
//     Optional. Defaults to 3. The fee is its own Checkout line item and
//     is not added to the invoice total.
//
//   supabase secrets set STRIPE_SECRET_KEY=sk_test_... STRIPE_CARD_FEE_PERCENT=3 --project-ref nrnnpprcshkgroghhbro
//
// Body: { invoice_id }
// On success: { url, session_id, fee, fee_percent, balance, charge, reused }
// The url is always https://checkout.stripe.com/... The card number is
// entered on that page. This function stores the url and session id on
// the invoice. Run sql/2026-10-27-stripe-card-payments.sql first.

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

function timingSafeEqual(a, b) {
  const aa = new TextEncoder().encode(String(a));
  const bb = new TextEncoder().encode(String(b));
  if (aa.length !== bb.length || aa.length === 0) return false;
  let out = 0;
  for (let i = 0; i < aa.length; i++) out |= aa[i] ^ bb[i];
  return out === 0;
}

function adminClient() {
  const url = Deno.env.get('SUPABASE_URL') || '';
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!url || !key) throw new Error('Supabase service role is not available in this function.');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function allowedCaller(req) {
  const header = req.headers.get('Authorization') || '';
  const token = header.toLowerCase().startsWith('bearer ') ? header.slice(7).trim() : '';
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (token && service && timingSafeEqual(token, service)) return true;
  const url = Deno.env.get('SUPABASE_URL') || '';
  const anon = Deno.env.get('SUPABASE_ANON_KEY') || '';
  if (!token || !url || !anon || !service) return false;
  const res = await fetch(`${url}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: anon },
  });
  if (!res.ok) return false;
  const user = await res.json();
  if (!user?.id) return false;
  const admin = adminClient();
  const { data, error } = await admin.from('profiles').select('id, role').eq('id', user.id).maybeSingle();
  if (error) return false;
  return data?.role === 'admin';
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
    if (!(await allowedCaller(req))) return json(401, { error: 'Sign in as the office to create a card link.' });
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
          ? 'Card payments are not in the database yet. Run sql/2026-10-27-stripe-card-payments.sql in the Supabase SQL Editor, then try again.'
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
      const missing = /stripe_checkout|card_fee/i.test(saved.error.message || '');
      return json(500, {
        error: missing
          ? 'Card payments are not in the database yet. Run sql/2026-10-27-stripe-card-payments.sql in the Supabase SQL Editor, then try again.'
          : 'The link was created, but it was not saved on the invoice.',
      });
    }
    if (!saved.data) return json(409, { error: 'This invoice is already paid.' });
    return json(200, result);
  } catch (err) {
    if (err instanceof StripeFlowError) return json(err.status || 400, { error: err.message });
    console.error('stripe-checkout', err?.message || err);
    return json(500, { error: 'Could not create the card link.' });
  }
});
