// Sumak Ops — turn a job description into estimate line items.
//
// Deploy (from a machine logged into the Supabase CLI):
//   supabase functions deploy smooth-handler --project-ref nrnnpprcshkgroghhbro
//
// Leave the gateway JWT check on. Only a signed-in admin may call this.
// The app invokes the slug smooth-handler. The earlier editor file was
// named ai-estiamte.ts; that name is not the function slug.
//
// ANTHROPIC_API_KEY is a function secret. It is not returned to the browser.
// The description is capped at 4000 characters.

import { createClient } from 'npm:@supabase/supabase-js@2';

const MAX_DESCRIPTION = 4000;

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

async function isAdmin(req) {
  const header = req.headers.get('Authorization') || '';
  const token = header.toLowerCase().startsWith('bearer ') ? header.slice(7).trim() : '';
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!token || (service && timingSafeEqual(token, service))) return false;
  const url = Deno.env.get('SUPABASE_URL') || '';
  const anon = Deno.env.get('SUPABASE_ANON_KEY') || '';
  if (!url || !anon) return false;
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

function serviceLines(services) {
  const list = Array.isArray(services) ? services.slice(0, 80) : [];
  return list.map((s) => {
    const name = String(s?.name || '').replace(/\s+/g, ' ').trim().slice(0, 80);
    const price = Number(s?.default_price);
    const shown = Number.isFinite(price) ? price.toFixed(2) : '0.00';
    return name ? `- ${name}: $${shown}` : '';
  }).filter(Boolean).join('\n');
}

function cleanItems(parsed) {
  const rows = Array.isArray(parsed?.lineItems) ? parsed.lineItems.slice(0, 40) : [];
  return rows.map((item) => {
    const quantity = Number(item?.quantity);
    const unitPrice = Number(item?.unitPrice);
    return {
      description: String(item?.description || '').replace(/\s+/g, ' ').trim().slice(0, 300),
      quantity: Number.isFinite(quantity) && quantity > 0 && quantity < 10000 ? quantity : 1,
      unitPrice: Number.isFinite(unitPrice) && unitPrice >= 0 && unitPrice < 1000000 ? Math.round(unitPrice * 100) / 100 : 0,
    };
  }).filter((item) => item.description);
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
    if (!(await isAdmin(req))) return json(401, { error: 'Sign in as the office to build an estimate.' });
    const description = String(body.description ?? '');
    if (!description.trim()) return json(400, { error: 'description required' });
    if (description.length > MAX_DESCRIPTION) return json(400, { error: 'Description is too long.' });
    const apiKey = Deno.env.get('ANTHROPIC_API_KEY') || '';
    if (!apiKey) return json(500, { error: 'AI build unavailable' });
    const serviceList = serviceLines(body.services);
    const systemPrompt = `You are an estimating assistant for Sumak, an outdoor maintenance and landscaping company in the Treasure Valley, Idaho. Given a plain-English description of a job, produce line items for a client-facing estimate.

Known services and their typical pricing (prefer matching these exactly when the description fits one):
${serviceList || '(no saved services yet — estimate reasonable market pricing for Idaho landscaping/lawn care)'}

Respond with ONLY valid JSON, no markdown formatting, no code fences, no explanation. Use exactly this shape:
{"title":"short job title","lineItems":[{"description":"client-facing line item text","quantity":1,"unitPrice":0}],"notes":"optional scope/terms notes, or empty string"}

Keep descriptions concise and professional, suitable for a client to read. If the job implies multiple distinct tasks (e.g. mowing AND mulch), split them into separate line items rather than one bundled line.`;
    const res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 1000,
        system: systemPrompt,
        messages: [{ role: 'user', content: description.slice(0, MAX_DESCRIPTION) }],
      }),
    });
    if (!res.ok) {
      console.error('smooth-handler upstream', res.status);
      return json(502, { error: 'AI build unavailable' });
    }
    const data = await res.json();
    const text = data.content?.[0]?.text || '{}';
    const clean = String(text).replace(/```json|```/g, '').trim();
    let parsed;
    try {
      parsed = JSON.parse(clean);
    } catch (_err) {
      return json(500, { error: 'Could not parse AI response' });
    }
    return json(200, {
      title: String(parsed.title || '').replace(/\s+/g, ' ').trim().slice(0, 140),
      lineItems: cleanItems(parsed),
      notes: String(parsed.notes || '').slice(0, 2000),
    });
  } catch (_err) {
    console.error('smooth-handler failed');
    return json(500, { error: 'AI build unavailable' });
  }
});
