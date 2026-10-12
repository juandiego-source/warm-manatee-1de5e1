-- Sumak Ops — fixes for Juand to run in the Supabase SQL editor
-- Project: nrnnpprcshkgroghhbro
--
-- Run ONE block at a time. Do not run this file as a single script.
-- Nothing here emails, texts, or notifies a client or a sub.
-- Block 2 calls the existing send_attention_summary() once. That writes an
-- admin notification, and the existing push pipeline may deliver it to the
-- admin phone. It does not message clients or subs.
--
-- Do not change generate-recurring-jobs. Do not edit process_recurring_services().
-- That function already has a duplicate guard and stays quiet on purpose.
--
-- Recommended cron hour: 14 UTC (0 14 * * 1,5). Explanation is in Block 3.
--
-- Order that matters: run Block 6 (trigger) before Block 10 (soft-delete).
-- Until the trigger allows postgres, setting deleted_at from this editor is
-- silently undone.

-- =============================================================================
-- BLOCK 1 — Does send_attention_summary() still exist?
-- Read only. Stop if this returns no row. Do not recreate the function here.
-- =============================================================================

SELECT
  n.nspname AS schema,
  p.proname AS function,
  pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'send_attention_summary';

-- Check: exactly one row. If zero rows, the function is gone and Block 3
-- must not be run.


-- =============================================================================
-- BLOCK 2 — Run the Monday/Friday summary once, then show the new row
-- This is the manual run. It inserts whatever send_attention_summary()
-- already inserts (an admin notification). It does not add a new send path.
-- =============================================================================

SELECT public.send_attention_summary();

-- Check: the newest admin notification. A row created just now means the
-- function ran. If nothing needed attention, the function may insert nothing;
-- in that case the newest row will be older, and that is still a successful run.
SELECT
  id,
  recipient_role,
  recipient_sub_id,
  message,
  link_type,
  link_id,
  read,
  created_at
FROM public.notifications
WHERE recipient_role = 'admin'
ORDER BY created_at DESC
LIMIT 5;


-- =============================================================================
-- BLOCK 3 — Put attention-summary back, exactly once, at 8:00 AM Boise
--
-- pg_cron stores a fixed UTC time. It does not follow daylight saving.
-- Boise (America/Boise) is on MDT, UTC-6, until 2:00 AM on Sunday Nov 1, 2026.
--   8:00 AM MDT = 14:00 UTC.
-- From Nov 1, 2026 until the second Sunday in March 2027, Boise is on MST, UTC-7.
--   8:00 AM MST = 15:00 UTC.
--
-- Recommendation: schedule 14 UTC ('0 14 * * 1,5').
--   * That is 8:00 AM Boise for the rest of October (Oct 16, 19, 23, 26, 30).
--   * It is the same expression the missing job used.
--   * MDT is the longer season (early March through early November).
--   * After Nov 1 the same job fires at 7:00 AM MST, still before the workday.
-- Scheduling 15 UTC instead would be 9:00 AM MDT until Nov 1, then 8:00 AM MST.
-- That misses 8:00 AM on the Mondays and Fridays left in this season.
--
-- If you want exactly 8:00 AM through the winter, on the Monday after the
-- clocks change (Nov 2, 2026) run only the unschedule + schedule again with
-- '0 15 * * 1,5'. Do not leave both hours scheduled.
--
-- This block removes every cron row named attention-summary, then creates one.
-- generate-recurring-jobs is not touched.
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'send_attention_summary'
  ) THEN
    RAISE EXCEPTION 'send_attention_summary() is not in public. Nothing was scheduled.';
  END IF;
END $$;

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'attention-summary';

SELECT cron.schedule(
  'attention-summary',
  '0 14 * * 1,5',
  $$SELECT public.send_attention_summary();$$
);

-- Check: exactly one attention-summary, at 14:00 UTC on Monday and Friday.
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'attention-summary';


-- =============================================================================
-- BLOCK 4 — cron.job, both jobs
-- Read only.
-- =============================================================================

SELECT jobid, jobname, schedule, command, active
FROM cron.job
ORDER BY jobname;

