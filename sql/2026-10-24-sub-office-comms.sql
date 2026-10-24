-- Sumak Ops — sub <-> office messages, and the schedule for reminders.
-- Project: nrnnpprcshkgroghhbro
--
-- Run sql/2026-10-23-sub-access.sql from this pull request first
-- (it drops and recreates the sub views, and it does not ALTER storage.objects).
-- Then paste this file into the Supabase SQL Editor as role postgres.
-- You can also run each PART on its own. Each part is safe to run again.
--
-- This file does not email, push, or change any job, customer, invoice,
-- estimate, payout, or photo row.
-- It does not ALTER storage.objects. Message photos stay in the private
-- job-photos bucket, under the job id, which the existing storage policy
-- already covers. Do not add a policy that changes other buckets.
--
-- After this file:
--   public.job_messages holds one thread per job. There is no price column.
--   An admin can read and post on every job.
--   A sub can read and post only on a job assigned to them.
--   The author is always the signed-in user.
--   Part 3 arms an hourly pg_cron check. It sends only when the clock in
--   America/Boise says 6pm (next-day reminder) or 7pm (daily recap).
--   That follows daylight saving time. On 23 Oct 2026 Boise is still MDT
--   (UTC-6), so 6pm is 00:00 UTC the next day. After 1 Nov 2026 it is MST
--   (UTC-7), so 6pm is 01:00 UTC. The hour is read in America/Boise; the
--   cron expression stays hourly so both offsets work.
--
-- Edge Function, secrets, and Vault are NOT created here. Deploy steps:
--
--   supabase functions deploy job-comms --project-ref nrnnpprcshkgroghhbro --no-verify-jwt
--
--   supabase secrets set \
--     RESEND_API_KEY=... \
--     VAPID_PUBLIC_KEY=... \
--     VAPID_PRIVATE_KEY=... \
--     VAPID_SUBJECT=mailto:office@sumaklawncare.com \
--     CRON_SECRET=...
--
--   Generate a VAPID pair with: npx web-push generate-vapid-keys
--   VAPID_PUBLIC_KEY must match the constant in index.html. If you generate
--   a new pair, update that constant and deploy the website too.
--   RESEND_API_KEY is the key the existing send-email function already uses.
--   From address is Sumak Lawncare <office@sumaklawncare.com>.
--   CRON_SECRET is any long random string (openssl rand -base64 32).
--   Put the same value in Vault once, then re-run is harmless only if you
--   do not create a second secret with the same name:
--
--   select vault.create_secret('<the same CRON_SECRET>', 'cron_secret');
--
--   If Part 3 prints a notice about pg_cron or pg_net, enable both under
--   Database → Extensions and run Part 3 again.

-- =============================================================================
-- PART 1 — job_messages
-- Paste from this banner through the end of PART 1 to run it alone.
-- Requires public.is_admin() and public.job_assigned_to_me(uuid).
-- =============================================================================

DO $need_access$
BEGIN
  IF to_regprocedure('public.is_admin()') IS NULL
     OR to_regprocedure('public.job_assigned_to_me(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Run sql/2026-10-23-sub-access.sql first.';
  END IF;
END
$need_access$;

CREATE TABLE IF NOT EXISTS public.job_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  author_id uuid NOT NULL,
  body text,
  photo_path text,
  created_at timestamptz NOT NULL DEFAULT now()
);

DO $job_messages_checks$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'job_messages_has_content'
      AND conrelid = 'public.job_messages'::regclass
  ) THEN
    ALTER TABLE public.job_messages
      ADD CONSTRAINT job_messages_has_content
      CHECK (
        (body IS NOT NULL AND length(btrim(body)) > 0)
        OR (photo_path IS NOT NULL AND length(btrim(photo_path)) > 0)
      );
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'job_messages_body_len'
      AND conrelid = 'public.job_messages'::regclass
  ) THEN
    ALTER TABLE public.job_messages
      ADD CONSTRAINT job_messages_body_len
      CHECK (body IS NULL OR length(body) <= 4000);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'job_messages_photo_path'
      AND conrelid = 'public.job_messages'::regclass
  ) THEN
    ALTER TABLE public.job_messages
      ADD CONSTRAINT job_messages_photo_path
      CHECK (
        photo_path IS NULL
        OR (
          photo_path !~ '\.\.'
          AND photo_path !~ '^/'
          AND split_part(photo_path, '/', 1) = job_id::text
        )
      );
  END IF;
END
$job_messages_checks$;

CREATE INDEX IF NOT EXISTS job_messages_job_created_idx
  ON public.job_messages (job_id, created_at);

CREATE OR REPLACE FUNCTION public.job_messages_set_author()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $fn$
BEGIN
  -- A signed-in user cannot post as someone else. The service role and
  -- postgres (no auth.uid()) keep the author they supply. The app inserts
  -- as the signed-in user.
  IF auth.uid() IS NOT NULL THEN
    NEW.author_id := auth.uid();
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS job_messages_set_author ON public.job_messages;
CREATE TRIGGER job_messages_set_author
  BEFORE INSERT ON public.job_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.job_messages_set_author();

REVOKE ALL ON TABLE public.job_messages FROM PUBLIC, anon;
GRANT SELECT, INSERT ON TABLE public.job_messages TO authenticated;
ALTER TABLE public.job_messages ENABLE ROW LEVEL SECURITY;

DO $grant_job_messages_service$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT SELECT, INSERT, DELETE ON TABLE public.job_messages TO service_role;
  END IF;
END
$grant_job_messages_service$;

DO $drop_job_messages$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'job_messages'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.job_messages', r.policyname);
  END LOOP;
END
$drop_job_messages$;

DROP POLICY IF EXISTS job_messages_admin_all ON public.job_messages;
CREATE POLICY job_messages_admin_all
  ON public.job_messages
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin() AND author_id = auth.uid());

