// Sumak Ops — job email, web push, day-before reminder, evening recap.
//
// Deploy (Juand, from a machine logged into the Supabase CLI):
//   supabase functions deploy job-comms --project-ref nrnnpprcshkgroghhbro --no-verify-jwt
//
// Secrets this function reads. Set them in the dashboard
// (Project Settings → Edge Functions → Secrets) or with the CLI.
// Do not put the private values in git.
//
//   RESEND_API_KEY
//     Already used by the send-email function. This function tries
//     send-email first, then Resend directly with the same key.
//     From address: Sumak Lawncare <office@sumaklawncare.com>
//
//   VAPID_PUBLIC_KEY
//     Must be the same value as VAPID_PUBLIC_KEY in index.html.
//     The app already ships a public key. If you still have the matching
//     private key, set that pair. If you do not, generate a new pair and
//     replace the public key in index.html in the same deploy:
//       npx web-push generate-vapid-keys
//
//   VAPID_PRIVATE_KEY
//     The private half of that pair. Never put it in the app or in git.
//
//   VAPID_SUBJECT
//     mailto:office@sumaklawncare.com
//
//   CRON_SECRET
//     A long random string. The same value goes in Supabase Vault so
//     pg_cron can call this function. See Part 3 of
//     sql/2026-10-24-sub-office-comms.sql.
//       openssl rand -base64 32
//
// SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY are
// injected into Edge Functions. You do not set those by hand.
//
// User actions require a logged-in Supabase JWT. reminder and recap
// require the x-cron-secret header. The browser never supplies the
// email HTML. This function loads the job and writes the email itself.
// It does not select or print the client price.

import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';
import {
  APP_ORIGIN,
  OFFICE_EMAIL,
  composeJobEmail,
  composeOfficeEmail,
  composeReminderEmail,
  jobHref,
  jobLabel,
  publicJob,
  pushPayload,
} from './compose.js';

const SAFE_JOB = 'id, job_number, title, description, address, scheduled_date, status, sub_pay, subcontractor_id, accepted_at, completed_at, deleted_at';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REASONS = new Set(['assigned', 'reassigned', 'rescheduled', 'cancelled', 'manual']);
const STATUS_KINDS = new Set(['accept', 'start', 'complete', 'photo']);

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

function boiseParts(date) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Boise',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(date);
  const get = (type) => parts.find((p) => p.type === type)?.value || '';
  return { ymd: `${get('year')}-${get('month')}-${get('day')}`, hour: Number(get('hour')) };
}

function boiseYMD(date = new Date()) {
  return boiseParts(date).ymd;
}

function addDaysYMD(ymd, days) {
  const [y, m, d] = ymd.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + days));
  return dt.toISOString().slice(0, 10);
}

function onBoiseDay(value, ymd) {
  if (!value) return false;
  const dt = new Date(value);
  if (Number.isNaN(dt.getTime())) return false;
  return boiseYMD(dt) === ymd;
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

async function signedInUser(req) {
  const header = req.headers.get('Authorization') || '';
  if (!header.toLowerCase().startsWith('bearer ')) return null;
  const token = header.slice(7).trim();
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!token || token === service) return null;
  const url = Deno.env.get('SUPABASE_URL') || '';
  const anon = Deno.env.get('SUPABASE_ANON_KEY') || '';
  if (!url || !anon) return null;
  const res = await fetch(`${url}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: anon },
  });
  if (!res.ok) return null;
  const user = await res.json();
  return user?.id ? user : null;
}

function cronOk(req) {
  const expected = Deno.env.get('CRON_SECRET') || '';
  const got = req.headers.get('x-cron-secret') || '';
  return timingSafeEqual(expected, got);
}

async function loadProfile(admin, userId) {
  const { data, error } = await admin.from('profiles').select('id, role, subcontractor_id').eq('id', userId).maybeSingle();
  if (error) throw new Error(error.message);
  return data;
}

async function loadJob(admin, jobId) {
  const { data, error } = await admin.from('jobs').select(SAFE_JOB).eq('id', jobId).maybeSingle();
  if (error) throw new Error(error.message);
  if (!data || data.deleted_at) return null;
  return data;
}

async function loadSub(admin, subId) {
  if (!subId) return null;
  const { data, error } = await admin.from('subcontractors').select('id, name, email').eq('id', subId).maybeSingle();
  if (error) throw new Error(error.message);
  return data;
}

async function sendOfficeEmail({ to, subject, html }) {
  const url = Deno.env.get('SUPABASE_URL') || '';
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (url && key) {
    try {
      const res = await fetch(`${url}/functions/v1/send-email`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${key}`,
          apikey: key,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ to: [to], subject, html }),
      });
      if (res.ok) {
        const data = await res.json().catch(() => ({}));
        if (!data?.error) return { via: 'send-email' };
      }
    } catch (_err) {
      // Fall through to Resend.
    }
  }
  const resendKey = Deno.env.get('RESEND_API_KEY') || '';
  if (!resendKey) throw new Error('Email is not configured. Set RESEND_API_KEY.');
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${resendKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: `Sumak Lawncare <${OFFICE_EMAIL}>`,
      to: [to],
      subject,
      html,
    }),
  });
  if (!res.ok) {
    const detail = await res.text();
    throw new Error(`Resend rejected the email (${res.status}): ${detail.slice(0, 240)}`);
  }
  return { via: 'resend' };
}