-- Check:
--   attention-summary        schedule 0 14 * * 1,5    one row, active
--   generate-recurring-jobs  schedule 0 12 * * 5      one row, unchanged
SELECT jobname, schedule, count(*) AS copies
FROM cron.job
WHERE jobname IN ('attention-summary', 'generate-recurring-jobs')
GROUP BY jobname, schedule
ORDER BY jobname;


-- =============================================================================
-- BLOCK 5 — Read the live protect_job_admin_fields() before replacing it
-- Read only. If the body protects columns other than sub_pay, client_price,
-- status, payment_status, and deleted_at, stop and add those columns to
-- Block 6 before you run it.
-- =============================================================================

SELECT pg_get_functiondef(p.oid) AS current_definition
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'protect_job_admin_fields';

SELECT tgname, pg_get_triggerdef(t.oid) AS trigger_def
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'jobs'
  AND NOT t.tgisinternal
  AND tgname = 'protect_job_admin_fields_trigger';


-- =============================================================================
-- BLOCK 6 — Let the SQL editor and service_role change admin job fields
--
-- The trigger rewrites sub_pay, client_price, status, payment_status, and
-- deleted_at back to the old values whenever is_admin() is false. The SQL
-- editor connects as postgres and has no admin JWT, so is_admin() is false
-- and the UPDATE succeeds without changing those columns.
--
-- Allow the write when the active role is postgres or service_role.
-- Do not treat a missing auth.uid() as trusted: anon has no uid either.
-- Do not trust session_user. SET ROLE authenticated leaves session_user as
-- postgres, which would let Block 8's simulated sub through.
-- The function stays SECURITY INVOKER so current_user is the role that ran
-- the UPDATE. A security-definer function would see current_user as the
-- owner and would unlock these columns for everyone.
-- Subs stay blocked: their active role is authenticated, and is_admin() is false.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.protect_job_admin_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $fn$
DECLARE
  actor text := current_user;
  active_role text := nullif(current_setting('role', true), 'none');
BEGIN
  IF public.is_admin()
     OR actor IN ('postgres', 'service_role')
     OR active_role IN ('postgres', 'service_role')
  THEN
    RETURN NEW;
  END IF;

  NEW.sub_pay := OLD.sub_pay;
  NEW.client_price := OLD.client_price;
  NEW.status := OLD.status;
  NEW.payment_status := OLD.payment_status;
  NEW.deleted_at := OLD.deleted_at;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS protect_job_admin_fields_trigger ON public.jobs;

CREATE TRIGGER protect_job_admin_fields_trigger
  BEFORE UPDATE ON public.jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_job_admin_fields();

-- Check: security definer is false, search_path is public, trigger is BEFORE UPDATE.
SELECT
  p.proname,
  p.prosecdef AS security_definer,
  p.proconfig
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'protect_job_admin_fields';

SELECT tgname, pg_get_triggerdef(t.oid) AS trigger_def
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'jobs'
  AND NOT t.tgisinternal
  AND tgname = 'protect_job_admin_fields_trigger';


-- =============================================================================
-- BLOCK 7 — Test A. An update from this SQL editor sticks, then is put back
-- Uses whatever role this editor is using (expect postgres).
-- Adds one cent to one job's sub_pay, reads it back, then restores the
-- original value in the same block. The job ends as it started.
-- If the trigger still resets the column, this block raises and changes nothing.
-- =============================================================================

SELECT current_user AS editor_role, session_user AS session_role;

CREATE TEMP TABLE IF NOT EXISTS editor_proof (
  job_id uuid,
  job_number text,
  before_sub_pay numeric,
  during_sub_pay numeric,
  after_sub_pay numeric,
  update_stuck boolean
);

TRUNCATE editor_proof;

DO $proof$
DECLARE
  jid uuid;
  jnum text;
  before_pay numeric;
  during_pay numeric;
  after_pay numeric;
  bumped numeric;
