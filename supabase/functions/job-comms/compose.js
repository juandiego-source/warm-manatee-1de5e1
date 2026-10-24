// Email and push text for sub <-> office messages.
// Only the fields listed in publicJob() are read. Extra columns on the
// object (client price, margin, cost) are ignored and never printed.

export const APP_ORIGIN = 'https://warm-manatee-1de5e1.netlify.app';
export const OFFICE_EMAIL = 'office@sumaklawncare.com';

const REASONS = new Set(['assigned', 'reassigned', 'rescheduled', 'cancelled', 'manual']);

export function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function formatMoney(value) {
  const n = Number(value);
  const amount = Number.isFinite(n) ? n : 0;
  return amount.toLocaleString('en-US', { style: 'currency', currency: 'USD' });
}

export function formatYMD(ymd) {
  if (!ymd) return 'Not scheduled';
  const [y, m, d] = String(ymd).slice(0, 10).split('-').map(Number);
  if (!y || !m || !d) return 'Not scheduled';
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-US', {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    timeZone: 'UTC',
  });
}

export function mapsHref(address) {
  if (!address) return '';
  return 'https://www.google.com/maps/dir/?api=1&destination=' + encodeURIComponent(address);
}

export function jobHref(jobNumber) {
  return APP_ORIGIN + '/jobs/' + encodeURIComponent(jobNumber || '');
}

export function publicJob(job) {
  const src = job || {};
  return {
    id: src.id || null,
    job_number: src.job_number || '',
    title: src.title || 'Job',
    description: src.description || '',
    address: src.address || '',
    scheduled_date: src.scheduled_date ? String(src.scheduled_date).slice(0, 10) : '',
    status: src.status || '',
    sub_pay: src.sub_pay,
    subcontractor_id: src.subcontractor_id || null,
    accepted_at: src.accepted_at || null,
  };
}

function reasonCopy(reason, job) {
  const title = job.title || 'Job';
  if (reason === 'assigned') return { subject: `New job assigned: ${title}`, lead: 'You have a new job from Sumak Lawncare.' };
  if (reason === 'reassigned') return { subject: `Job assigned to you: ${title}`, lead: 'This job was assigned to you.' };
  if (reason === 'rescheduled') return { subject: `Job date changed: ${title}`, lead: 'The date on this job changed.' };
  if (reason === 'cancelled') return { subject: `Job cancelled: ${title}`, lead: 'This job was cancelled. You do not need to go.' };
  if (reason === 'manual') return { subject: `Job details: ${title}`, lead: 'Here are the details for your job.' };
  throw new Error('Unknown notify reason');
}

function jobBlock(job) {
  const safe = publicJob(job);
  const map = mapsHref(safe.address);
  const link = jobHref(safe.job_number);
  const address = safe.address
    ? `<p><strong>Address</strong><br><a href="${escapeHtml(map)}">${escapeHtml(safe.address)}</a></p>`
    : '';
  const scope = safe.description
    ? `<p><strong>Scope</strong><br>${escapeHtml(safe.description)}</p>`
    : '';
  return `
    <div style="margin:0 0 16px;padding:12px 14px;border:1px solid #eadfd4;border-radius:10px">
      <p style="margin:0 0 8px;font-size:16px"><strong>${escapeHtml(safe.job_number)} ${escapeHtml(safe.title)}</strong></p>
      ${address}
      <p><strong>Date</strong><br>${escapeHtml(formatYMD(safe.scheduled_date))}</p>
      ${scope}
      <p><strong>Your pay</strong><br>${escapeHtml(formatMoney(safe.sub_pay))}</p>
      <p><a href="${escapeHtml(link)}">Open this job in the sub portal</a></p>
    </div>`;
}

export function composeJobEmail({ job, subName, reason }) {
  if (!REASONS.has(reason)) throw new Error('Unknown notify reason');
  const safe = publicJob(job);
  const copy = reasonCopy(reason, safe);
  const html = `<div style="font-family:Georgia,serif;color:#2b2118;line-height:1.45">
    <p>Hi ${escapeHtml(subName || 'there')},</p>
    <p>${escapeHtml(copy.lead)}</p>
    ${jobBlock(safe)}
    <p>Sumak Lawncare<br>${escapeHtml(OFFICE_EMAIL)}</p>
  </div>`;
  const text = [
    `Hi ${subName || 'there'},`,
    '',
    copy.lead,
    '',
    `${safe.job_number} ${safe.title}`,
    safe.address ? `Address: ${safe.address}` : '',
    safe.address ? `Map: ${mapsHref(safe.address)}` : '',
    `Date: ${formatYMD(safe.scheduled_date)}`,
    safe.description ? `Scope: ${safe.description}` : '',
    `Your pay: ${formatMoney(safe.sub_pay)}`,
    `Open: ${jobHref(safe.job_number)}`,
  ].filter(Boolean).join('\n');
  return { subject: copy.subject, html, text };
}

export function composeReminderEmail({ subName, jobs }) {
  const list = (jobs || []).map(publicJob);
  const subject = list.length === 1
    ? `Tomorrow: ${list[0].title}`
    : `Tomorrow: ${list.length} jobs`;
  const html = `<div style="font-family:Georgia,serif;color:#2b2118;line-height:1.45">
    <p>Hi ${escapeHtml(subName || 'there')},</p>
    <p>Here is what you have scheduled tomorrow.</p>
    ${list.map((job) => jobBlock(job)).join('')}
    <p>Sumak Lawncare<br>${escapeHtml(OFFICE_EMAIL)}</p>
  </div>`;
  const text = [
    `Hi ${subName || 'there'},`,
    '',
    'Tomorrow:',
    ...list.map((j) => `${j.job_number} ${j.title} · ${formatYMD(j.scheduled_date)} · ${formatMoney(j.sub_pay)} · ${jobHref(j.job_number)}`),
  ].join('\n');
  return { subject, html, text };
}

export function composeOfficeEmail({ subject, intro, lines }) {
  const safeLines = lines || [];
  const html = `<div style="font-family:Georgia,serif;color:#2b2118;line-height:1.45">
    <p>${escapeHtml(intro)}</p>
    ${safeLines.length ? `<ul>${safeLines.map((line) => `<li>${escapeHtml(line)}</li>`).join('')}</ul>` : '<p>Nothing to list.</p>'}
    <p>Sumak Ops</p>
  </div>`;
  const text = [intro, '', ...(safeLines.length ? safeLines : ['Nothing to list.'])].join('\n');
  return { subject, html, text };
}

export function pushPayload({ title, body, url, linkType, linkId }) {
  return JSON.stringify({
    title: String(title || 'Sumak Ops').slice(0, 80),
    body: String(body || '').slice(0, 180),
    url: url || (APP_ORIGIN + '/'),
    linkType: linkType || null,
    linkId: linkId || null,
  });
}

export function jobLabel(job) {
  const safe = publicJob(job);
  return [safe.job_number, safe.title].filter(Boolean).join(' ');
}
