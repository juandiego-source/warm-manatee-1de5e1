import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { cardFeeCents } from '../supabase/functions/_shared/stripe.js';

const require = createRequire(import.meta.url);
const { invoiceIdFrom, checkoutRedirectUrl } = require('../netlify/functions/pay.js');

test('the pay link reads the invoice id from the redirect or the path', () => {
  const id = '7b9a1422-6d63-4ffe-8c70-333c75d267f0';
  assert.equal(invoiceIdFrom({ queryStringParameters: { invoice_id: id } }), id);
  assert.equal(invoiceIdFrom({ path: `/pay/${id}` }), id);
  assert.equal(invoiceIdFrom({
    path: '/.netlify/functions/pay',
    rawUrl: `https://warm-manatee-1de5e1.netlify.app/pay/${id}`,
  }), id);
  assert.equal(invoiceIdFrom({ queryStringParameters: { invoice_id: 'INV-0102' } }), '');
  assert.equal(invoiceIdFrom({ path: '/pay/not-an-id' }), '');
});

test('only a Stripe hosted checkout URL can be the redirect', () => {
  assert.equal(
    checkoutRedirectUrl({ url: 'https://checkout.stripe.com/c/pay/cs_test_abc' }),
    'https://checkout.stripe.com/c/pay/cs_test_abc',
  );
  assert.equal(checkoutRedirectUrl({ url: 'https://evil.example/checkout.stripe.com' }), '');
  assert.equal(checkoutRedirectUrl({ url: 'http://checkout.stripe.com/c/pay/cs_test_abc' }), '');
  assert.equal(checkoutRedirectUrl({ url: 'https://warm-manatee-1de5e1.netlify.app/pay/x' }), '');
  assert.equal(checkoutRedirectUrl({}), '');
});

test('the emailed card fee matches the checkout fee', () => {
  const app = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
  const quote = app.slice(app.indexOf('function invoiceCardQuote'), app.indexOf('function invoiceCardLinkHTML'));
  assert.match(quote, /Math\.round\(\(balanceCents\*Math\.round\(pct\*100\)\)\/10000\)/);
  assert.match(quote, /pct=3/);
  for (const dollars of [65, 33.33, 100, 19.99, 0.5]) {
    const balanceCents = Math.round((dollars + Number.EPSILON) * 100);
    const quoted = Math.round((balanceCents * Math.round(3 * 100)) / 10000);
    assert.equal(quoted, cardFeeCents(balanceCents, 3));
  }
  const pay = readFileSync(new URL('../supabase/functions/pay-invoice/index.ts', import.meta.url), 'utf8');
  const toml = readFileSync(new URL('../netlify.toml', import.meta.url), 'utf8');
  assert.match(pay, /ensureCheckoutSession/);
  assert.match(pay, /feePercentFromEnv/);
  assert.equal(pay.includes('sk_live_'), false);
  assert.equal(pay.includes('sk_test_'), false);
  assert.match(toml, /\/pay\/:invoiceId/);
  assert.match(app, /data-outbound-send="invoice"/);
});