BEGIN
  SELECT j.id, j.job_number, j.sub_pay
    INTO jid, jnum, before_pay
  FROM public.jobs j
  WHERE j.deleted_at IS NULL
  ORDER BY j.created_at DESC NULLS LAST
  LIMIT 1;

  IF jid IS NULL THEN
    RAISE EXCEPTION 'No active job to test.';
  END IF;

  bumped := round(COALESCE(before_pay, 0)::numeric + 0.01, 2);

  UPDATE public.jobs
  SET sub_pay = bumped
  WHERE id = jid;

  SELECT sub_pay INTO during_pay FROM public.jobs WHERE id = jid;

  UPDATE public.jobs
  SET sub_pay = before_pay
  WHERE id = jid;

  SELECT sub_pay INTO after_pay FROM public.jobs WHERE id = jid;

  INSERT INTO editor_proof
  VALUES (
    jid,
    jnum,
    before_pay,
    during_pay,
    after_pay,
    during_pay IS NOT DISTINCT FROM bumped
      AND after_pay IS NOT DISTINCT FROM before_pay
  );

  IF during_pay IS DISTINCT FROM bumped THEN
    RAISE EXCEPTION
      'SQL editor update did not stick for role % (session %). before % during %',
      current_user, session_user, before_pay, during_pay;
  END IF;

  IF after_pay IS DISTINCT FROM before_pay THEN
    RAISE EXCEPTION
      'Could not restore sub_pay on job %. Left at %; original was %.',
      jid, after_pay, before_pay;
  END IF;
END;
$proof$;

-- Check: update_stuck is true, and after_sub_pay equals before_sub_pay.
SELECT * FROM editor_proof;


-- =============================================================================
-- BLOCK 8 — Test B. A simulated logged-in sub is still blocked
-- Whole block is one transaction and it ROLLS BACK. Nothing is saved.
-- Sets the role to authenticated and request.jwt.claims to a real sub uid,
-- then tries to change the protected columns on one of that sub's jobs.
-- A notes marker shows the UPDATE reached the row. The five admin fields
-- must still match the original values.
-- =============================================================================

BEGIN;

DO $probe$
DECLARE
  r record;
BEGIN
  SELECT
    p.id AS uid,
    j.id AS job_id,
    j.sub_pay,
    j.client_price,
    j.status,
    j.payment_status,
    j.deleted_at
  INTO r
  FROM public.profiles p
  JOIN public.jobs j
    ON j.subcontractor_id = p.subcontractor_id
   AND j.deleted_at IS NULL
  WHERE p.role = 'sub'
    AND p.subcontractor_id IS NOT NULL
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No sub profile with an active job. Rolled back. Nothing was changed.';
  END IF;

  PERFORM set_config('app.probe_uid', r.uid::text, true);
  PERFORM set_config('app.probe_job', r.job_id::text, true);
  PERFORM set_config('app.probe_sub_pay', COALESCE(r.sub_pay::text, ''), true);
  PERFORM set_config('app.probe_client_price', COALESCE(r.client_price::text, ''), true);
  PERFORM set_config('app.probe_status', COALESCE(r.status, ''), true);
  PERFORM set_config('app.probe_payment_status', COALESCE(r.payment_status, ''), true);
  PERFORM set_config('app.probe_deleted_at', COALESCE(r.deleted_at::text, ''), true);
END;
$probe$;

SELECT set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('app.probe_uid'),
    'role', 'authenticated'
  )::text,
  true
);