function vapidReady() {
  return !!(Deno.env.get('VAPID_PUBLIC_KEY') && Deno.env.get('VAPID_PRIVATE_KEY') && Deno.env.get('VAPID_SUBJECT'));
}

async function loadPushRows(admin, filter) {
  let q = admin.from('push_subscriptions').select('id, endpoint, p256dh, auth_key');
  if (filter.role) q = q.eq('recipient_role', filter.role);
  if (filter.subId) q = q.eq('recipient_sub_id', filter.subId);
  if (filter.userId) q = q.eq('user_id', filter.userId);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return data || [];
}

async function sendPush(admin, rows, payload) {
  if (!rows.length) return { push: 'none', sent: 0 };
  if (!vapidReady()) return { push: 'unconfigured', sent: 0, push_error: 'Set VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, and VAPID_SUBJECT.' };
  webpush.setVapidDetails(
    Deno.env.get('VAPID_SUBJECT') || '',
    Deno.env.get('VAPID_PUBLIC_KEY') || '',
    Deno.env.get('VAPID_PRIVATE_KEY') || '',
  );
  let sent = 0;
  let failed = 0;
  for (const row of rows) {
    if (!row.endpoint || !row.p256dh || !row.auth_key) continue;
    try {
      await webpush.sendNotification(
        { endpoint: row.endpoint, keys: { p256dh: row.p256dh, auth: row.auth_key } },
        payload,
      );
      sent++;
    } catch (err) {
      const code = err?.statusCode;
      if (code === 404 || code === 410) {
        await admin.from('push_subscriptions').delete().eq('id', row.id);
      } else {
        failed++;
      }
    }
  }
  if (sent === 0 && failed > 0) return { push: 'failed', sent: 0, push_error: 'The push service rejected the notification.' };
  if (sent === 0) return { push: 'none', sent: 0 };
  return { push: 'sent', sent };
}

async function notifyInApp(admin, row) {
  const { error } = await admin.from('notifications').insert(row);
  if (error) throw new Error(error.message);
}

function pushForJob(job, body) {
  return pushPayload({
    title: 'Sumak Ops',
    body,
    url: jobHref(job.job_number),
    linkType: 'job',
    linkId: job.id,
  });
}

async function handleJobEmail(admin, profile, body) {
  if (profile?.role !== 'admin') return json(403, { error: 'Only the office can email a sub about a job.' });
  const reason = String(body.reason || 'manual');
  if (!REASONS.has(reason)) return json(400, { error: 'Unknown notify reason.' });
  const job = await loadJob(admin, body.job_id);
  if (!job) return json(404, { error: 'Job not found.' });
  if (!job.subcontractor_id) return json(400, { error: 'This job has no subcontractor.' });
  const sub = await loadSub(admin, job.subcontractor_id);
  if (!sub?.email) return json(400, { error: 'This sub has no email on file.' });
  const mail = composeJobEmail({ job, subName: sub.name, reason });
  await sendOfficeEmail({ to: sub.email, subject: mail.subject, html: mail.html });
  const note = mail.subject;
  await notifyInApp(admin, {
    recipient_role: 'sub',
    recipient_sub_id: sub.id,
    message: note,
    link_type: 'job',
    link_id: job.id,
  });
  const rows = await loadPushRows(admin, { role: 'sub', subId: sub.id });
  const push = await sendPush(admin, rows, pushForJob(job, note));
  return json(200, { ok: true, email: 'sent', ...push });
}

