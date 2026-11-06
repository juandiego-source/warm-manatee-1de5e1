// Public card link: /pay/<invoice_id>
// Stripe Checkout URLs expire after 24 hours. This address does not.
// Each visit asks the pay-invoice function for a live session, then
// redirects the client there. The 3% fee is added on that session.
// No email is sent from this function.

const SB_URL = 'https://nrnnpprcshkgroghhbro.supabase.co';
const SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5ybm5wcHJjc2hrZ3JvZ2hoYnJvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc0MTAwOTYsImV4cCI6MjA5Mjk4NjA5Nn0.pRjE7f8h8xwibZG2X7prT-xOKhcKrBxB6VGs8zMYlNs';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function decodePart(raw) {
  try {
    return decodeURIComponent(String(raw || '')).trim();
  } catch (e) {
    return String(raw || '').trim();
  }
}

function invoiceIdFrom(event) {
  const query = (event && event.queryStringParameters) || {};
  const fromQuery = decodePart(query.invoice_id || query.id || '');
  if (UUID.test(fromQuery)) return fromQuery;
  const paths = [String((event && event.path) || '')];
  const rawUrl = String((event && event.rawUrl) || '');
  if (rawUrl) {
    try { paths.push(new URL(rawUrl).pathname); } catch (e) {}
  }
  const headers = (event && event.headers) || {};
  const original = headers['x-nf-original-pathname'] || headers['x-forwarded-uri'] || '';
  if (original) paths.push(String(original).split('?')[0]);
  for (const path of paths) {
    const match = String(path).match(/\/pay\/([0-9a-f-]{36})/i);
    if (match && UUID.test(match[1])) return match[1];
  }
  return '';
}

function checkoutRedirectUrl(body) {
  try {
    const url = new URL(String(body && body.url || ''));
    if (url.protocol !== 'https:' || url.hostname !== 'checkout.stripe.com') return '';
    return url.toString();
  } catch (e) {
    return '';
  }
}

function esc(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function page(title, message) {
  const html = `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(title)}</title></head><body style="margin:0;background:#F3ECE4;font-family:Georgia,serif;color:#3a2f28"><div style="max-width:520px;margin:0 auto;padding:64px 24px;text-align:center"><div style="font-size:28px;color:#7B1A1A">Sumak Lawncare</div><h1 style="font-size:22px;font-weight:600;margin:28px 0 8px">${esc(title)}</h1><p style="font-family:sans-serif;font-size:15px;line-height:1.5;color:#6a5c50">${esc(message)}</p><p style="font-family:sans-serif;font-size:13px;color:#8a7a6e;margin-top:24px">208-695-7239 · office@sumaklawncare.com</p></div></body></html>`;
  return {
    statusCode: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
    body: html,
  };
}

async function startCheckout(invoiceId) {
  const res = await fetch(SB_URL + '/functions/v1/pay-invoice', {
    method: 'POST',
    headers: {
      apikey: SB_KEY,
      Authorization: 'Bearer ' + SB_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ invoice_id: invoiceId }),
  });
  const text = await res.text();
  let data = null;
  if (text) {
    try { data = JSON.parse(text); } catch (e) { data = null; }
  }
  return { status: res.status, data };
}

exports.invoiceIdFrom = invoiceIdFrom;
exports.checkoutRedirectUrl = checkoutRedirectUrl;

exports.handler = async function (event) {
  const invoiceId = invoiceIdFrom(event);
  if (!invoiceId) return page('Payment link not found', 'This link is incomplete. Please contact Sumak Lawncare and we will send a new one.');
  try {
    const { status, data } = await startCheckout(invoiceId);
    const url = checkoutRedirectUrl(data);
    if (status === 200 && url) {
      return {
        statusCode: 302,
        headers: { Location: url, 'Cache-Control': 'no-store' },
        body: '',
      };
    }
    const message = data && typeof data.error === 'string' ? data.error : '';
    if (status === 404) return page('Invoice not found', 'This payment link does not match an invoice. Please contact Sumak Lawncare.');
    if (status === 409) return page('This invoice is not open for card payment', message || 'It may already be paid. Please contact Sumak Lawncare if you still need to pay.');
    return page('Card checkout is unavailable', message || 'Please try this link again in a minute, or pay by Venmo. Call 208-695-7239 if it still does not open.');
  } catch (e) {
    return page('Card checkout is unavailable', 'Please try this link again in a minute, or pay by Venmo. Call 208-695-7239 if it still does not open.');
  }
};