SELECT set_config('request.jwt.claim.sub', current_setting('app.probe_uid'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SET LOCAL ROLE authenticated;

WITH upd AS (
  UPDATE public.jobs
  SET
    notes = CASE
      WHEN notes LIKE '%[sub-probe]%' THEN notes
      ELSE concat_ws(' ', notes, '[sub-probe]')
    END,
    sub_pay = round(COALESCE(sub_pay, 0)::numeric + 25, 2),
    client_price = round(COALESCE(client_price, 0)::numeric + 25, 2),
    status = CASE WHEN status = 'Cancelled' THEN 'Pending' ELSE 'Cancelled' END,
    payment_status = CASE WHEN payment_status = 'Paid' THEN 'Unpaid' ELSE 'Paid' END,
    deleted_at = now()
  WHERE id = current_setting('app.probe_job')::uuid
  RETURNING id, notes, sub_pay, client_price, status, payment_status, deleted_at
)
SELECT
  id,
  notes LIKE '%[sub-probe]%' AS update_landed,
  sub_pay IS NOT DISTINCT FROM NULLIF(current_setting('app.probe_sub_pay'), '')::numeric AS sub_pay_blocked,
  client_price IS NOT DISTINCT FROM NULLIF(current_setting('app.probe_client_price'), '')::numeric AS client_price_blocked,
  status IS NOT DISTINCT FROM NULLIF(current_setting('app.probe_status'), '') AS status_blocked,
  payment_status IS NOT DISTINCT FROM NULLIF(current_setting('app.probe_payment_status'), '') AS payment_status_blocked,
  deleted_at IS NOT DISTINCT FROM NULLIF(current_setting('app.probe_deleted_at'), '')::timestamptz AS deleted_at_blocked,
  current_user AS acting_role,
  public.is_admin() AS is_admin
FROM upd;

-- Check: one row, update_landed true, every *_blocked column true,
-- acting_role = authenticated, is_admin = false.
-- An empty result means row security hid the job, so this did not prove the
-- trigger. The job was chosen as one assigned to that sub.

ROLLBACK;


-- =============================================================================
-- BLOCK 9 — Review John Richmond duplicates in August 2026
-- Read only. Run this, read it, then decide on Block 10.
--
-- A group is the same normalized address, the same sub, and the same date,
-- with at least one Completed + Paid job and at least one Pending job.
-- would_soft_delete is true only for a Pending copy that Block 10 will archive.
-- Pending rows already referenced by invoice_items.job_id stay (on_invoice).
-- The Completed/Paid job is never marked.
-- =============================================================================

WITH richmond AS (
  SELECT
    j.id,
    j.job_number,
    j.title,
    j.status,
    j.payment_status,
    j.scheduled_date,
    j.address,
    j.subcontractor_id,
    s.name AS sub_name,
    c.name AS customer_name,
    j.recurring_service_id,
    j.deleted_at,
    lower(trim(regexp_replace(regexp_replace(coalesce(j.address, ''), '[.,]+', '', 'g'), '\s+', ' ', 'g'))) AS addr_key,
    EXISTS (
      SELECT 1 FROM public.invoice_items ii WHERE ii.job_id = j.id
    ) AS on_invoice
  FROM public.jobs j
  JOIN public.customers c ON c.id = j.customer_id
  LEFT JOIN public.subcontractors s ON s.id = j.subcontractor_id
  WHERE j.deleted_at IS NULL
    AND c.name ILIKE '%john%richmond%'
    AND j.scheduled_date >= DATE '2026-08-01'
    AND j.scheduled_date < DATE '2026-09-01'
),
groups AS (
  SELECT addr_key, subcontractor_id, scheduled_date
  FROM richmond
  WHERE addr_key <> ''
  GROUP BY addr_key, subcontractor_id, scheduled_date
  HAVING count(*) FILTER (WHERE status = 'Completed' AND payment_status = 'Paid') >= 1
     AND count(*) FILTER (WHERE status = 'Pending') >= 1
)
SELECT
  r.scheduled_date,
  r.address,
  r.sub_name,
  r.customer_name,
  r.job_number,
  r.status,
  r.payment_status,
  r.on_invoice,
  r.recurring_service_id,
  r.id,
  (g.addr_key IS NOT NULL AND r.status = 'Pending' AND NOT r.on_invoice) AS would_soft_delete
FROM richmond r
LEFT JOIN groups g
  ON g.addr_key = r.addr_key
 AND g.scheduled_date = r.scheduled_date
 AND g.subcontractor_id IS NOT DISTINCT FROM r.subcontractor_id
ORDER BY r.scheduled_date, r.addr_key, r.status, r.job_number;

-- Check: you should see 732 W Sheridan Ave on 2026-08-14, 2026-08-21, and
-- 2026-08-28, each with a Completed/Paid row (would_soft_delete false) and
-- one or more Pending rows. Pending rows not on an invoice show
-- would_soft_delete true. Anything else in August for this client is listed
-- so a near-miss address is visible before you delete.


-- =============================================================================
-- BLOCK 10 — Soft-delete only the Pending copies
-- Run only after Block 6. Requires Block 9 to look right.
-- Sets deleted_at. Does not delete the Completed/Paid job.
-- Skips any Pending job referenced by invoice_items.job_id.
-- Does not touch jobs outside those duplicate groups.
-- =============================================================================

WITH richmond AS (
  SELECT
    j.id,
    j.status,
    j.payment_status,
    j.scheduled_date,
    j.subcontractor_id,
    lower(trim(regexp_replace(regexp_replace(coalesce(j.address, ''), '[.,]+', '', 'g'), '\s+', ' ', 'g'))) AS addr_key,
    EXISTS (
      SELECT 1 FROM public.invoice_items ii WHERE ii.job_id = j.id
    ) AS on_invoice
  FROM public.jobs j
  JOIN public.customers c ON c.id = j.customer_id
  WHERE j.deleted_at IS NULL
    AND c.name ILIKE '%john%richmond%'
    AND j.scheduled_date >= DATE '2026-08-01'
    AND j.scheduled_date < DATE '2026-09-01'
),
groups AS (
  SELECT addr_key, subcontractor_id, scheduled_date
  FROM richmond
  WHERE addr_key <> ''
  GROUP BY addr_key, subcontractor_id, scheduled_date
  HAVING count(*) FILTER (WHERE status = 'Completed' AND payment_status = 'Paid') >= 1
     AND count(*) FILTER (WHERE status = 'Pending') >= 1
),
victims AS (
  SELECT r.id
  FROM richmond r
  JOIN groups g
    ON g.addr_key = r.addr_key
   AND g.scheduled_date = r.scheduled_date
   AND g.subcontractor_id IS NOT DISTINCT FROM r.subcontractor_id
  WHERE r.status = 'Pending'
    AND NOT r.on_invoice
)
UPDATE public.jobs j
SET deleted_at = now()
FROM victims v
WHERE j.id = v.id
  AND j.deleted_at IS NULL
  AND j.status = 'Pending'
  AND NOT EXISTS (
    SELECT 1 FROM public.invoice_items ii WHERE ii.job_id = j.id
  )
RETURNING j.id, j.job_number, j.address, j.scheduled_date, j.status, j.payment_status, j.deleted_at;

-- Check: no active Pending copy remains in those groups unless it is on an
-- invoice line. The Completed/Paid job for each date is still active.
WITH richmond AS (
  SELECT
    j.id,
    j.job_number,
    j.status,
    j.payment_status,
    j.scheduled_date,
    j.address,
    j.deleted_at,
    j.subcontractor_id,
    lower(trim(regexp_replace(regexp_replace(coalesce(j.address, ''), '[.,]+', '', 'g'), '\s+', ' ', 'g'))) AS addr_key,
    EXISTS (
      SELECT 1 FROM public.invoice_items ii WHERE ii.job_id = j.id
    ) AS on_invoice
  FROM public.jobs j
  JOIN public.customers c ON c.id = j.customer_id
  WHERE c.name ILIKE '%john%richmond%'
    AND j.scheduled_date >= DATE '2026-08-01'
    AND j.scheduled_date < DATE '2026-09-01'
),
groups AS (
  SELECT addr_key, subcontractor_id, scheduled_date
  FROM richmond
  WHERE addr_key <> ''
  GROUP BY addr_key, subcontractor_id, scheduled_date
  HAVING count(*) FILTER (
           WHERE status = 'Completed' AND payment_status = 'Paid' AND deleted_at IS NULL
         ) >= 1
     AND count(*) FILTER (WHERE status = 'Pending') >= 1
)
SELECT
  r.scheduled_date,
  r.address,
  r.job_number,
  r.status,
  r.payment_status,
  r.on_invoice,
  r.deleted_at
FROM richmond r
JOIN groups g
  ON g.addr_key = r.addr_key
 AND g.scheduled_date = r.scheduled_date
 AND g.subcontractor_id IS NOT DISTINCT FROM r.subcontractor_id
ORDER BY r.scheduled_date, r.deleted_at NULLS FIRST, r.status, r.job_number;