function statusText(kind, name, job, count) {
  const label = jobLabel(job);
  if (kind === 'accept') return `${name} accepted ${label}`;
  if (kind === 'start') return `${name} started ${label}`;
  if (kind === 'complete') return `${name} completed ${label}`;
  const n = count === 1 ? '1 photo' : `${count} photos`;
  return `${name} added ${n} to ${label}`;
}

async function handleStatus(admin, profile, body) {
  const kind = String(body.kind || '');
  if (!STATUS_KINDS.has(kind)) return json(400, { error: 'Unknown status update.' });
  const job = await loadJob(admin, body.job_id);
  if (!job) return json(404, { error: 'Job not found.' });
  if (profile?.role === 'admin' || !profile?.subcontractor_id || profile.subcontractor_id !== job.subcontractor_id) {
    return json(403, { error: 'Only the assigned sub can update the office from this job.' });
  }
  const sub = await loadSub(admin, profile.subcontractor_id);
  const count = Math.min(20, Math.max(1, Number(body.count) || 1));
  const message = statusText(kind, sub?.name || 'A sub', job, count);
  await notifyInApp(admin, {
    recipient_role: 'admin',
    recipient_sub_id: null,
    message,
    link_type: 'job',
    link_id: job.id,
  });
  const rows = await loadPushRows(admin, { role: 'admin' });
  const push = await sendPush(admin, rows, pushForJob(job, message));
  return json(200, { ok: true, notified: true, ...push });
}

async function handleMessage(admin, user, profile, body) {
  if (!UUID.test(String(body.message_id || ''))) return json(400, { error: 'Message id is required.' });
  const { data: message, error } = await admin
    .from('job_messages')
    .select('id, job_id, author_id, body, photo_path, created_at')
    .eq('id', body.message_id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!message) return json(404, { error: 'Message not found.' });
  if (message.author_id !== user.id) return json(403, { error: 'You can only notify about your own message.' });
  const job = await loadJob(admin, message.job_id);
  if (!job) return json(404, { error: 'Job not found.' });
  const text = String(message.body || '').trim();
  const excerpt = text ? text.slice(0, 140) : (message.photo_path ? 'Sent a photo' : 'New message');
  if (profile?.role === 'admin') {
    if (!job.subcontractor_id) return json(200, { ok: true, notified: false, error: 'No sub is assigned.' });
    const sub = await loadSub(admin, job.subcontractor_id);
    const note = `Office on ${jobLabel(job)}: ${excerpt}`;
    await notifyInApp(admin, {
      recipient_role: 'sub',
      recipient_sub_id: job.subcontractor_id,
      message: note,
      link_type: 'job',
      link_id: job.id,
    });
    const rows = await loadPushRows(admin, { role: 'sub', subId: job.subcontractor_id });
    const push = await sendPush(admin, rows, pushForJob(job, note));
    return json(200, { ok: true, notified: true, sub: sub?.name || null, ...push });
  }
  if (!profile?.subcontractor_id || profile.subcontractor_id !== job.subcontractor_id) {
    return json(403, { error: 'That job is not assigned to you.' });
  }
  const sub = await loadSub(admin, profile.subcontractor_id);
  const note = `${sub?.name || 'A sub'} on ${jobLabel(job)}: ${excerpt}`;
  await notifyInApp(admin, {
    recipient_role: 'admin',
    recipient_sub_id: null,
    message: note,
    link_type: 'job',
    link_id: job.id,
  });
  const rows = await loadPushRows(admin, { role: 'admin' });
  const push = await sendPush(admin, rows, pushForJob(job, note));
  return json(200, { ok: true, notified: true, ...push });
}

