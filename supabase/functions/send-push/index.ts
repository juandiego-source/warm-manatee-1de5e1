// Sumak Ops — send a browser push for one notification row.
//
// Deploy (from a machine logged into the Supabase CLI):
//   supabase functions deploy send-push --project-ref nrnnpprcshkgroghhbro
//
// Leave the gateway JWT check on. The database trigger sends
// Authorization: Bearer <service role key> read from Vault
// (vault.decrypted_secrets name service_role_key). That passes the gateway.
// The trigger also sends x-cron-secret when Vault has cron_secret.
// Set the function secret CRON_SECRET to that same value.
//
// Deploy with --no-verify-jwt only if the trigger cannot send the service
// role key and must rely on x-cron-secret alone.
//
// A signed-in admin may call it. A subcontractor login cannot.
// VAPID_PUBLIC_KEY must match the key in index.html.
// VAPID_SUBJECT defaults to mailto:sumak.idaho@gmail.com when unset.

import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
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

function bearer(req) {
  const header = req.headers.get('Authorization') || '';
  return header.toLowerCase().startsWith('bearer ') ? header.slice(7).trim() : '';
}

async function allowedCaller(req) {
  const cron = Deno.env.get('CRON_SECRET') || '';
  const presented = req.headers.get('x-cron-secret') || '';
  if (cron && presented && timingSafeEqual(presented, cron)) return true;
  const token = bearer(req);
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
  const { data, error } = await adminClient().from('profiles').select('id, role').eq('id', user.id).maybeSingle();
  if (error) return false;
  return data?.role === 'admin';
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'POST only.' });
  try {
    if (!(await allowedCaller(req))) return json(401, { error: 'Not allowed.' });
  } catch (_err) {
    console.error('send-push auth failed');
    return json(401, { error: 'Not allowed.' });
  }
  let payload = {};
  try {
    payload = await req.json();
  } catch (_err) {
    return json(400, { error: 'JSON body required.' });
  }
  const record = payload && payload.record;
  if (!record || (record.recipient_role !== 'admin' && record.recipient_role !== 'sub')) {
    return json(400, { error: 'no record in payload' });
  }
  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY') || '';
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY') || '';
  if (!publicKey || !privateKey) return json(500, { error: 'Push is not configured.' });
  try {
    webpush.setVapidDetails(
      Deno.env.get('VAPID_SUBJECT') || 'mailto:sumak.idaho@gmail.com',
      publicKey,
      privateKey,
    );
    const supabase = adminClient();
    let query = supabase
      .from('push_subscriptions')
      .select('id, endpoint, p256dh, auth_key')
      .eq('recipient_role', record.recipient_role);
    if (record.recipient_role === 'sub') {
      if (!record.recipient_sub_id) return json(200, { sent: 0, failed: 0 });
      query = query.eq('recipient_sub_id', record.recipient_sub_id);
    }
    const { data: subs, error } = await query;
    if (error) {
      console.error('send-push subscriptions', error.message || error);
      return json(500, { error: 'Could not load subscriptions.' });
    }
    const notifPayload = JSON.stringify({
      title: 'Sumak Ops',
      body: String(record.message || '').slice(0, 500),
      url: '/',
      linkType: record.link_type || null,
      linkId: record.link_id || null,
    });
    const results = await Promise.allSettled(
      (subs || []).map(async (s) => {
        if (!s.endpoint || !s.p256dh || !s.auth_key) return;
        try {
          await webpush.sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } },
            notifPayload,
          );
        } catch (err) {
          if (err?.statusCode === 404 || err?.statusCode === 410) {
            await supabase.from('push_subscriptions').delete().eq('endpoint', s.endpoint);
            return;
          }
          throw err;
        }
      }),
    );
    const sent = results.filter((r) => r.status === 'fulfilled').length;
    const failed = results.filter((r) => r.status === 'rejected').length;
    return json(200, { sent, failed });
  } catch (_err) {
    console.error('send-push failed');
    return json(500, { error: 'Could not send the push.' });
  }
});