DROP POLICY IF EXISTS job_messages_sub_select ON public.job_messages;
CREATE POLICY job_messages_sub_select
  ON public.job_messages
  FOR SELECT
  TO authenticated
  USING (public.job_assigned_to_me(job_id));

DROP POLICY IF EXISTS job_messages_sub_insert ON public.job_messages;
CREATE POLICY job_messages_sub_insert
  ON public.job_messages
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.job_assigned_to_me(job_id)
    AND author_id = auth.uid()
  );

-- Realtime is optional. The job screen also polls. A second run must not
-- fail if the table is already in the publication.
DO $job_messages_realtime$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'job_messages'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.job_messages;
    END IF;
  ELSE
    RAISE NOTICE 'supabase_realtime publication not found. The job screen will poll for messages.';
  END IF;
END
$job_messages_realtime$;

-- End of PART 1.

-- =============================================================================
-- PART 2 — one reminder and one recap per Boise day
-- Paste from this banner through the end of PART 2 to run it alone.
-- The Edge Function writes a row before it sends, so a retry the same
-- evening does not email everyone twice. No job contents are stored here.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.comms_dispatches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL CHECK (action IN ('reminder', 'recap')),
  boise_date date NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (action, boise_date)
);

REVOKE ALL ON TABLE public.comms_dispatches FROM PUBLIC, anon, authenticated;
ALTER TABLE public.comms_dispatches ENABLE ROW LEVEL SECURITY;

DO $grant_comms_service$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT SELECT, INSERT, DELETE ON TABLE public.comms_dispatches TO service_role;
  END IF;
END
$grant_comms_service$;

-- No policy for authenticated. With row level security on and no grant,
-- a signed-in user cannot read or write this table.

-- End of PART 2.

-- =============================================================================
-- PART 3 — 6pm reminder and 7pm recap, America/Boise
-- Paste from this banner through the end of PART 3 to run it alone.
-- Hour 18 is 6pm local. Hour 19 is 7pm local. pg_cron itself is UTC and
-- does not know Boise, so the job runs every hour and returns immediately
-- unless that local hour matches. DST is handled by the America/Boise zone.
-- If pg_cron or pg_net cannot be created, this part prints a notice and
-- still finishes. Enable the extensions, then run Part 3 again.
-- If Vault has no secret named cron_secret, the hourly call skips.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.sumak_dispatch_if_boise_hour(p_hour integer, p_action text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions, vault, pg_temp
AS $fn$
DECLARE
  v_hour integer;
  v_secret text;
  v_url text := 'https://nrnnpprcshkgroghhbro.supabase.co/functions/v1/job-comms';
BEGIN
  IF p_action NOT IN ('reminder', 'recap') THEN
    RAISE EXCEPTION 'unknown comms action';
  END IF;
  IF p_hour IS NULL OR p_hour < 0 OR p_hour > 23 THEN
    RAISE EXCEPTION 'hour must be 0-23';
  END IF;
  v_hour := EXTRACT(HOUR FROM timezone('America/Boise', clock_timestamp()))::integer;
  IF v_hour IS DISTINCT FROM p_hour THEN
    RETURN;
  END IF;
  BEGIN
    EXECUTE 'SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = $1 LIMIT 1'
      INTO v_secret
      USING 'cron_secret';
  EXCEPTION WHEN undefined_table OR invalid_schema_name THEN
    RAISE NOTICE 'vault secret cron_secret is not available; % skipped', p_action;
    RETURN;
  END;
  IF v_secret IS NULL OR btrim(v_secret) = '' THEN
    RAISE NOTICE 'vault secret cron_secret is empty; % skipped', p_action;
    RETURN;
  END IF;
  BEGIN
    EXECUTE
      'SELECT net.http_post(url := $1, body := $2::jsonb, headers := $3::jsonb, timeout_milliseconds := 5000)'
      USING
        v_url,
        jsonb_build_object('action', p_action),
        jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret);
  EXCEPTION WHEN undefined_function OR invalid_schema_name THEN
    RAISE NOTICE 'pg_net is not available; % skipped', p_action;
    RETURN;
  END;
END;
$fn$;

REVOKE ALL ON FUNCTION public.sumak_dispatch_if_boise_hour(integer, text) FROM PUBLIC, anon, authenticated;

DO $schedule_comms$
DECLARE
  v_cron boolean;
  v_net boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') INTO v_cron;
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') INTO v_net;
  IF NOT v_cron OR NOT v_net THEN
    BEGIN
      CREATE EXTENSION IF NOT EXISTS pg_cron;
      CREATE EXTENSION IF NOT EXISTS pg_net;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Part 3 schedule skipped (%). Enable pg_cron and pg_net in Database → Extensions, then run Part 3 again.', SQLERRM;
      RETURN;
    END;
  END IF;
  IF to_regclass('cron.job') IS NULL THEN
    RAISE NOTICE 'Part 3 schedule skipped. cron.job is not visible. Enable pg_cron, then run Part 3 again.';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sumak-next-day-reminder') THEN
    PERFORM cron.unschedule('sumak-next-day-reminder');
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sumak-daily-recap') THEN
    PERFORM cron.unschedule('sumak-daily-recap');
  END IF;
  PERFORM cron.schedule(
    'sumak-next-day-reminder',
    '0 * * * *',
    $cron$SELECT public.sumak_dispatch_if_boise_hour(18, 'reminder')$cron$
  );
  PERFORM cron.schedule(
    'sumak-daily-recap',
    '0 * * * *',
    $cron$SELECT public.sumak_dispatch_if_boise_hour(19, 'recap')$cron$
  );
END
$schedule_comms$;

-- End of PART 3.
