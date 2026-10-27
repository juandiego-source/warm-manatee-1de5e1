import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  DEFAULT_FEE_PERCENT,
  StripeFlowError,
  buildCheckoutBody,
  cardFeeCents,
  dollarsToCents,
  ensureCheckoutSession,
  feePercentFromEnv,
  markInvoiceFromStripeEvent,
  paymentFromCheckoutEvent,
  verifyStripeSignature,
} from '../supabase/functions/_shared/stripe.js';

const SECRET_KEY = `sk_test_${'a'.repeat(24)}`;
const WEBHOOK_SECRET = 'whsec_test_secret';
const INVOICE_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

function stripeSign(secret, timestamp, body) {
  return createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex');
}

test('the card fee defaults to 3% and rounds to the nearest cent', () => {
  assert.equal(DEFAULT_FEE_PERCENT, 3);
  assert.equal(feePercentFromEnv(''), 3);
  assert.equal(feePercentFromEnv(undefined), 3);
  assert.equal(feePercentFromEnv('3.5'), 3.5);
  assert.throws(() => feePercentFromEnv('30'), StripeFlowError);
  assert.equal(dollarsToCents('100.00'), 10000);
  assert.equal(dollarsToCents(19.99), 1999);
  assert.equal(cardFeeCents(10000, 3), 300);
  assert.equal(cardFeeCents(3333, 3), 100);
  assert.equal(cardFeeCents(1, 3), 0);
});

test('checkout charges the balance and the fee as separate line items', () => {
  const body = buildCheckoutBody({
    invoiceId: INVOICE_ID,
    invoiceNumber: 'INV-1042',
    balanceCents: 10000,
    feeCents: 300,
    feePercent: 3,
    origin: 'https://warm-manatee-1de5e1.netlify.app',
    email: 'billing@customer.test',
    address: '100 Main St',
  });
  const params = new URLSearchParams(body);
  assert.equal(params.get('mode'), 'payment');
  assert.equal(params.get('payment_method_types[0]'), 'card');
  assert.equal(params.get('line_items[0][price_data][unit_amount]'), '10000');
  assert.equal(params.get('line_items[0][price_data][product_data][name]'), 'Invoice INV-1042');
  assert.equal(params.get('line_items[1][price_data][unit_amount]'), '300');
  assert.equal(params.get('line_items[1][price_data][product_data][name]'), 'Card processing fee (3%)');
  assert.equal(params.get('metadata[invoice_id]'), INVOICE_ID);
  assert.equal(params.get('metadata[fee_cents]'), '300');
  assert.equal(params.get('success_url'), 'https://warm-manatee-1de5e1.netlify.app/?card=paid');
  assert.equal(body.toString().includes(SECRET_KEY), false);
});

test('a Stripe signature matches, and a bad or stale one does not', async () => {
  const body = JSON.stringify({ id: 'evt_1', type: 'checkout.session.completed' });
  const timestamp = String(Math.floor(Date.now() / 1000));
  const signature = stripeSign(WEBHOOK_SECRET, timestamp, body);
  const header = `t=${timestamp},v1=${'ab'.repeat(32)},v1=${signature}`;
  assert.equal((await verifyStripeSignature({ secret: WEBHOOK_SECRET, header, body })).ok, true);
  assert.equal((await verifyStripeSignature({
    secret: WEBHOOK_SECRET,
    header: `t=${timestamp},v1=${signature}`,
    body: `${body} `,
  })).reason, 'mismatch');
  assert.equal((await verifyStripeSignature({
    secret: WEBHOOK_SECRET,
    header: `t=${Number(timestamp) - 600},v1=${signature}`,
    body,
  })).reason, 'stale');
  assert.equal((await verifyStripeSignature({ secret: '', header, body })).reason, 'missing');
});

