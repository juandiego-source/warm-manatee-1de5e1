-- Sumak Ops — subcontractor access lock
-- Project: nrnnpprcshkgroghhbro
--
-- Paste this WHOLE file into the Supabase SQL Editor and run it once.
-- Safe to run again.
--
-- It does not email, text, or invite anyone.
-- It does not insert, update, or delete any job, customer, invoice,
-- estimate, payout, or photo row.
-- It does drop and recreate public.sub_jobs and public.sub_cost_requests.
-- Those views hold no rows. CREATE OR REPLACE cannot change their column
-- order (production error 42P16), so they are dropped first.
-- The one data change is storage: the job-photos bucket is marked private
-- so an old public link no longer opens a photo. Deploy the website in
-- the same change so the app loads photos with a signed link.
-- Do not ALTER storage.objects. The SQL editor runs as postgres, and that
-- table is owned by supabase_storage_admin (42501). Row level security
-- is already on. postgres can still update storage.buckets and create
-- or drop policies on storage.objects.
--
-- After this file:
--   An admin still uses the jobs table (and the rest of the office tables).
--   A subcontractor reads public.sub_jobs, which has their own visits and
--   their own sub pay, and does not have client price or margin columns.
--   A subcontractor writes through the functions below. They cannot update
--   the jobs table directly, so PostgREST cannot return client_price.
--   Signup from an invite link fills profiles.subcontractor_id when that
--   subcontractor exists and nobody else is already linked.
--
-- This replaces protect_job_admin_fields() completely. It keeps the
-- postgres / service_role bypass and the sub status rules from
-- sql/2026-10-12-sub-status.sql. Do not run that older file afterwards.
--
-- Requires the existing public.is_admin() and auth.uid(). It does not
-- replace either one, and it does not replace the quote functions.

-- =============================================================================
-- 1. Who the signed-in sub is
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

-- =============================================================================
-- 2. Freeze office fields if a sub ever gets a direct update again
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
  sub_id uuid;
  owns boolean;
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
  NEW.payment_method := OLD.payment_method;
  NEW.paid_at := OLD.paid_at;
  NEW.deleted_at := OLD.deleted_at;
  NEW.subcontractor_id := OLD.subcontractor_id;
  NEW.customer_id := OLD.customer_id;
  NEW.estimate_id := OLD.estimate_id;
  NEW.job_number := OLD.job_number;
  NEW.title := OLD.title;
  NEW.description := OLD.description;
  NEW.address := OLD.address;
  NEW.scheduled_date := OLD.scheduled_date;
  NEW.notes := OLD.notes;
  NEW.recurring_service_id := OLD.recurring_service_id;
  NEW.created_at := OLD.created_at;

  sub_id := public.current_subcontractor_id();
  owns :=
    sub_id IS NOT NULL
    AND OLD.subcontractor_id IS NOT NULL
    AND OLD.subcontractor_id = sub_id
    AND OLD.deleted_at IS NULL;

  allowed_transition :=
    owns
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
    ELSIF owns
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

  IF NEW.accepted_at IS DISTINCT FROM OLD.accepted_at THEN
    IF NOT (owns AND OLD.accepted_at IS NULL AND NEW.accepted_at IS NOT NULL) THEN
      NEW.accepted_at := OLD.accepted_at;
    END IF;
  END IF;

  IF NEW.site_report IS DISTINCT FROM OLD.site_report AND NOT owns THEN
    NEW.site_report := OLD.site_report;
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS protect_job_admin_fields_trigger ON public.jobs;

CREATE TRIGGER protect_job_admin_fields_trigger
  BEFORE UPDATE ON public.jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_job_admin_fields();

-- =============================================================================
-- 3. Invite link → profile.subcontractor_id, only when it is still free
-- =============================================================================