async function handleTestPush(admin, user) {
  const rows = await loadPushRows(admin, { userId: user.id });
  if (!rows.length) return json(400, { error: 'Enable notifications on this device first.' });
  const push = await sendPush(admin, rows, pushPayload({
    title: 'Sumak Ops',
    body: 'Test push from Sumak Ops',
    url: APP_ORIGIN + '/',
    linkType: 'dashboard',
    linkId: null,
  }));
  if (push.push === 'unconfigured') return json(400, { error: push.push_error });
  if (push.push === 'failed') return json(502, { error: push.push_error });
  return json(200, { ok: true, ...push });
}

async function claimDispatch(admin, action, ymd) {
  const { error } = await admin.from('comms_dispatches').insert({ action, boise_date: ymd });
  if (!error) return true;
  if (error.code === '23505') return false;
  throw new Error(error.message);
}

async function releaseDispatch(admin, action, ymd) {
  await admin.from('comms_dispatches').delete().eq('action', action).eq('boise_date', ymd);
}

async function jobsOnDate(admin, ymd) {
  const { data, error } = await admin
    .from('jobs')
    .select(SAFE_JOB)
    .eq('scheduled_date', ymd)
    .is('deleted_at', null)
    .neq('status', 'Cancelled');
  if (error) throw new Error(error.message);
  return (data || []).filter((job) => job.subcontractor_id);
}

async function handleReminder(admin, dryRun) {
  const today = boiseYMD();
  const tomorrow = addDaysYMD(today, 1);
  const jobs = (await jobsOnDate(admin, tomorrow)).map(publicJob);
  const subIds = [...new Set(jobs.map((job) => job.subcontractor_id))];
  const subs = [];
  if (subIds.length) {
    const { data, error } = await admin.from('subcontractors').select('id, name, email').in('id', subIds);
    if (error) throw new Error(error.message);
    subs.push(...(data || []));
  }
  const bySub = new Map(subs.map((sub) => [sub.id, sub]));
  const groups = subIds.map((id) => ({
    sub: bySub.get(id) || { id, name: 'there', email: '' },
    jobs: jobs.filter((job) => job.subcontractor_id === id),
  }));
  const unaccepted = jobs.filter((job) => !job.accepted_at);
  const preview = groups.map((group) => composeReminderEmail({ subName: group.sub.name, jobs: group.jobs }));
  const officeLines = unaccepted.map((job) => {
    const sub = bySub.get(job.subcontractor_id);
    return `${jobLabel(job)} · ${sub?.name || 'Unassigned sub'} · not accepted`;
  });
  const officeMail = composeOfficeEmail({
    subject: unaccepted.length
      ? `Tomorrow: ${unaccepted.length} job${unaccepted.length === 1 ? '' : 's'} not accepted`
      : 'Tomorrow: every assigned job is accepted',
    intro: unaccepted.length
      ? 'These jobs are scheduled tomorrow and the sub has not accepted yet.'
      : 'Every job scheduled tomorrow has been accepted.',
    lines: officeLines,
  });
  if (dryRun) {
    return json(200, {
      ok: true,
      dry_run: true,
      tomorrow,
      subs: groups.map((group) => ({
        name: group.sub.name,
        email: group.sub.email || null,
        jobs: group.jobs.map((job) => job.job_number),
        subject: composeReminderEmail({ subName: group.sub.name, jobs: group.jobs }).subject,
      })),
      office_subject: officeMail.subject,
      office_lines: officeLines,
    });
  }
  const claimed = await claimDispatch(admin, 'reminder', today);
  if (!claimed) return json(200, { ok: true, skipped: 'already sent' });
  let emails = 0;
  let emailErrors = 0;
  try {
    for (const group of groups) {
      const mail = composeReminderEmail({ subName: group.sub.name, jobs: group.jobs });
      if (group.sub.email) {
        try {
          await sendOfficeEmail({ to: group.sub.email, subject: mail.subject, html: mail.html });
          emails++;
        } catch (err) {
          emailErrors++;
          console.error('reminder email failed', group.sub.id, err?.message || err);
        }
      }
      const rows = await loadPushRows(admin, { role: 'sub', subId: group.sub.id });
      const first = group.jobs[0];
      const body = group.jobs.length === 1
        ? `Tomorrow: ${jobLabel(first)}`
        : `Tomorrow: ${group.jobs.length} jobs, starting with ${jobLabel(first)}`;
      await sendPush(admin, rows, pushPayload({
        title: 'Sumak Ops',
        body,
        url: first ? jobHref(first.job_number) : APP_ORIGIN + '/my-jobs',
        linkType: 'job',
        linkId: first?.id || null,
      }));
      if (first) {
        await notifyInApp(admin, {
          recipient_role: 'sub',
          recipient_sub_id: group.sub.id,
          message: body,
          link_type: 'job',
          link_id: first.id,
        });
      }
    }
    if (groups.length && emails === 0 && emailErrors > 0) {
      throw new Error('Reminder emails failed.');
    }
    if (unaccepted.length) {
      await sendOfficeEmail({ to: OFFICE_EMAIL, subject: officeMail.subject, html: officeMail.html });
    }
    for (const job of unaccepted) {
      const sub = bySub.get(job.subcontractor_id);
      await notifyInApp(admin, {
        recipient_role: 'admin',
        recipient_sub_id: null,
        message: `${jobLabel(job)} tomorrow is still waiting on ${sub?.name || 'the sub'} to accept`,
        link_type: 'job',
        link_id: job.id,
      });
    }
    if (unaccepted.length) {
      const rows = await loadPushRows(admin, { role: 'admin' });
      await sendPush(admin, rows, pushPayload({
        title: 'Sumak Ops',
        body: unaccepted.length === 1
          ? `Tomorrow: ${jobLabel(unaccepted[0])} is not accepted yet`
          : `Tomorrow: ${unaccepted.length} jobs are not accepted yet`,
        url: APP_ORIGIN + '/',
        linkType: 'dashboard',
        linkId: null,
      }));
    }
  } catch (err) {
    if (emails === 0) await releaseDispatch(admin, 'reminder', today);
    throw err;
  }
  return json(200, { ok: true, emails, email_errors: emailErrors, unaccepted: unaccepted.length });
}