test('only a paid checkout or a succeeded payment intent can mark an invoice', () => {
  const paid = paymentFromCheckoutEvent({
    type: 'checkout.session.completed',
    data: {
      object: {
        id: 'cs_test_abc',
        mode: 'payment',
        payment_status: 'paid',
        currency: 'usd',
        amount_total: 10300,
        payment_intent: 'pi_card123',
        client_reference_id: INVOICE_ID,
        metadata: { invoice_id: INVOICE_ID, balance_cents: '10000', fee_cents: '300', fee_percent: '3' },
      },
    },
  });
  assert.equal(paid.ignore, false);
  assert.equal(paid.paymentIntentId, 'pi_card123');
  assert.equal(paid.feeCents, 300);
  assert.equal(paymentFromCheckoutEvent({
    type: 'checkout.session.completed',
    data: { object: { payment_status: 'unpaid', metadata: { invoice_id: INVOICE_ID } } },
  }).reason, 'unpaid');
  assert.equal(paymentFromCheckoutEvent({
    type: 'checkout.session.completed',
    data: {
      object: {
        payment_status: 'paid',
        currency: 'usd',
        amount_total: 50,
        payment_intent: 'pi_short',
        metadata: { invoice_id: INVOICE_ID, balance_cents: '10000', fee_cents: '300' },
      },
    },
  }).reason, 'amount');
  assert.equal(paymentFromCheckoutEvent({ type: 'charge.refunded', data: { object: {} } }).reason, 'event');
});

