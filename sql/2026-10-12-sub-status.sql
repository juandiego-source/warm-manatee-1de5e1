-- Sumak Ops — let an assigned sub start and complete their own job
-- Project: nrnnpprcshkgroghhbro
--
-- Run ONE block at a time. Do not run this file as a single script.
-- Block 2 rolls back. If you run it in the same transaction as Block 1,
-- that rollback also undoes the function change. Commit Block 1 first.
--
-- This replaces protect_job_admin_fields() completely. It includes the
-- postgres / service_role bypass, so it is the right function whether or
-- not the earlier Block 6 has already been run. Running that older Block 6
-- after this one would remove the sub status allowance. Run this again if that happens.
--
-- Nothing here emails, texts, or notifies a client or a sub.
-- sub_pay, client_price, payment_status, and deleted_at stay protected for subs.
-- A sub may change status only on a job assigned to them, and only:
--   Pending or Scheduled -> In Progress
--   Pending or Scheduled -> Completed
--   In Progress -> Completed
-- completed_at may be set when that move is to Completed, or on a follow-up
-- write once the job is already Completed and completed_at is still empty.
-- Any other completed_at change is put back.

-- =============================================================================
-- BLOCK 1 — Replace the trigger function and reattach it
-- =============================================================================

CREATE OR REPLACE FUNCTION public.current_subcontractor_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT p.subcontractor_id
  FROM public.profiles p
  WHERE p.id = auth.uid()
    AND p.subcontractor_id IS NOT NULL
    AND COALESCE(p.role, '') <> 'admin'
  LIMIT 1;
$fn$;

REVOKE ALL ON FUNCTION public.current_subcontractor_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_subcontractor_id() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.protect_job_admin_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $fn$
DECLARE
  actor text := current_user;
  active_role text := nullif(current_setting('role', true), 'none');
  sub_id uuid;
  allowed_transition boolean := false;
BEGIN
  -- SQL editor (postgres) and the service key. Do not use session_user:
  -- SET ROLE authenticated leaves session_user as postgres.
  -- Do not treat a missing auth.uid() as trusted: anon has no uid either.
  IF public.is_admin()
     OR actor IN ('postgres', 'service_role')
     OR active_role IN ('postgres', 'service_role')
  THEN
    RETURN NEW;
  END IF;

  NEW.sub_pay := OLD.sub_pay;
  NEW.client_price := OLD.client_price;
  NEW.payment_status := OLD.payment_status;
  NEW.deleted_at := OLD.deleted_at;
  -- Assignment is part of the status rule. A sub who could rewrite
  -- subcontractor_id could claim another job and then complete it.
  NEW.subcontractor_id := OLD.subcontractor_id;

  sub_id := public.current_subcontractor_id();

  allowed_transition :=
    sub_id IS NOT NULL
    AND OLD.subcontractor_id IS NOT NULL
    AND OLD.subcontractor_id = sub_id
    AND (
      (OLD.status IN ('Pending', 'Scheduled') AND NEW.status IN ('In Progress', 'Completed'))
      OR (OLD.status = 'In Progress' AND NEW.status = 'Completed')
    );

  IF NEW.status IS DISTINCT FROM OLD.status AND NOT allowed_transition THEN
    NEW.status := OLD.status;
  END IF;

  IF NEW.completed_at IS DISTINCT FROM OLD.completed_at THEN
    IF allowed_transition AND NEW.status = 'Completed' AND NEW.status IS DISTINCT FROM OLD.status THEN
      NULL;
    ELSIF sub_id IS NOT NULL
      AND OLD.subcontractor_id = sub_id
      AND OLD.status = 'Completed'
      AND NEW.status = 'Completed'
      AND OLD.completed_at IS NULL
      AND NEW.completed_at IS NOT NULL
    THEN
      NULL;
    ELSE
      NEW.completed_at := OLD.completed_at;
    END IF;
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS protect_job_admin_fields_trigger ON public.jobs;

CREATE TRIGGER protect_job_admin_fields_trigger
  BEFORE UPDATE ON public.jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_job_admin_fields();

-- Check: protect_job_admin_fields is invoker with search_path=public.
-- current_subcontractor_id is definer with search_path=public.
-- The trigger is BEFORE UPDATE on jobs.
SELECT
  p.proname,
  p.prosecdef AS security_definer,
  p.proconfig
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('protect_job_admin_fields', 'current_subcontractor_id')
ORDER BY p.proname;

SELECT tgname, pg_get_triggerdef(t.oid) AS trigger_def
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'jobs'
  AND NOT t.tgisinternal
  AND tgname = 'protect_job_admin_fields_trigger';


-- =============================================================================
-- BLOCK 2 — Simulated sub, then ROLLBACK
-- Own assigned job: the next allowed status sticks.
-- Same job: client_price, sub_pay, payment_status, and deleted_at do not.
-- Someone else's job: the status change does not stick.
-- completed_at sticks only when the move is to Completed.
-- Nothing is saved.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE probe_jobs (
  kind text PRIMARY KEY,
  job_id uuid,
  sub_uid uuid,
  status text,
  next_status text,
  client_price numeric,
  sub_pay numeric,
  payment_status text,
  deleted_at timestamptz,
  completed_at timestamptz,
  subcontractor_id uuid
) ON COMMIT DROP;

DO $probe$
DECLARE
  r record;
  other_id uuid;
  other_status text;
  own_next text;
  other_next text;
