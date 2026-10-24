import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  composeJobEmail,
  composeOfficeEmail,
  composeReminderEmail,
  publicJob,
} from '../supabase/functions/job-comms/compose.js';

const poisoned = {
  title: 'Leaf cleanup',
  job_number: 'SMK-13040',
  address: '123 Main St, Boise ID',
  scheduled_date: '2026-10-24',
  description: 'Front beds and the parkway',
  sub_pay: 80,
  status: 'Pending',
  client_price: 250.5,
  margin: 'SECRET-MARGIN',
  cost: 999,
  office_price: 1111,
  notes: 'Do not print this office note',
};

function joined(mail) {
  return `${mail.subject}\n${mail.html}\n${mail.text}`;
}

test('job email keeps the sub pay and drops office money', () => {
  const mail = composeJobEmail({ job: poisoned, subName: 'Jaime', reason: 'manual' });
  const blob = joined(mail);
  assert.match(mail.subject, /Leaf cleanup/);
  assert.match(blob, /SMK-13040/);
  assert.match(blob, /123 Main St, Boise ID/);
  assert.match(blob, /maps\/dir/);
  assert.match(blob, /Front beds and the parkway/);
  assert.match(blob, /\$80\.00/);
  assert.match(blob, /https:\/\/warm-manatee-1de5e1\.netlify\.app\/jobs\/SMK-13040/);
  assert.match(blob, /Oct 24, 2026/);
  for (const secret of ['250.5', '250.50', 'SECRET-MARGIN', '999', '1111', 'Do not print this office note']) {
    assert.equal(blob.includes(secret), false, secret);
  }
  assert.deepEqual(Object.keys(publicJob(poisoned)).sort(), [
    'accepted_at', 'address', 'description', 'id', 'job_number', 'scheduled_date', 'status', 'sub_pay', 'subcontractor_id', 'title',
  ]);
});

test('assign, reschedule, and cancel subjects stay on the job title', () => {
  assert.match(composeJobEmail({ job: poisoned, subName: 'Jaime', reason: 'assigned' }).subject, /^New job assigned:/);
  assert.match(composeJobEmail({ job: poisoned, subName: 'Jaime', reason: 'reassigned' }).subject, /^Job assigned to you:/);
  assert.match(composeJobEmail({ job: poisoned, subName: 'Jaime', reason: 'rescheduled' }).subject, /^Job date changed:/);
  assert.match(composeJobEmail({ job: poisoned, subName: 'Jaime', reason: 'cancelled' }).subject, /^Job cancelled:/);
  assert.throws(() => composeJobEmail({ job: poisoned, subName: 'Jaime', reason: 'client_price' }));
});

test('reminder lists each job pay and nothing else from the row', () => {
  const other = { ...poisoned, job_number: 'SMK-2', title: 'Hedge trim', sub_pay: 40, client_price: 777 };
  const mail = composeReminderEmail({ subName: 'Jaime', jobs: [poisoned, other] });
  const blob = joined(mail);
  assert.match(mail.subject, /2 jobs/);
  assert.match(blob, /\$80\.00/);
  assert.match(blob, /\$40\.00/);
  assert.match(blob, /Hedge trim/);
  assert.equal(blob.includes('777'), false);
  assert.equal(blob.includes('250.5'), false);
});

test('office recap escapes text and does not invent prices', () => {
  const mail = composeOfficeEmail({
    subject: 'Sub activity 2026-10-23',
    intro: 'Sub activity on 2026-10-23.',
    lines: ['Jaime accepted SMK-13040 Leaf cleanup', '<script>250.50</script>'],
  });
  assert.match(mail.html, /&lt;script&gt;/);
  assert.equal(mail.html.includes('<script>'), false);
});

test('the function source does not select office price columns', () => {
  const src = [
    readFileSync(new URL('../supabase/functions/job-comms/index.ts', import.meta.url), 'utf8'),
    readFileSync(new URL('../supabase/functions/job-comms/compose.js', import.meta.url), 'utf8'),
    readFileSync(new URL('../supabase/functions/send-email/index.ts', import.meta.url), 'utf8'),
    readFileSync(new URL('../supabase/functions/resend-webhook/index.ts', import.meta.url), 'utf8'),
    readFileSync(new URL('../supabase/functions/resend-webhook/verify.js', import.meta.url), 'utf8'),
  ].join('\n');
  for (const name of ['client_price', 'office_price', 'margin_pct']) {
    assert.equal(src.includes(name), false, name);
  }
});