function listen(handler) {
  const server = createServer(handler);
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

test('test mode creates a checkout link, then a signed webhook marks the invoice paid once', async () => {
  const sessions = new Map();
  const posts = [];
  let seq = 0;
  const server = await listen(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const raw = Buffer.concat(chunks).toString();
    const auth = req.headers.authorization || '';
    if (!auth.startsWith('Bearer sk_test_') && !auth.startsWith('Bearer sk_live_')) {
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { message: 'bad key' } }));
      return;
    }
    assert.equal(raw.includes(SECRET_KEY), false);
    const url = new URL(req.url, 'https://api.stripe.com');
    if (req.method === 'POST' && url.pathname === '/v1/checkout/sessions') {
      seq += 1;
      const params = new URLSearchParams(raw);
      const id = `cs_test_session${seq}`;
      const balance = Number(params.get('metadata[balance_cents]'));
      const fee = Number(params.get('metadata[fee_cents]'));
      const session = {
        id,
        url: `https://checkout.stripe.com/c/pay/${id}`,
        status: 'open',
        payment_status: 'unpaid',
        amount_total: balance + fee,
        metadata: {
          invoice_id: params.get('metadata[invoice_id]'),
          fee_cents: params.get('metadata[fee_cents]'),
          balance_cents: params.get('metadata[balance_cents]'),
          fee_percent: params.get('metadata[fee_percent]'),
        },
      };
      sessions.set(id, session);
      posts.push(raw);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(session));
      return;
    }
    const expire = url.pathname.match(/^\/v1\/checkout\/sessions\/([^/]+)\/expire$/);
    if (req.method === 'POST' && expire) {
      const session = sessions.get(decodeURIComponent(expire[1]));
      session.status = 'expired';
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(session));
      return;
    }
    const got = url.pathname.match(/^\/v1\/checkout\/sessions\/([^/]+)$/);
    if (req.method === 'GET' && got) {
      const session = sessions.get(decodeURIComponent(got[1]));
      if (!session) {
        res.writeHead(404, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'missing' } }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(session));
      return;
    }
    res.writeHead(404);
    res.end('{}');
  });
  const { port } = server.address();
  const apiBase = `http://127.0.0.1:${port}`;
  try {
    const invoice = {
      id: INVOICE_ID,
      invoice_number: 'INV-E2E',
      status: 'Unpaid',
      total: '100.00',
      customer_email: 'billing@customer.test',
      address: '100 Main St',
    };
    const created = await ensureCheckoutSession({
      secretKey: SECRET_KEY,
      invoice,
      feePercent: 3,
      apiBase,
    });
    assert.equal(created.reused, false);
    assert.equal(created.balance, 100);
    assert.equal(created.fee, 3);
    assert.equal(created.charge, 103);
    assert.equal(created.url.startsWith('https://checkout.stripe.com/'), true);
    assert.equal(JSON.stringify(created).includes(SECRET_KEY), false);
    assert.equal(posts.length, 1);
    const sent = new URLSearchParams(posts[0]);
    assert.equal(sent.get('line_items[0][price_data][unit_amount]'), '10000');
    assert.equal(sent.get('line_items[1][price_data][unit_amount]'), '300');
    assert.equal(sent.get('line_items[1][price_data][product_data][name]'), 'Card processing fee (3%)');
    assert.equal(sent.get('payment_method_types[0]'), 'card');

    const again = await ensureCheckoutSession({
      secretKey: SECRET_KEY,
      invoice: { ...invoice, stripe_checkout_session_id: created.session_id },
      feePercent: 3,
      apiBase,
    });
    assert.equal(again.reused, true);
    assert.equal(again.url, created.url);
    assert.equal(posts.length, 1);

    const replaced = await ensureCheckoutSession({
      secretKey: SECRET_KEY,
      invoice: { ...invoice, total: '200.00', stripe_checkout_session_id: created.session_id },
      feePercent: 3,
      apiBase,
    });
    assert.equal(replaced.reused, false);
    assert.equal(replaced.fee, 6);
    assert.equal(replaced.charge, 206);
    assert.notEqual(replaced.session_id, created.session_id);

    const event = {
      id: 'evt_e2e',
      type: 'checkout.session.completed',
      data: {
        object: {
          id: created.session_id,
          mode: 'payment',
          payment_status: 'paid',
          currency: 'usd',
          amount_total: 10300,
          payment_intent: 'pi_e2eCardPay1',
          client_reference_id: INVOICE_ID,
          metadata: {
            invoice_id: INVOICE_ID,
            balance_cents: '10000',
            fee_cents: '300',
            fee_percent: '3',
          },
        },
      },
    };
    const raw = JSON.stringify(event);
    const timestamp = String(Math.floor(Date.now() / 1000));
    const header = `t=${timestamp},v1=${stripeSign(WEBHOOK_SECRET, timestamp, raw)}`;
    assert.equal((await verifyStripeSignature({ secret: WEBHOOK_SECRET, header, body: raw })).ok, true);
    const bad = await verifyStripeSignature({ secret: WEBHOOK_SECRET, header: `t=${timestamp},v1=${'0'.repeat(64)}`, body: raw });
    assert.equal(bad.ok, false);

    const calls = [];
    const first = await markInvoiceFromStripeEvent({
      event,
      admin: {
        rpc(name, args) {
          calls.push({ name, args });
          return { data: { ok: true, already: false, invoice_id: INVOICE_ID }, error: null };
        },
      },
    });
    assert.equal(first.status, 200);
    assert.equal(first.body.already, false);
    assert.equal(calls[0].name, 'apply_stripe_invoice_payment');
    assert.equal(calls[0].args.p_invoice_id, INVOICE_ID);
    assert.equal(calls[0].args.p_payment_intent_id, 'pi_e2eCardPay1');
    assert.equal(calls[0].args.p_fee, 3);
    assert.equal(calls[0].args.p_fee_percent, 3);
    assert.equal(calls[0].args.p_session_id, created.session_id);

    const second = await markInvoiceFromStripeEvent({
      event,
      admin: {
        rpc() {
          return { data: { ok: true, already: true }, error: null };
        },
      },
    });
    assert.equal(second.body.already, true);

    applyEndToEnd(calls[0].args);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

function psql(sql) {
  execFileSync('sudo', ['-u', 'postgres', 'psql', '-d', 'sumak_stripe_card', '-v', 'ON_ERROR_STOP=1', '-c', sql], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function applyEndToEnd(args) {
  psql(`DELETE FROM public.notifications WHERE link_id = '${args.p_invoice_id}';
        DELETE FROM public.invoices WHERE id = '${args.p_invoice_id}';
        INSERT INTO public.invoices (id, invoice_number, status, subtotal, total)
        VALUES ('${args.p_invoice_id}', 'INV-E2E', 'Unpaid', 100, 100);`);
  const fee = Number(args.p_fee);
  const percent = args.p_fee_percent == null ? 'NULL' : Number(args.p_fee_percent);
  const session = args.p_session_id ? `'${args.p_session_id}'` : 'NULL';
  const applied = execFileSync('sudo', [
    '-u', 'postgres', 'psql', '-d', 'sumak_stripe_card', '-v', 'ON_ERROR_STOP=1', '-t', '-A', '-c',
    `SELECT public.apply_stripe_invoice_payment('${args.p_invoice_id}', '${args.p_payment_intent_id}', ${fee}, ${percent}, ${session}, NULL)::text;`,
  ], { encoding: 'utf8' });
  const result = JSON.parse(applied.trim());
  assert.equal(result.ok, true);
  assert.equal(result.already, false);
  const row = execFileSync('sudo', [
    '-u', 'postgres', 'psql', '-d', 'sumak_stripe_card', '-v', 'ON_ERROR_STOP=1', '-t', '-A', '-c',
    `SELECT (status = 'Paid'
      AND payment_method = 'Card (Stripe)'
      AND payment_reference = '${args.p_payment_intent_id}'
      AND card_fee = 3
      AND paid_on IS NOT NULL
      AND total = 100)::text
     FROM public.invoices WHERE id = '${args.p_invoice_id}';`,
  ], { encoding: 'utf8' }).trim();
  assert.equal(row, 'true');
  psql(`SELECT public.apply_stripe_invoice_payment('${args.p_invoice_id}', '${args.p_payment_intent_id}', ${fee}, ${percent}, ${session}, NULL);`);
  const notes = execFileSync('sudo', [
    '-u', 'postgres', 'psql', '-d', 'sumak_stripe_card', '-v', 'ON_ERROR_STOP=1', '-t', '-A', '-c',
    `SELECT count(*) FROM public.notifications WHERE link_id = '${args.p_invoice_id}';`,
  ], { encoding: 'utf8' }).trim();
  assert.equal(notes, '1');
}

test('the office UI keeps the card link away from subcontractors, and secrets stay on the server', () => {
  const app = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
  const checkout = readFileSync(new URL('../supabase/functions/stripe-checkout/index.ts', import.meta.url), 'utf8');
  const webhook = readFileSync(new URL('../supabase/functions/stripe-webhook/index.ts', import.meta.url), 'utf8');
  const sql = readFileSync(new URL('../sql/2026-10-27-stripe-card-payments.sql', import.meta.url), 'utf8');
  assert.equal(app.includes('STRIPE_SECRET_KEY'), false);
  assert.equal(app.includes('sk_test_'), false);
  assert.equal(app.includes('sk_live_'), false);
  assert.equal(app.includes('Card payment link'), true);
  assert.equal(app.includes('Pay by card'), true);
  assert.equal(app.includes('You can pay by Venmo'), true);
  const sub = app.slice(app.indexOf('function renderSubPortal'), app.indexOf('function filterSubJobs'));
  assert.equal(sub.includes('Card payment link'), false);
  assert.equal(sub.includes('stripe_checkout'), false);
  assert.equal(sub.includes('client_price'), false);
  const subJob = app.slice(app.indexOf('function asSubJob'), app.indexOf('async function fetchCostRequests'));
  assert.equal(subJob.includes('delete copy.stripe_checkout_url'), true);
  assert.equal(subJob.includes('delete copy.client_price'), true);
  const invoices = app.slice(app.indexOf('function renderInvoices'), app.indexOf('function invAttnBanner'));
  assert.equal(invoices.indexOf("role==='sub'") < invoices.indexOf('renderBatchInvoice()'), true);
  const detail = app.slice(app.indexOf('async function openInvDetail'), app.indexOf('function invoiceCSS'));
  assert.equal(detail.indexOf("role==='sub'") < detail.indexOf('Card payment link'), true);
  assert.match(checkout, /role === 'admin'/);
  assert.equal(checkout.includes('STRIPE_WEBHOOK_SECRET'), false);
  assert.equal(webhook.includes('STRIPE_SECRET_KEY'), false);
  const serve = webhook.slice(webhook.indexOf('Deno.serve'));
  assert.equal(serve.indexOf('verifyStripeSignature') < serve.indexOf('markInvoiceFromStripeEvent'), true);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.apply_stripe_invoice_payment/);
  assert.match(sql, /'Card \(Stripe\)'/);
  assert.equal(sql.includes('sk_live_'), false);
});

test('publishable keys are rejected before any Stripe call', async () => {
  await assert.rejects(
    () => ensureCheckoutSession({
      secretKey: 'pk_test_notasecret',
      invoice: { id: INVOICE_ID, status: 'Unpaid', total: 10 },
      feePercent: 3,
      fetchImpl() {
        throw new Error('the browser key was sent');
      },
    }),
    (err) => err instanceof StripeFlowError && /publishable/.test(err.message),
  );
});
