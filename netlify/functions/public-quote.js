// Public estimate page. No login. The secret is the token in /q/<token>.
// Data and approval go through get_public_quote / respond_to_quote, which
// are the only anonymous access to an estimate.

const SB_URL = 'https://nrnnpprcshkgroghhbro.supabase.co';
const SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5ybm5wcHJjc2hrZ3JvZ2hoYnJvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc0MTAwOTYsImV4cCI6MjA5Mjk4NjA5Nn0.pRjE7f8h8xwibZG2X7prT-xOKhcKrBxB6VGs8zMYlNs';

function decodeToken(raw) {
  try {
    return decodeURIComponent(String(raw || '')).trim();
  } catch (e) {
    return String(raw || '').trim();
  }
}

function tokenFrom(event) {
  const paths = [String((event && event.path) || '')];
  const rawUrl = String((event && event.rawUrl) || '');
  if (rawUrl) {
    try { paths.push(new URL(rawUrl).pathname); } catch (e) {}
  }
  for (const path of paths) {
    const match = path.match(/\/(?:q|quote)\/([^/?#]+)/);
    if (match) return decodeToken(match[1]);
  }
  const q = (event && event.queryStringParameters) || {};
  if (q.quote) return decodeToken(q.quote);
  if (q.token) return decodeToken(q.token);
  return '';
}

function parseForm(event) {
  const raw = event && event.isBase64Encoded
    ? Buffer.from(event.body || '', 'base64').toString('utf8')
    : String((event && event.body) || '');
  const params = new URLSearchParams(raw);
  return {
    response: params.get('response') || '',
    note: params.get('note') || '',
    lines: params.getAll('line')
  };
}

async function rpc(name, args) {
  const res = await fetch(SB_URL + '/rest/v1/rpc/' + name, {
    method: 'POST',
    headers: {
      apikey: SB_KEY,
      Authorization: 'Bearer ' + SB_KEY,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(args || {})
  });
  const text = await res.text();
  let data = null;
  if (text) {
    try { data = JSON.parse(text); } catch (e) { data = { error: 'bad_response', detail: text.slice(0, 180) }; }
  }
  return { status: res.status, data };
}

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function money(n) {
  const x = Math.round((Number(n) || 0) * 100) / 100;
  return x.toLocaleString('en-US', { style: 'currency', currency: 'USD' });
}

function cents(n) {
  return Math.round((Number(n) || 0) * 100);
}

function prettyDate(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(s || ''));
  if (!m) return '';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return months[Number(m[2]) - 1] + ' ' + Number(m[3]) + ', ' + m[1];
}

function boiseToday() {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Boise', year: 'numeric', month: '2-digit', day: '2-digit'
  }).format(new Date());
}

function itemsOf(quote) {
  let items = quote && quote.items;
  if (typeof items === 'string') {
    try { items = JSON.parse(items); } catch (e) { items = []; }
  }
  return Array.isArray(items) ? items : [];
}

function isOptional(item) {
  return !!(item && (item.is_optional === true || item.is_optional === 'true' || item.is_optional === 1));
}

function lineTotal(item) {
  return Math.round((Number(item && item.total) || 0) * 100) / 100;
}

function quoteTotals(quote, selectedIds) {
  const chosen = new Set((selectedIds || []).map(String));
  let sub = 0;
  itemsOf(quote).forEach((item) => {
    const on = !isOptional(item) || chosen.has(String(item.id));
    if (on) sub += lineTotal(item);
  });
  sub = Math.round(sub * 100) / 100;
  const rate = Number(quote && quote.tax_rate) || 0;
  const tax = Math.round(sub * rate) / 100;
  return { sub, tax, total: Math.round((sub + tax) * 100) / 100, rate };
}

function htmlPage(title, body) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${esc(title)}</title>
<link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:wght@600;700&family=Plus+Jakarta+Sans:wght@400;600;700&display=swap" rel="stylesheet">
<style>
  body{margin:0;background:#F3ECE4;color:#3a2f28;font-family:'Plus Jakarta Sans',sans-serif;}
  .wrap{max-width:560px;margin:0 auto;padding:28px 18px 64px;}
  h1{font-family:'Cormorant Garamond',serif;font-size:30px;font-weight:600;color:#7B1A1A;text-align:center;margin:0;}
  .tag{text-align:center;font-size:12px;color:#8a7a6e;margin:2px 0 24px;}
  .card{background:#fff;border-radius:16px;padding:22px;box-shadow:0 4px 20px rgba(0,0,0,.06);}
  .row{display:flex;justify-content:space-between;gap:12px;align-items:flex-start;}
  .muted{font-size:12px;color:#8a7a6e;}
  .line{display:flex;justify-content:space-between;gap:12px;padding:10px 0;border-bottom:1px solid #f2ede8;}
  .opt{font-size:10px;background:#f0e6da;color:#8a6d3b;padding:1px 6px;border-radius:8px;font-weight:700;letter-spacing:.04em;}
  label.optline{display:flex;gap:8px;align-items:flex-start;cursor:pointer;}
  input[type=checkbox]{margin-top:3px;width:16px;height:16px;accent-color:#7B1A1A;}
  .totals{margin-top:16px;padding-top:14px;border-top:2px solid #3a2f28;}
  .trow{display:flex;justify-content:space-between;padding:4px 0;font-size:14px;color:#5a463c;}
  .grand{font-size:16px;font-weight:700;color:#3a2f28;}
  .grand b{font-family:'Cormorant Garamond',serif;font-size:26px;color:#7B1A1A;font-weight:700;}
  button, .btn{font-family:inherit;cursor:pointer;border-radius:12px;font-weight:700;}
  .accept{width:100%;padding:16px;background:#7B1A1A;color:#fff;border:none;font-size:16px;margin:22px 0 10px;}
  .pair{display:flex;gap:10px;}
  .ghost{flex:1;padding:13px;background:#fff;color:#3a2f28;border:1.5px solid #d8cec4;font-size:14px;}
  .danger{flex:1;padding:13px;background:#fff;color:#8B1A1A;border:1.5px solid #e5c4c4;font-size:14px;}
  textarea{width:100%;box-sizing:border-box;padding:12px;border:1.5px solid #d8cec4;border-radius:10px;font-family:inherit;font-size:14px;min-height:70px;}
  .send{width:100%;margin-top:8px;padding:13px;background:#8a6d3b;color:#fff;border:none;font-size:14px;}
  .note{font-size:12.5px;color:#6a5c50;margin-top:14px;padding:12px;background:#faf6f0;border-radius:10px;white-space:pre-wrap;}
  .foot{text-align:center;margin-top:24px;font-size:11.5px;color:#a89a8c;}
  .banner{text-align:center;margin-top:22px;padding:18px;background:#fff;border-radius:14px;}
</style>
</head>
<body>
<div class="wrap">
  <h1>Sumak Lawncare</h1>
  <div class="tag">Outdoor Maintenance · Treasure Valley, Idaho</div>
  ${body}
  <div class="foot">Sumak Lawncare · 208-695-7239 · office@sumaklawncare.com</div>
</div>
</body>
</html>`;
}

function respond(status, title, body) {
  return {
    statusCode: status,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Robots-Tag': 'noindex'
    },
    body: htmlPage(title, body)
  };
}

function missingPage() {
  return respond(404, 'Quote not found', `
    <div class="card" style="text-align:center">
      <div style="font-size:20px;font-weight:700">Quote not found</div>
      <div class="muted" style="margin-top:8px;font-size:14px;line-height:1.5">This link may be incomplete. Call or text Sumak Lawncare at 208-695-7239 and we will send a fresh one.</div>
    </div>`);
}

function problemPage() {
  return respond(500, 'Quote unavailable', `
    <div class="card" style="text-align:center">
      <div style="font-size:18px;font-weight:700">We could not open this quote</div>
      <div class="muted" style="margin-top:8px;font-size:14px">Please call Sumak Lawncare at 208-695-7239.</div>
    </div>`);
}

function confirmation(quote, response, total) {
  const cfg = {
    Accepted: { color: '#2a6010', title: 'Quote accepted — thank you', msg: 'We have your acceptance and will be in touch to schedule. The total below is what you approved.' },
    Declined: { color: '#8B1A1A', title: 'Quote declined', msg: 'Thanks for letting us know. If anything changes, call us.' },
    'Changes Requested': { color: '#8a6d3b', title: 'Changes requested', msg: 'We have your note and will get back to you.' }
  }[response] || { color: '#3a2f28', title: 'Thank you', msg: 'Your response has been received.' };
  const totalLine = response === 'Accepted' && total != null
    ? `<div style="margin-top:14px;font-size:18px;font-weight:700">Approved total ${esc(money(total))}</div>`
    : '';
  return respond(200, cfg.title, `
    <div class="card" style="text-align:center">
      <div style="font-size:21px;font-weight:700;color:${cfg.color}">${esc(cfg.title)}</div>
      <div style="font-size:14px;color:#6a5c50;margin-top:12px;line-height:1.6">${esc(cfg.msg)}</div>
      ${totalLine}
      <div class="muted" style="margin-top:18px;padding-top:14px;border-top:1px solid #f2ede8">Estimate ${esc(quote.estimate_number || '')} · ${esc(quote.client_name || '')}</div>
    </div>`);
}

function selectedIds(quote) {
  let raw = quote && quote.client_selected_items;
  if (typeof raw === 'string') {
    try { raw = JSON.parse(raw); } catch (e) { raw = []; }
  }
  return Array.isArray(raw) ? raw.map(String) : [];
}

function lineBlock(item, mode, chosen) {
  const amount = money(lineTotal(item));
  const title = esc(item.title || 'Item');
  const desc = item.description ? `<div class="muted" style="margin-top:2px">${esc(item.description)}</div>` : '';
  const qty = Number(item.quantity);
  const qtyBit = Number.isFinite(qty) && qty !== 1 ? `<div class="muted">Qty ${esc(String(item.quantity))}</div>` : '';
  const optional = isOptional(item);
  const on = !optional || chosen.has(String(item.id));
  if (mode === 'pick' && optional) {
    return `<div class="line"><label class="optline"><input type="checkbox" name="line" value="${esc(item.id)}" data-cents="${cents(lineTotal(item))}"><span><span style="font-weight:600">${title}</span> <span class="opt">OPTIONAL</span>${qtyBit}${desc}</span></label><div style="font-weight:600;white-space:nowrap">${esc(amount)}</div></div>`;
  }
  const flag = optional
    ? (on ? ' <span class="opt">OPTIONAL · INCLUDED</span>' : ' <span class="opt">OPTIONAL · NOT INCLUDED</span>')
    : '';
  return `<div class="line" style="${optional && !on ? 'opacity:.55' : ''}"><div><div style="font-weight:600">${title}${flag}</div>${qtyBit}${desc}</div><div style="font-weight:600;white-space:nowrap">${esc(amount)}</div></div>`;
}

function quotePage(quote) {
  const items = itemsOf(quote);
  const already = quote.client_response;
  const chosen = new Set(already === 'Accepted' ? selectedIds(quote) : []);
  const totals = quoteTotals(quote, already === 'Accepted' ? [...chosen] : []);
  const rate = Number(quote.tax_rate) || 0;
  const expired = quote.valid_until && String(quote.valid_until).slice(0, 10) < boiseToday();
  const valid = quote.valid_until
    ? `<div class="muted" style="margin-top:8px">Valid until ${esc(prettyDate(quote.valid_until))}${expired ? '. That date has passed. You can still respond and we will confirm the price.' : ''}</div>`
    : '';
  const notes = quote.notes ? `<div class="note">${esc(quote.notes)}</div>` : '';
  const taxRow = rate > 0 ? `<div class="trow"><span>Tax (${esc(String(rate))}%)</span><span id="pq-tax">${esc(money(totals.tax))}</span></div>` : '';
  const header = `
    <div class="row" style="margin-bottom:8px">
      <div><div class="muted">Estimate</div><div style="font-size:18px;font-weight:700">${esc(quote.estimate_number || '')}</div></div>
      <div style="text-align:right"><div class="muted">Prepared for</div><div style="font-weight:600">${esc(quote.client_name || '')}</div></div>
    </div>
    ${quote.address ? `<div class="muted" style="margin-bottom:8px">${esc(quote.address)}</div>` : ''}`;
  if (already) {
    const lines = items.map((item) => lineBlock(item, 'read', chosen)).join('');
    const label = already === 'Accepted' ? 'You accepted this quote' : already === 'Declined' ? 'This quote was declined' : 'Changes were requested';
    return respond(200, 'Estimate ' + (quote.estimate_number || ''), `
      <div class="card">
        ${header}
        <div style="border-top:1px solid #eee;margin-top:8px">${lines}</div>
        <div class="totals">
          <div class="trow"><span>Subtotal</span><span>${esc(money(totals.sub))}</span></div>
          ${taxRow}
          <div class="trow grand"><span>Total</span><b>${esc(money(totals.total))}</b></div>
        </div>
        ${notes}${valid}
      </div>
      <div class="banner"><div style="font-weight:700">${esc(label)}</div><div class="muted" style="margin-top:6px">Questions? Call 208-695-7239.</div></div>`);
  }
  const lines = items.map((item) => lineBlock(item, 'pick', new Set())).join('');
  const hasOptional = items.some(isOptional);
  const requiredCents = cents(items.reduce((sum, item) => sum + (isOptional(item) ? 0 : lineTotal(item)), 0));
  return respond(200, 'Estimate ' + (quote.estimate_number || ''), `
    <div class="card">
      ${header}
      <form method="post" id="accept-form">
        <div style="border-top:1px solid #eee;margin-top:8px">${lines}</div>
        <div class="totals">
          <div class="trow"><span>Subtotal</span><span id="pq-sub">${esc(money(totals.sub))}</span></div>
          ${taxRow}
          <div class="trow grand"><span>Total</span><b id="pq-total">${esc(money(totals.total))}</b></div>
        </div>
        ${notes}${valid}
        <button class="accept" name="response" value="Accepted">Accept this quote</button>
        ${hasOptional ? '<div class="muted">Optional lines stay off until you check them, so the total starts at the amount in the email. Required work is already included.</div>' : ''}
      </form>
      <form method="post" style="margin-top:10px">
        <div class="pair">
          <button class="ghost" type="button" id="show-changes">Request changes</button>
          <button class="danger" name="response" value="Declined">Decline</button>
        </div>
        <div id="changes" style="display:none;margin-top:12px">
          <textarea name="note" placeholder="What would you like changed?"></textarea>
          <button class="send" name="response" value="Changes Requested">Send request</button>
        </div>
      </form>
    </div>
    <script>
      (function(){
        var required=${requiredCents};
        var rate=${JSON.stringify(rate)};
        function money(c){
          var sign=c<0?'-':'';
          var n=Math.abs(c);
          return sign+'$'+Math.floor(n/100).toLocaleString('en-US')+'.'+String(n%100).padStart(2,'0');
        }
        function draw(){
          var sub=required;
          document.querySelectorAll('#accept-form input[type=checkbox]:checked').forEach(function(el){
            sub+=Number(el.getAttribute('data-cents'))||0;
          });
          var tax=Math.round(sub*rate/100);
          var subEl=document.getElementById('pq-sub');
          var taxEl=document.getElementById('pq-tax');
          var totalEl=document.getElementById('pq-total');
          if(subEl)subEl.textContent=money(sub);
          if(taxEl)taxEl.textContent=money(tax);
          if(totalEl)totalEl.textContent=money(sub+tax);
        }
        document.querySelectorAll('#accept-form input[type=checkbox]').forEach(function(el){
          el.addEventListener('change', draw);
        });
        var btn=document.getElementById('show-changes');
        if(btn)btn.addEventListener('click', function(){
          var n=document.getElementById('changes');
          if(n)n.style.display=n.style.display==='block'?'none':'block';
        });
      })();
    </script>`);
}

async function loadQuote(token) {
  const loaded = await rpc('get_public_quote', { p_token: token });
  if (loaded.status >= 500 || loaded.data == null) return { error: 'down' };
  if (loaded.status === 404 || (loaded.data && loaded.data.code)) return { error: 'missing' };
  const data = Array.isArray(loaded.data) ? loaded.data[0] : loaded.data;
  if (!data || data.error) return { error: 'missing' };
  try { await rpc('mark_quote_viewed', { p_token: token }); } catch (e) {}
  return { quote: data };
}

exports.handler = async function handler(event) {
  try {
    const token = tokenFrom(event);
    if (!token) return missingPage();
    const method = String(event.httpMethod || 'GET').toUpperCase();
    if (method === 'POST') {
      const form = parseForm(event);
      const loaded = await loadQuote(token);
      if (loaded.error === 'down') return problemPage();
      if (loaded.error) return missingPage();
      const quote = loaded.quote;
      if (quote.client_response && quote.client_response !== form.response) {
        const kept = quote.client_response === 'Accepted' ? quoteTotals(quote, selectedIds(quote)).total : null;
        return confirmation(quote, quote.client_response, kept);
      }
      const allowed = ['Accepted', 'Declined', 'Changes Requested'];
      if (!allowed.includes(form.response)) return quotePage(quote);
      const saved = await rpc('respond_to_quote', {
        p_token: token,
        p_response: form.response,
        p_note: form.note || null,
        p_selected: JSON.stringify(form.lines || [])
      });
      const body = saved.data || {};
      if (body.error === 'already_responded') {
        const keptResponse = body.response || quote.client_response;
        const keptTotal = keptResponse === 'Accepted' ? quoteTotals(quote, selectedIds(quote)).total : null;
        return confirmation(quote, keptResponse, keptTotal);
      }
      if (body.error || saved.status >= 400) return problemPage();
      const totals = quoteTotals(quote, form.response === 'Accepted' ? form.lines : []);
      const total = body.total != null ? body.total : (form.response === 'Accepted' ? totals.total : null);
      return confirmation(quote, form.response, total);
    }
    const loaded = await loadQuote(token);
    if (loaded.error === 'down') return problemPage();
    if (loaded.error) return missingPage();
    return quotePage(loaded.quote);
  } catch (e) {
    return problemPage();
  }
};

exports._test = { tokenFrom, parseForm, quoteTotals, esc, itemsOf, isOptional };
