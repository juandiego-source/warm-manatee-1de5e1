// Sumak Ops — send one office email through Resend and record it.
//
// Deploy (Juand, from a machine logged into the Supabase CLI):
//   supabase functions deploy send-email --project-ref nrnnpprcshkgroghhbro
//
// Leave the gateway JWT check on. The signed-in office user calls this
// from the app. job-comms calls it with the service role key.
// A subcontractor login is rejected.
//
// RESEND_API_KEY is the same secret the function already uses.
// From address: Sumak Lawncare <office@sumaklawncare.com>
//
// Body: { to, cc, subject, html, pdfBase64, pdfFilename, kind,
//         invoice_id, estimate_id, job_id }
// On success: { id } where id is the Resend message id.
// The row in email_events stores that id and the recipients.
// An invoice or estimate id also writes sent_to and sent_at.
// On a Resend error this returns a non-2xx JSON body and writes nothing,
// so the app does not mark the document sent.

import { createClient } from 'npm:@supabase/supabase-js@2';

const FROM = 'Sumak Lawncare <office@sumaklawncare.com>';
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

function asList(value) {
  const raw = Array.isArray(value) ? value : String(value || '').split(/[,;\n]+/);
  const out = [];
  const seen = new Set();
  for (const item of raw) {
    const email = String(item || '').trim();
    const key = email.toLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(email);
  }
  return out;
}

function cleanId(value) {
  const id = String(value || '').trim();
  return UUID.test(id) ? id : null;
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

async function linkedRow(admin, table, id) {
  if (!id) return true;
  const { data, error } = await admin.from(table).select('id').eq('id', id).maybeSingle();
  if (error) throw new Error(error.message);
  return !!data;
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
  let sentId = '';
  try {
    if (!(await allowedCaller(req))) return json(401, { error: 'Sign in as the office to send email.' });
    const to = asList(body.to);
    const cc = asList(body.cc).filter((email) => !to.some((item) => item.toLowerCase() === email.toLowerCase()));
    const subject = String(body.subject || '').trim();
    const html = String(body.html || '');
    if (!to.length) return json(400, { error: 'Add a To address.' });
    if (!subject) return json(400, { error: 'Subject is required.' });
    if (!html.trim()) return json(400, { error: 'Message is required.' });
    const invoiceId = cleanId(body.invoice_id);
    const estimateId = cleanId(body.estimate_id);
    const jobId = cleanId(body.job_id);
    let kind = String(body.kind || '').trim().toLowerCase();
    if (!kind) {
      if (invoiceId) kind = 'invoice';
      else if (estimateId) kind = 'estimate';
      else if (jobId) kind = 'job';
      else kind = 'other';
    }
    if (!/^[a-z][a-z0-9_]{0,31}$/.test(kind)) return json(400, { error: 'Unknown email kind.' });
    const admin = adminClient();
    if (invoiceId && !(await linkedRow(admin, 'invoices', invoiceId))) {
      return json(400, { error: 'That invoice was not found.' });
    }
    if (estimateId && !(await linkedRow(admin, 'estimates', estimateId))) {
      return json(400, { error: 'That estimate was not found.' });
    }
    if (jobId && !(await linkedRow(admin, 'jobs', jobId))) {
      return json(400, { error: 'That job was not found.' });
    }
    const resendKey = Deno.env.get('RESEND_API_KEY') || '';
    if (!resendKey) return json(500, { error: 'Email is not configured.' });
    const payload = {
      from: FROM,
      to,
      subject,
      html,
    };
    if (cc.length) payload.cc = cc;
    const pdf = String(body.pdfBase64 || '').trim();
    if (pdf) {
      payload.attachments = [{
        filename: String(body.pdfFilename || 'document.pdf').slice(0, 180),
        content: pdf,
      }];
    }
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${resendKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });
    const text = await res.text();
    let data = {};
    try {
      data = text ? JSON.parse(text) : {};
    } catch (_err) {
      data = {};
    }
    if (!res.ok || data.error || !data.id) {
      const detail = data.message || data.error || text || 'Resend rejected the email.';
      return json(res.status >= 400 && res.status < 600 ? res.status : 502, {
        error: 'Email was not sent.',
        detail: String(detail).slice(0, 240),
      });
    }
    sentId = String(data.id);
    const { error } = await admin.rpc('record_outgoing_email', {
      p_resend_id: sentId,
      p_kind: kind,
      p_invoice_id: invoiceId,
      p_estimate_id: estimateId,
      p_job_id: jobId,
      p_to: to,
      p_cc: cc,
      p_subject: subject,
      p_sent_at: new Date().toISOString(),
    });
    if (error) {
      console.error('email event was not saved', error.message);
      return json(200, { id: sentId, warning: 'Email was sent. Delivery tracking was not saved.' });
    }
    return json(200, { id: sentId });
  } catch (err) {
    console.error('send-email', err?.message || err);
    if (sentId) return json(200, { id: sentId, warning: 'Email was sent. Delivery tracking was not saved.' });
    return json(500, { error: 'Email was not sent.', detail: err?.message || 'The mailer failed.' });
  }
});