CREATE OR REPLACE FUNCTION public.subcontractor_id_from_invite(p_uid uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  raw text;
  sub_id uuid;
BEGIN
  IF p_uid IS NULL THEN
    RETURN NULL;
  END IF;

  -- A signed-in user can only resolve their own invite. The signup trigger
  -- runs as postgres or service_role and may resolve the new row's id.
  IF p_uid IS DISTINCT FROM auth.uid()
     AND current_user NOT IN ('postgres', 'service_role')
     AND COALESCE(nullif(current_setting('role', true), 'none'), '') NOT IN ('postgres', 'service_role')
  THEN
    RETURN NULL;
  END IF;

  SELECT u.raw_user_meta_data->>'invited_sub_id'
    INTO raw
  FROM auth.users u
  WHERE u.id = p_uid;

  IF raw IS NULL OR btrim(raw) = '' THEN
    RETURN NULL;
  END IF;

  BEGIN
    sub_id := btrim(raw)::uuid;
  EXCEPTION WHEN others THEN
    RETURN NULL;
  END;

  IF NOT EXISTS (SELECT 1 FROM public.subcontractors s WHERE s.id = sub_id) THEN
    RETURN NULL;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.subcontractor_id = sub_id
      AND p.id IS DISTINCT FROM p_uid
  ) THEN
    RETURN NULL;
  END IF;

  RETURN sub_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.subcontractor_id_from_invite(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subcontractor_id_from_invite(uuid) TO authenticated;

-- Invoker, not definer: current_user must be the account that is inserting
-- the profile. A definer function would always look like postgres and would
-- trust a subcontractor id the browser sent.
CREATE OR REPLACE FUNCTION public.link_invited_subcontractor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $fn$
DECLARE
  actor text := current_user;
  active_role text := nullif(current_setting('role', true), 'none');
  bypass boolean;
  linked uuid;
BEGIN
  bypass :=
    public.is_admin()
    OR actor IN ('postgres', 'service_role')
    OR active_role IN ('postgres', 'service_role');

  IF COALESCE(NEW.role, '') = 'admin' THEN
    RETURN NEW;
  END IF;

  IF NOT bypass THEN
    NEW.role := CASE
      WHEN COALESCE(btrim(NEW.role), '') = '' THEN 'sub'
      ELSE NEW.role
    END;
    NEW.subcontractor_id := NULL;
  END IF;

  IF NEW.subcontractor_id IS NULL THEN
    linked := public.subcontractor_id_from_invite(NEW.id);
    IF linked IS NOT NULL THEN
      NEW.subcontractor_id := linked;
      IF NEW.role IS NULL OR btrim(NEW.role) = '' THEN
        NEW.role := 'sub';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS link_invited_subcontractor ON public.profiles;

CREATE TRIGGER link_invited_subcontractor
  BEFORE INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.link_invited_subcontractor();

CREATE OR REPLACE FUNCTION public.protect_profile_privileges()
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

  NEW.role := OLD.role;
  NEW.subcontractor_id := OLD.subcontractor_id;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS protect_profile_privileges ON public.profiles;

CREATE TRIGGER protect_profile_privileges
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_profile_privileges();

CREATE OR REPLACE FUNCTION public.claim_subcontractor_invite()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  uid uuid := auth.uid();
  current_role text;
  current_sub uuid;
  linked uuid;
BEGIN
  IF uid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT p.role, p.subcontractor_id
    INTO current_role, current_sub
  FROM public.profiles p
  WHERE p.id = uid;

  IF NOT FOUND OR COALESCE(current_role, '') = 'admin' OR current_sub IS NOT NULL THEN
    RETURN current_sub;
  END IF;

  linked := public.subcontractor_id_from_invite(uid);
  IF linked IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.profiles
  SET subcontractor_id = linked,
      role = CASE
        WHEN role IS NULL OR btrim(role) = '' THEN 'sub'
        ELSE role
      END
  WHERE id = uid
    AND subcontractor_id IS NULL
    AND COALESCE(role, '') <> 'admin';

  RETURN linked;
END;
$fn$;

REVOKE ALL ON FUNCTION public.claim_subcontractor_invite() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_subcontractor_invite() TO authenticated;

-- =============================================================================
-- 4. What a sub can see, and the only writes they can make
-- =============================================================================

CREATE OR REPLACE FUNCTION public.job_assigned_to_me(p_job_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT EXISTS (
    SELECT 1
    FROM public.jobs j
    WHERE j.id = p_job_id
      AND j.deleted_at IS NULL
      AND j.subcontractor_id = public.current_subcontractor_id()
  );
$fn$;

REVOKE ALL ON FUNCTION public.job_assigned_to_me(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.job_assigned_to_me(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.storage_job_id(p_name text)
RETURNS uuid
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $fn$
DECLARE
  head text := split_part(COALESCE(p_name, ''), '/', 1);
BEGIN
  IF head ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN head::uuid;
  END IF;
  RETURN NULL;
END;
$fn$;

REVOKE ALL ON FUNCTION public.storage_job_id(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.storage_job_id(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.sub_accept_job(p_job_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_accepted timestamptz;
BEGIN
  UPDATE public.jobs j
  SET accepted_at = COALESCE(j.accepted_at, now())
  WHERE j.id = p_job_id
    AND j.deleted_at IS NULL
    AND j.subcontractor_id = public.current_subcontractor_id()
  RETURNING j.accepted_at INTO v_accepted;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Job not found';
  END IF;

  RETURN jsonb_build_object('accepted_at', v_accepted);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.sub_set_job_status(p_job_id uuid, p_status text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_status text;
  v_completed timestamptz;
BEGIN
  UPDATE public.jobs j
  SET status = p_status,
      completed_at = CASE
        WHEN p_status = 'Completed' AND j.completed_at IS NULL THEN now()
        ELSE j.completed_at
      END
  WHERE j.id = p_job_id
    AND j.deleted_at IS NULL
    AND j.subcontractor_id = public.current_subcontractor_id()
    AND (
      (j.status IN ('Pending', 'Scheduled') AND p_status IN ('In Progress', 'Completed'))
      OR (j.status = 'In Progress' AND p_status = 'Completed')
    )
  RETURNING j.status, j.completed_at INTO v_status, v_completed;

  IF FOUND THEN
    RETURN jsonb_build_object('status', v_status, 'completed_at', v_completed);
  END IF;

  SELECT j.status, j.completed_at
    INTO v_status, v_completed
  FROM public.jobs j
  WHERE j.id = p_job_id
    AND j.deleted_at IS NULL
    AND j.subcontractor_id = public.current_subcontractor_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Job not found';
  END IF;

  RETURN jsonb_build_object('status', v_status, 'completed_at', v_completed);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.sub_save_site_report(p_job_id uuid, p_report jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_notes text;
  v_report jsonb;
BEGIN
  IF p_report IS NULL OR octet_length(p_report::text) > 8000 THEN
    RAISE EXCEPTION 'Report is too large';
  END IF;

  v_notes := left(COALESCE(p_report->>'notes', ''), 2000);
  v_report := jsonb_build_object(
    'items', CASE
      WHEN jsonb_typeof(p_report->'items') = 'object' THEN p_report->'items'
      ELSE '{}'::jsonb
    END,
    'notes', v_notes,
    'submitted_at', to_jsonb(now())
  );

  UPDATE public.jobs j
  SET site_report = v_report
  WHERE j.id = p_job_id
    AND j.deleted_at IS NULL
    AND j.subcontractor_id = public.current_subcontractor_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Job not found';
  END IF;

  RETURN v_report;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.sub_submit_cost(p_id uuid, p_cost numeric, p_notes text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_cost numeric;
  v_notes text;
  v_at timestamptz;
BEGIN
  IF p_cost IS NULL OR p_cost <= 0 OR p_cost > 1000000 THEN
    RAISE EXCEPTION 'Enter a cost';
  END IF;

  UPDATE public.cost_requests c
  SET status = 'Submitted',
      submitted_cost = round(p_cost, 2),
      submitted_notes = NULLIF(left(btrim(COALESCE(p_notes, '')), 2000), ''),
      submitted_at = now()
  WHERE c.id = p_id
    AND c.subcontractor_id = public.current_subcontractor_id()
    AND c.status = 'Requested'
  RETURNING c.submitted_cost, c.submitted_notes, c.submitted_at
    INTO v_cost, v_notes, v_at;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Quote request not found';
  END IF;

  RETURN jsonb_build_object(
    'status', 'Submitted',
    'submitted_cost', v_cost,
    'submitted_notes', v_notes,
    'submitted_at', v_at
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.sub_accept_job(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sub_set_job_status(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sub_save_site_report(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sub_submit_cost(uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sub_accept_job(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sub_set_job_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sub_save_site_report(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sub_submit_cost(uuid, numeric, text) TO authenticated;

-- No client_price, margin, invoice total, or other office columns.
-- security_invoker false: the view owner reads the jobs table, then the
-- WHERE clause keeps only this sub's rows. A direct select on jobs is
-- still empty for a sub because of the policies below.
--
-- Drop first. CREATE OR REPLACE cannot rename or reorder columns.
-- Production already has sub_jobs with customer_id where this view has
-- address (42P16). Nothing else in this project depends on these views:
-- no view, function, or policy reads them. The app selects them only
-- after this script recreates them. No CASCADE, so an unexpected
-- dependent stops the script instead of being deleted with the view.
DROP VIEW IF EXISTS public.sub_jobs;
DROP VIEW IF EXISTS public.sub_cost_requests;

CREATE OR REPLACE VIEW public.sub_jobs
WITH (security_barrier = true, security_invoker = false) AS
SELECT
  j.id,
  j.job_number,
  j.title,
  j.description,
  j.address,
  j.scheduled_date,
  j.status,
  j.completed_at,
  j.accepted_at,
  j.notes,
  j.site_report,
  j.subcontractor_id,
  j.customer_id,
  j.recurring_service_id,
  j.sub_pay,
  j.payment_status,
  j.payment_method,
  j.paid_at,
  j.created_at,
  c.name AS customer_name,
  s.name AS subcontractor_name
FROM public.jobs j
LEFT JOIN public.customers c ON c.id = j.customer_id
LEFT JOIN public.subcontractors s ON s.id = j.subcontractor_id
WHERE j.deleted_at IS NULL
  AND j.subcontractor_id IS NOT NULL
  AND j.subcontractor_id = public.current_subcontractor_id();

ALTER VIEW public.sub_jobs SET (security_barrier = true, security_invoker = false);
ALTER VIEW public.sub_jobs OWNER TO postgres;

REVOKE ALL ON TABLE public.sub_jobs FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.sub_jobs TO authenticated;

-- Drop again in case this section is run on its own. Do not drop
-- sub_jobs here: the statements above just created it.
DROP VIEW IF EXISTS public.sub_cost_requests;

CREATE OR REPLACE VIEW public.sub_cost_requests
WITH (security_barrier = true, security_invoker = false) AS
SELECT
  c.id,
  c.title,
  c.description,
  c.address,
  c.status,
  c.subcontractor_id,
  c.submitted_cost,
  c.submitted_notes,
  c.submitted_at,
  c.created_at,
  cust.name AS customer_name
FROM public.cost_requests c
LEFT JOIN public.customers cust ON cust.id = c.customer_id
WHERE c.subcontractor_id IS NOT NULL
  AND c.subcontractor_id = public.current_subcontractor_id();

ALTER VIEW public.sub_cost_requests SET (security_barrier = true, security_invoker = false);
ALTER VIEW public.sub_cost_requests OWNER TO postgres;

REVOKE ALL ON TABLE public.sub_cost_requests FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.sub_cost_requests TO authenticated;

-- =============================================================================
-- 5. Office tables: admin only. Subs get no row, not a hidden column.
-- =============================================================================

DO $policies$
DECLARE
  t text;
  r record;
  office text[] := ARRAY[
    'jobs',
    'customers',
    'properties',
    'estimates',
    'estimate_items',
    'invoices',
    'invoice_items',
    'recurring_services',
    'services',
    'sub_payments',
    'sub_payment_jobs',
    'cost_requests'
  ];
BEGIN
  FOREACH t IN ARRAY office LOOP
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon', t);
    EXECUTE format(
      'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO authenticated',
      t
    );
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    FOR r IN
      SELECT policyname
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = t
    LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, t);
    END LOOP;
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_admin_all', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin())',
      t || '_admin_all',
      t
    );
  END LOOP;
END
$policies$;

-- Subcontractors: a sub can read their own name. Nothing else.
REVOKE ALL ON TABLE public.subcontractors FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.subcontractors TO authenticated;
ALTER TABLE public.subcontractors ENABLE ROW LEVEL SECURITY;

DO $drop_subs$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'subcontractors'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.subcontractors', r.policyname);
  END LOOP;
END
$drop_subs$;

DROP POLICY IF EXISTS subcontractors_admin_all ON public.subcontractors;
CREATE POLICY subcontractors_admin_all
  ON public.subcontractors
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS subcontractors_select_own ON public.subcontractors;
CREATE POLICY subcontractors_select_own
  ON public.subcontractors
  FOR SELECT
  TO authenticated
  USING (id = public.current_subcontractor_id());

-- Profiles: own row, or every row for an admin. A sub cannot change role
-- or subcontractor_id (protect_profile_privileges). Signup insert of the
-- caller's own row is allowed; the invite trigger decides the link.
REVOKE ALL ON TABLE public.profiles FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.profiles TO authenticated;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DO $drop_profiles$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'profiles'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.profiles', r.policyname);
  END LOOP;
END
$drop_profiles$;

DROP POLICY IF EXISTS profiles_admin_all ON public.profiles;
CREATE POLICY profiles_admin_all
  ON public.profiles
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS profiles_select_own ON public.profiles;
CREATE POLICY profiles_select_own
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING (id = auth.uid());

DROP POLICY IF EXISTS profiles_insert_own ON public.profiles;
CREATE POLICY profiles_insert_own
  ON public.profiles
  FOR INSERT
  TO authenticated
  WITH CHECK (id = auth.uid() AND COALESCE(role, '') <> 'admin');

-- Notifications: admin sees the office inbox. A sub sees only their own.
REVOKE ALL ON TABLE public.notifications FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.notifications TO authenticated;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

DO $drop_notifs$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'notifications'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.notifications', r.policyname);
  END LOOP;
END
$drop_notifs$;

DROP POLICY IF EXISTS notifications_admin_all ON public.notifications;
CREATE POLICY notifications_admin_all
  ON public.notifications
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS notifications_select_own ON public.notifications;
CREATE POLICY notifications_select_own
  ON public.notifications
  FOR SELECT
  TO authenticated
  USING (
    recipient_role = 'sub'
    AND recipient_sub_id = public.current_subcontractor_id()
  );

DROP POLICY IF EXISTS notifications_update_own ON public.notifications;
CREATE POLICY notifications_update_own
  ON public.notifications
  FOR UPDATE
  TO authenticated
  USING (
    recipient_role = 'sub'
    AND recipient_sub_id = public.current_subcontractor_id()
  )
  WITH CHECK (
    recipient_role = 'sub'
    AND recipient_sub_id = public.current_subcontractor_id()
  );

DROP POLICY IF EXISTS notifications_insert_sub ON public.notifications;
CREATE POLICY notifications_insert_sub
  ON public.notifications
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.current_subcontractor_id() IS NOT NULL
    AND (
      (recipient_role = 'admin' AND recipient_sub_id IS NULL)
      OR (
        recipient_role = 'sub'
        AND recipient_sub_id = public.current_subcontractor_id()
      )
    )
  );

-- Activity log: a sub may add a line and cannot read the office log.
REVOKE ALL ON TABLE public.activity_log FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.activity_log TO authenticated;
ALTER TABLE public.activity_log ENABLE ROW LEVEL SECURITY;

DO $drop_activity$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'activity_log'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.activity_log', r.policyname);
  END LOOP;
END
$drop_activity$;

DROP POLICY IF EXISTS activity_log_admin_all ON public.activity_log;
CREATE POLICY activity_log_admin_all
  ON public.activity_log
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS activity_log_insert_sub ON public.activity_log;
CREATE POLICY activity_log_insert_sub
  ON public.activity_log
  FOR INSERT
  TO authenticated
  WITH CHECK (public.current_subcontractor_id() IS NOT NULL);

-- Push subscriptions: a user can store only their own device.
REVOKE ALL ON TABLE public.push_subscriptions FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.push_subscriptions TO authenticated;
ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;

DO $drop_push$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'push_subscriptions'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.push_subscriptions', r.policyname);
  END LOOP;
END
$drop_push$;

DROP POLICY IF EXISTS push_subscriptions_admin_all ON public.push_subscriptions;
CREATE POLICY push_subscriptions_admin_all
  ON public.push_subscriptions
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS push_subscriptions_own ON public.push_subscriptions;
CREATE POLICY push_subscriptions_own
  ON public.push_subscriptions
  FOR ALL
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Job photo rows: only the assigned sub, or an admin.
REVOKE ALL ON TABLE public.job_photos FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.job_photos TO authenticated;
ALTER TABLE public.job_photos ENABLE ROW LEVEL SECURITY;

DO $drop_photos$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'job_photos'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.job_photos', r.policyname);
  END LOOP;
END
$drop_photos$;

DROP POLICY IF EXISTS job_photos_admin_all ON public.job_photos;
CREATE POLICY job_photos_admin_all
  ON public.job_photos
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS job_photos_assigned ON public.job_photos;
CREATE POLICY job_photos_assigned
  ON public.job_photos
  FOR ALL
  TO authenticated
  USING (public.job_assigned_to_me(job_id))
  WITH CHECK (public.job_assigned_to_me(job_id));

-- =============================================================================
-- 6. job-photos bucket: private, and only the assigned sub or an admin
-- =============================================================================

DO $bucket$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'storage'
      AND table_name = 'buckets'
      AND column_name = 'name'
  ) THEN
    UPDATE storage.buckets
    SET public = false
    WHERE id = 'job-photos' OR name = 'job-photos';
  ELSE
    UPDATE storage.buckets
    SET public = false
    WHERE id = 'job-photos';
  END IF;
END
$bucket$;

-- storage.objects already has row level security on hosted Supabase.
-- ALTER TABLE storage.objects is not allowed for postgres (42501:
-- must be owner of table objects). Policies below are allowed.

DO $drop_storage$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND (
        policyname ILIKE '%job_photo%'
        OR policyname ILIKE '%job-photo%'
        OR COALESCE(qual, '') ILIKE '%job-photos%'
        OR COALESCE(with_check, '') ILIKE '%job-photos%'
      )
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', r.policyname);
  END LOOP;
END
$drop_storage$;

DROP POLICY IF EXISTS job_photos_object_assigned ON storage.objects;
CREATE POLICY job_photos_object_assigned
  ON storage.objects
  FOR ALL
  TO authenticated
  USING (
    bucket_id = 'job-photos'
    AND (
      public.is_admin()
      OR public.job_assigned_to_me(public.storage_job_id(name))
    )
  )
  WITH CHECK (
    bucket_id = 'job-photos'
    AND (
      public.is_admin()
      OR public.job_assigned_to_me(public.storage_job_id(name))
    )
  );

-- Check: sub_jobs has no price column, the bucket is private, and the
-- office tables are admin-only.
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'sub_jobs'
ORDER BY ordinal_position;

SELECT id, public AS is_public
FROM storage.buckets
WHERE id = 'job-photos';

SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'jobs', 'customers', 'invoices', 'invoice_items', 'estimates',
    'sub_payments', 'job_photos', 'profiles', 'subcontractors'
  )
ORDER BY tablename, policyname;