BEGIN
  SELECT
    p.id AS uid,
    p.subcontractor_id,
    j.id AS job_id,
    j.status,
    j.client_price,
    j.sub_pay,
    j.payment_status,
    j.deleted_at,
    j.completed_at,
    j.subcontractor_id AS sub_id
  INTO r
  FROM public.profiles p
  JOIN public.jobs j
    ON j.subcontractor_id = p.subcontractor_id
   AND j.deleted_at IS NULL
  WHERE COALESCE(p.role, '') <> 'admin'
    AND p.subcontractor_id IS NOT NULL
    AND j.status IN ('Pending', 'Scheduled', 'In Progress')
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No assigned Pending, Scheduled, or In Progress job for a sub. Nothing was changed.';
  END IF;

  SELECT j.id, j.status
    INTO other_id, other_status
  FROM public.jobs j
  WHERE j.deleted_at IS NULL
    AND j.id <> r.job_id
    AND j.subcontractor_id IS DISTINCT FROM r.subcontractor_id
    AND j.status IN ('Pending', 'Scheduled', 'In Progress')
  LIMIT 1;

  IF other_id IS NULL THEN
    RAISE EXCEPTION 'No second job assigned to someone else. Nothing was changed.';
  END IF;

  own_next := CASE WHEN r.status = 'In Progress' THEN 'Completed' ELSE 'In Progress' END;
  other_next := CASE WHEN other_status = 'In Progress' THEN 'Completed' ELSE 'In Progress' END;

  INSERT INTO probe_jobs
  VALUES (
    'own', r.job_id, r.uid, r.status, own_next,
    r.client_price, r.sub_pay, r.payment_status, r.deleted_at, r.completed_at, r.sub_id
  );
  INSERT INTO probe_jobs (kind, job_id, status, next_status, subcontractor_id)
  VALUES ('other', other_id, other_status, other_next, (
    SELECT j.subcontractor_id FROM public.jobs j WHERE j.id = other_id
  ));

  PERFORM set_config('app.probe_uid', r.uid::text, true);
  PERFORM set_config('app.probe_own_job', r.job_id::text, true);
  PERFORM set_config('app.probe_own_next', own_next, true);
  PERFORM set_config('app.probe_other_job', other_id::text, true);
  PERFORM set_config('app.probe_other_next', other_next, true);
  PERFORM set_config('app.probe_own_sub', r.sub_id::text, true);
END;
$probe$;

SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', current_setting('app.probe_uid'), 'role', 'authenticated')::text,
  true
);
SELECT set_config('request.jwt.claim.sub', current_setting('app.probe_uid'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SET LOCAL ROLE authenticated;

UPDATE public.jobs
SET status = current_setting('app.probe_own_next')
WHERE id = current_setting('app.probe_own_job')::uuid;

UPDATE public.jobs
SET completed_at = timestamptz '2026-10-12 18:00:00+00'
WHERE id = current_setting('app.probe_own_job')::uuid
  AND status = 'Completed';

UPDATE public.jobs
SET
  client_price = round(COALESCE(client_price, 0)::numeric + 80, 2),
  sub_pay = round(COALESCE(sub_pay, 0)::numeric + 80, 2),
  payment_status = CASE WHEN payment_status = 'Paid' THEN 'Unpaid' ELSE 'Paid' END,
  deleted_at = timestamptz '2026-10-12 18:05:00+00',
  notes = CASE
    WHEN notes LIKE '%[sub-status-probe]%' THEN notes
    ELSE concat_ws(' ', notes, '[sub-status-probe]')
  END
WHERE id = current_setting('app.probe_own_job')::uuid;

UPDATE public.jobs
SET
  status = current_setting('app.probe_other_next'),
  subcontractor_id = current_setting('app.probe_own_sub')::uuid
WHERE id = current_setting('app.probe_other_job')::uuid;

RESET ROLE;

-- Check this result, then the rollback finishes.
-- Expect own_status_ok, price_blocked, pay_blocked, payment_blocked,
-- deleted_blocked, price_update_reached_row, completed_at_ok,
-- other_status_blocked, and other_assignment_blocked all true.
SELECT
  own_job.status = own_before.next_status AS own_status_ok,
  own_job.client_price IS NOT DISTINCT FROM own_before.client_price AS price_blocked,
  own_job.sub_pay IS NOT DISTINCT FROM own_before.sub_pay AS pay_blocked,
  own_job.payment_status IS NOT DISTINCT FROM own_before.payment_status AS payment_blocked,
  own_job.deleted_at IS NOT DISTINCT FROM own_before.deleted_at AS deleted_blocked,
  own_job.notes LIKE '%[sub-status-probe]%' AS price_update_reached_row,
  CASE
    WHEN own_before.next_status = 'Completed' THEN own_job.completed_at IS NOT NULL
    ELSE own_job.completed_at IS NOT DISTINCT FROM own_before.completed_at
  END AS completed_at_ok,
  other_job.status = other_before.status AS other_status_blocked,
  other_job.subcontractor_id IS NOT DISTINCT FROM other_before.subcontractor_id AS other_assignment_blocked,
  own_before.status AS own_status_before,
  own_job.status AS own_status_after,
  other_before.status AS other_status_before,
  other_job.status AS other_status_after
FROM probe_jobs own_before
JOIN public.jobs own_job ON own_job.id = own_before.job_id
JOIN probe_jobs other_before ON other_before.kind = 'other'
JOIN public.jobs other_job ON other_job.id = other_before.job_id
WHERE own_before.kind = 'own';

ROLLBACK;
