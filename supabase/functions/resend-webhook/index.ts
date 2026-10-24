// Sumak Ops — Resend delivery webhook.
//
// Deploy (Juand, from a machine logged into the Supabase CLI):
//   supabase functions deploy resend-webhook --project-ref nrnnpprcshkgroghhbro --no-verify-jwt
//
// The gateway JWT check stays off. Resend does not send a Supabase JWT.
// This function rejects any body whose Svix signature does not match
// RESEND_WEBHOOK_SECRET.
//
// In the Resend dashboard, add a webhook:
//   https://nrnnpprcshkgroghhbro.supabase.co/functions/v1/resend-webhook
// Events: email.sent, email.delivered, email.bounced, email.opened,
// email.complained, email.delivery_delayed.
//
// Put the signing secret (whsec_...) in:
//   supabase secrets set RESEND_WEBHOOK_SECRET=whsec_... --project-ref nrnnpprcshkgroghhbro
//
// A repeated event does not move a timestamp that is already set.
// The first bounce or complaint writes one admin notification.
// A push is attempted after that. A push failure still returns 200,
// because the status row is already saved.
// VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, and VAPID_SUBJECT are the same
// secrets job-comms uses. If they are missing, the in-app notification
// still stands.

import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';
import { verifySvixSignature } from './verify.js';

const APP_ORIGIN = 'https://warm-manatee-1de5e1.netlify.app';

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

function bounceReason(data) {
  const bounce = data && typeof data.bounce === 'object' ? data.bounce : {};
  const parts = [bounce.type, bounce.subType, bounce.message || bounce.diagnosticCode]
    .map((part) => String(part || '').trim())
    .filter(Boolean);
  return parts.join(' · ').slice(0, 500);
}

function vapidReady() {
  return !!(Deno.env.get('VAPID_PUBLIC_KEY') && Deno.env.get('VAPID_PRIVATE_KEY') && Deno.env.get('VAPID_SUBJECT'));
}

async function pushAdmins(admin, result) {
  if (!result?.newly_bounced && !result?.newly_complained) return;
  if (!vapidReady()) return;
  const { data, error } = await admin
    .from('push_subscriptions')
    .select('id, endpoint, p256dh, auth_key')
    .eq('recipient_role', 'admin');
  if (error || !data?.length) return;
  webpush.setVapidDetails(
    Deno.env.get('VAPID_SUBJECT') || '',
    Deno.env.get('VAPID_PUBLIC_KEY') || '',
    Deno.env.get('VAPID_PRIVATE_KEY') || '',
  );
  const linkType = result.invoice_id ? 'invoice' : result.estimate_id ? 'estimate' : result.job_id ? 'job' : 'dashboard';
  const linkId = result.invoice_id || result.estimate_id || result.job_id || null;
  const payload = JSON.stringify({
    title: 'Sumak Ops',
    body: String(result.message || 'An email needs attention.').slice(0, 180),
    url: `${APP_ORIGIN}/?notif=${encodeURIComponent(linkType)}${linkId ? `&id=${encodeURIComponent(linkId)}` : ''}`,
    linkType,
    linkId,
  });
  for (const row of data) {
    if (!row.endpoint || !row.p256dh || !row.auth_key) continue;
    try {
      await webpush.sendNotification(
        { endpoint: row.endpoint, keys: { p256dh: row.p256dh, auth: row.auth_key } },
        payload,
      );
    } catch (err) {
      const code = err?.statusCode;
      if (code === 404 || code === 410) {
        await admin.from('push_subscriptions').delete().eq('id', row.id);
      } else {
        console.error('bounce push', err?.message || err);
      }
    }
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'POST only.' });
  const secret = Deno.env.get('RESEND_WEBHOOK_SECRET') || '';
  if (!secret) return json(500, { error: 'Webhook secret is not set.' });
  const raw = await req.text();
  const verified = await verifySvixSignature({
    secret,
    id: req.headers.get('svix-id') || req.headers.get('webhook-id') || '',
    timestamp: req.headers.get('svix-timestamp') || req.headers.get('webhook-timestamp') || '',
    signature: req.headers.get('svix-signature') || req.headers.get('webhook-signature') || '',
    body: raw,
  });
  if (!verified.ok) return json(401, { error: 'Invalid signature.' });
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (_err) {
    return json(400, { error: 'JSON body required.' });
  }
  const type = String(payload?.type || '');
  const data = payload?.data && typeof payload.data === 'object' ? payload.data : {};
  const resendId = String(data.email_id || '').trim();
  if (!type) return json(200, { ok: true, ignored: true });
  if (!resendId) return json(400, { error: 'email_id required.' });
  const occurred = payload.created_at || data.created_at || null;
  const to = Array.isArray(data.to) ? data.to.map((item) => String(item || '').trim()).filter(Boolean) : [];
  try {
    const admin = adminClient();
    const { data: result, error } = await admin.rpc('apply_resend_event', {
      p_resend_id: resendId,
      p_type: type,
      p_occurred_at: occurred,
      p_to: to,
      p_subject: data.subject ? String(data.subject) : null,
      p_bounce_reason: type === 'email.bounced' ? bounceReason(data) : null,
    });
    if (error) throw new Error(error.message);
    try {
      await pushAdmins(admin, result);
    } catch (err) {
      console.error('bounce push', err?.message || err);
    }
    return json(200, { ok: true, status: result?.status || null, ignored: !!result?.ignored });
  } catch (err) {
    console.error('resend-webhook', err?.message || err);
    return json(500, { error: 'Could not save the delivery status.' });
  }
});