async function rowsSince(admin, table, columns, column) {
  const today = boiseYMD();
  const start = addDaysYMD(today, -1) + 'T00:00:00Z';
  const end = addDaysYMD(today, 2) + 'T00:00:00Z';
  const { data, error } = await admin.from(table).select(columns).gte(column, start).lt(column, end);
  if (error) throw new Error(error.message);
  return (data || []).filter((row) => onBoiseDay(row[column], today));
}

async function handleRecap(admin, dryRun) {
  const today = boiseYMD();
  const accepted = (await rowsSince(admin, 'jobs', SAFE_JOB, 'accepted_at')).filter((job) => !job.deleted_at);
  const completed = (await rowsSince(admin, 'jobs', SAFE_JOB, 'completed_at')).filter((job) => !job.deleted_at);
  const photos = await rowsSince(admin, 'job_photos', 'id, job_id, created_at', 'created_at');
  const messages = await rowsSince(admin, 'job_messages', 'id, job_id, author_id, body, photo_path, created_at', 'created_at');
  const starts = await rowsSince(admin, 'activity_log', 'id, action, actor_name, detail, entity_id, created_at', 'created_at');
  const started = starts.filter((row) => row.action === 'Job started');
  const jobIds = [...new Set([
    ...photos.map((row) => row.job_id),
    ...messages.map((row) => row.job_id),
    ...started.map((row) => row.entity_id),
  ].filter(Boolean))];
  const jobs = new Map();
  for (const job of accepted.concat(completed)) jobs.set(job.id, job);
  if (jobIds.length) {
    const { data, error } = await admin.from('jobs').select(SAFE_JOB).in('id', jobIds);
    if (error) throw new Error(error.message);
    for (const job of data || []) jobs.set(job.id, job);
  }
  const subIds = [...new Set([...jobs.values()].map((job) => job.subcontractor_id).filter(Boolean))];
  const subs = new Map();
  if (subIds.length) {
    const { data, error } = await admin.from('subcontractors').select('id, name, email').in('id', subIds);
    if (error) throw new Error(error.message);
    for (const sub of data || []) subs.set(sub.id, sub);
  }
  const authorIds = [...new Set(messages.map((row) => row.author_id).filter(Boolean))];
  const authors = new Map();
  if (authorIds.length) {
    const { data, error } = await admin.from('profiles').select('id, role, subcontractor_id').in('id', authorIds);
    if (error) throw new Error(error.message);
    for (const profile of data || []) authors.set(profile.id, profile);
  }
  const nameFor = (job) => subs.get(job?.subcontractor_id)?.name || 'A sub';
  const lines = [];
  for (const job of accepted) lines.push(`${nameFor(job)} accepted ${jobLabel(job)}`);
  for (const row of started) {
    const job = jobs.get(row.entity_id);
    lines.push(`${row.actor_name || nameFor(job)} started ${job ? jobLabel(job) : (row.detail || 'a job')}`);
  }
  for (const job of completed) lines.push(`${nameFor(job)} completed ${jobLabel(job)}`);
  const photosByJob = new Map();
  for (const photo of photos) photosByJob.set(photo.job_id, (photosByJob.get(photo.job_id) || 0) + 1);
  for (const [jobId, count] of photosByJob) {
    const job = jobs.get(jobId);
    lines.push(`${count} photo${count === 1 ? '' : 's'} added on ${job ? jobLabel(job) : 'a job'}`);
  }
  for (const message of messages) {
    const author = authors.get(message.author_id);
    if (author?.role === 'admin') continue;
    const job = jobs.get(message.job_id);
    const who = author?.subcontractor_id ? (subs.get(author.subcontractor_id)?.name || nameFor(job)) : nameFor(job);
    const text = String(message.body || '').trim();
    const excerpt = text ? text.slice(0, 140) : (message.photo_path ? 'Sent a photo' : 'New message');
    lines.push(`${who} messaged on ${job ? jobLabel(job) : 'a job'}: ${excerpt}`);
  }
  const mail = composeOfficeEmail({
    subject: `Sub activity ${today}`,
    intro: lines.length ? `Sub activity on ${today} (America/Boise).` : `No sub activity on ${today} (America/Boise).`,
    lines,
  });
  if (dryRun) return json(200, { ok: true, dry_run: true, today, lines, subject: mail.subject });
  const claimed = await claimDispatch(admin, 'recap', today);
  if (!claimed) return json(200, { ok: true, skipped: 'already sent' });
  try {
    await sendOfficeEmail({ to: OFFICE_EMAIL, subject: mail.subject, html: mail.html });
  } catch (err) {
    await releaseDispatch(admin, 'recap', today);
    throw err;
  }
  return json(200, { ok: true, lines: lines.length });
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
  const action = String(body.action || '');
  try {
    const admin = adminClient();
    if (action === 'reminder' || action === 'recap') {
      if (!cronOk(req)) return json(401, { error: 'Not allowed.' });
      const dryRun = body.dry_run === true;
      if (action === 'reminder') return await handleReminder(admin, dryRun);
      return await handleRecap(admin, dryRun);
    }
    const user = await signedInUser(req);
    if (!user) return json(401, { error: 'Sign in required.' });
    const profile = await loadProfile(admin, user.id);
    if (!profile) return json(403, { error: 'No profile for this login.' });
    if (action === 'job_email') {
      if (!UUID.test(String(body.job_id || ''))) return json(400, { error: 'Job id is required.' });
      return await handleJobEmail(admin, profile, body);
    }
    if (action === 'status') {
      if (!UUID.test(String(body.job_id || ''))) return json(400, { error: 'Job id is required.' });
      return await handleStatus(admin, profile, body);
    }
    if (action === 'message') return await handleMessage(admin, user, profile, body);
    if (action === 'test_push') return await handleTestPush(admin, user);
    return json(400, { error: 'Unknown action.' });
  } catch (err) {
    console.error('job-comms', action, err?.message || err);
    return json(500, { error: err?.message || 'The office mailer failed.' });
  }
});
