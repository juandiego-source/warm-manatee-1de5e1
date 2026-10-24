-- Sumak Ops — email delivery tracking.
-- Project: nrnnpprcshkgroghhbro
--
-- Paste this file into the Supabase SQL Editor as role postgres.
-- You can also run each PART on its own, in order. Each part is safe to run again.
--
-- This file does not email anyone, and it does not change storage.
-- Subs have no access to public.email_events. The browser cannot insert
-- or update a row. Only the Edge Functions (service role) write them.
--
-- After this file, deploy:
--   supabase functions deploy send-email --project-ref nrnnpprcshkgroghhbro
--   supabase functions deploy resend-webhook --project-ref nrnnpprcshkgroghhbro --no-verify-jwt
-- and set the secret RESEND_WEBHOOK_SECRET. The pull request has the webhook URL.

-- =============================================================================
-- PART 1 — recipient columns
-- Paste from this banner through the end of PART 1 to run it alone.
-- Requires public.is_admin() from sql/2026-10-23-sub-access.sql.
-- =============================================================================

DO $need_access$
BEGIN
  IF to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION 'Run sql/2026-10-23-sub-access.sql first.';
  END IF;
END
$need_access$;

ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS sent_at timestamptz;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS sent_to text;
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS sent_at timestamptz;
ALTER TABLE public.estimates ADD COLUMN IF NOT EXISTS sent_to text;

-- =============================================================================
-- PART 2 — email_events
-- One row per Resend message. Status timestamps stay once they are set.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.email_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resend_id text NOT NULL,
  kind text NOT NULL DEFAULT 'other',
  invoice_id uuid,
  estimate_id uuid,
  job_id uuid,
  to_addresses text[] NOT NULL DEFAULT '{}',
  cc_addresses text[] NOT NULL DEFAULT '{}',
  subject text,
  sent_at timestamptz,
  status text NOT NULL DEFAULT 'sent',
  status_at timestamptz,
  delivered_at timestamptz,
  bounced_at timestamptz,
  bounce_reason text,
  opened_at timestamptz,
  complained_at timestamptz,
  delayed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DO $email_events_constraints$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'email_events_resend_id_key'
      AND conrelid = 'public.email_events'::regclass
  ) THEN
    ALTER TABLE public.email_events
      ADD CONSTRAINT email_events_resend_id_key UNIQUE (resend_id);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'email_events_kind'
      AND conrelid = 'public.email_events'::regclass
  ) THEN
    ALTER TABLE public.email_events
      ADD CONSTRAINT email_events_kind
      CHECK (kind ~ '^[a-z][a-z0-9_]{0,31}$');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'email_events_status'
      AND conrelid = 'public.email_events'::regclass
  ) THEN
    ALTER TABLE public.email_events
      ADD CONSTRAINT email_events_status
      CHECK (status IN ('sent', 'delivery_delayed', 'delivered', 'opened', 'bounced', 'complained'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'email_events_invoice_id_fkey'
      AND conrelid = 'public.email_events'::regclass
  ) THEN
    ALTER TABLE public.email_events
      ADD CONSTRAINT email_events_invoice_id_fkey
      FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'email_events_estimate_id_fkey'
      AND conrelid = 'public.email_events'::regclass
  ) THEN
    ALTER TABLE public.email_events
      ADD CONSTRAINT email_events_estimate_id_fkey
      FOREIGN KEY (estimate_id) REFERENCES public.estimates(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'email_events_job_id_fkey'
      AND conrelid = 'public.email_events'::regclass
  ) THEN
    ALTER TABLE public.email_events
      ADD CONSTRAINT email_events_job_id_fkey
      FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE SET NULL;
  END IF;
END
$email_events_constraints$;

CREATE INDEX IF NOT EXISTS email_events_invoice_idx
  ON public.email_events (invoice_id) WHERE invoice_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS email_events_estimate_idx
  ON public.email_events (estimate_id) WHERE estimate_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS email_events_job_idx
  ON public.email_events (job_id) WHERE job_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS email_events_problem_idx
  ON public.email_events (status_at DESC)
  WHERE status IN ('bounced', 'complained');

-- =============================================================================
-- PART 3 — admin-only read
-- Authenticated users may select. The policy keeps that to admins.
-- There is no insert, update, or delete policy, so the browser cannot write.
-- =============================================================================

REVOKE ALL ON TABLE public.email_events FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.email_events TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.email_events TO service_role;
ALTER TABLE public.email_events ENABLE ROW LEVEL SECURITY;

DO $drop_email_event_policies$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'email_events'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.email_events', r.policyname);
  END LOOP;
END
$drop_email_event_policies$;

CREATE POLICY email_events_admin_select
  ON public.email_events
  FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- =============================================================================
-- PART 4 — record a send, and apply one Resend webhook event
-- service_role only. A later send fills in recipients without wiping status.
-- A repeated webhook does not move a timestamp that is already set.
-- Bounced and complained are terminal. Opened does not clear a bounce.
-- The first bounce or complaint also writes one admin notification.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.record_outgoing_email(
  p_resend_id text,
  p_kind text,
  p_invoice_id uuid,
  p_estimate_id uuid,
  p_job_id uuid,
  p_to text[],
  p_cc text[],
  p_subject text,
  p_sent_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_id uuid;
  v_kind text;
  v_sent text;
  v_sent_at timestamptz;
BEGIN
  IF p_resend_id IS NULL OR btrim(p_resend_id) = '' THEN
    RAISE EXCEPTION 'resend id required';
  END IF;
  IF p_to IS NULL OR cardinality(p_to) = 0 THEN
    RAISE EXCEPTION 'to address required';
  END IF;
  v_kind := lower(btrim(COALESCE(p_kind, 'other')));
  IF v_kind !~ '^[a-z][a-z0-9_]{0,31}$' THEN
    RAISE EXCEPTION 'unknown email kind';
  END IF;
  v_sent_at := COALESCE(p_sent_at, now());
  v_sent := json_build_object(
    'to', to_json(p_to),
    'cc', to_json(COALESCE(p_cc, ARRAY[]::text[])),
    'note', ''
  )::text;

  INSERT INTO public.email_events (
    resend_id, kind, invoice_id, estimate_id, job_id,
    to_addresses, cc_addresses, subject, sent_at, status, status_at
  ) VALUES (
    btrim(p_resend_id), v_kind, p_invoice_id, p_estimate_id, p_job_id,
    p_to, COALESCE(p_cc, ARRAY[]::text[]), NULLIF(btrim(COALESCE(p_subject, '')), ''),
    v_sent_at, 'sent', v_sent_at
  )
  ON CONFLICT (resend_id) DO UPDATE SET
    kind = CASE WHEN public.email_events.kind = 'other' THEN EXCLUDED.kind ELSE public.email_events.kind END,
    invoice_id = COALESCE(public.email_events.invoice_id, EXCLUDED.invoice_id),
    estimate_id = COALESCE(public.email_events.estimate_id, EXCLUDED.estimate_id),
    job_id = COALESCE(public.email_events.job_id, EXCLUDED.job_id),
    to_addresses = CASE
      WHEN cardinality(EXCLUDED.to_addresses) > 0 THEN EXCLUDED.to_addresses
      ELSE public.email_events.to_addresses
    END,
    cc_addresses = CASE
      WHEN cardinality(EXCLUDED.cc_addresses) > 0 THEN EXCLUDED.cc_addresses
      ELSE public.email_events.cc_addresses
    END,
    subject = COALESCE(EXCLUDED.subject, public.email_events.subject),
    sent_at = COALESCE(public.email_events.sent_at, EXCLUDED.sent_at),
    updated_at = now()
  RETURNING id INTO v_id;

  IF p_invoice_id IS NOT NULL THEN
    UPDATE public.invoices
       SET sent_to = v_sent,
           sent_at = v_sent_at
     WHERE id = p_invoice_id;
  END IF;
  IF p_estimate_id IS NOT NULL THEN
    UPDATE public.estimates
       SET sent_to = v_sent,
           sent_at = v_sent_at
     WHERE id = p_estimate_id;
  END IF;
  RETURN v_id;
END
$fn$;

CREATE OR REPLACE FUNCTION public.apply_resend_event(
  p_resend_id text,
  p_type text,
  p_occurred_at timestamptz,
  p_to text[],
  p_subject text,
  p_bounce_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_status text;
  v_row public.email_events%ROWTYPE;
  v_rank int;
  v_cur int;
  v_at timestamptz;
  v_applied boolean := false;
  v_new_bounce boolean := false;
  v_new_complaint boolean := false;
  v_link_type text;
  v_link_id uuid;
  v_message text;
BEGIN
  IF p_resend_id IS NULL OR btrim(p_resend_id) = '' THEN
    RAISE EXCEPTION 'resend id required';
  END IF;
  v_status := CASE p_type
    WHEN 'email.sent' THEN 'sent'
    WHEN 'email.delivered' THEN 'delivered'
    WHEN 'email.bounced' THEN 'bounced'
    WHEN 'email.opened' THEN 'opened'
    WHEN 'email.complained' THEN 'complained'
    WHEN 'email.delivery_delayed' THEN 'delivery_delayed'
    ELSE NULL
  END;
  IF v_status IS NULL THEN
    RETURN jsonb_build_object('ignored', true);
  END IF;
  v_at := COALESCE(p_occurred_at, now());

  INSERT INTO public.email_events (resend_id, kind, to_addresses, subject, status, status_at)
  VALUES (
    btrim(p_resend_id),
    'other',
    COALESCE(p_to, ARRAY[]::text[]),
    NULLIF(btrim(COALESCE(p_subject, '')), ''),
    'sent',
    v_at
  )
  ON CONFLICT (resend_id) DO NOTHING;

  SELECT * INTO v_row
    FROM public.email_events
   WHERE resend_id = btrim(p_resend_id)
   FOR UPDATE;

  IF p_subject IS NOT NULL AND btrim(p_subject) <> '' AND (v_row.subject IS NULL OR btrim(v_row.subject) = '') THEN
    v_row.subject := btrim(p_subject);
  END IF;
  IF p_to IS NOT NULL AND cardinality(p_to) > 0 AND cardinality(v_row.to_addresses) = 0 THEN
    v_row.to_addresses := p_to;
  END IF;

  IF v_status = 'sent' AND v_row.sent_at IS NULL THEN
    v_row.sent_at := v_at;
    v_applied := true;
  ELSIF v_status = 'delivered' AND v_row.delivered_at IS NULL THEN
    v_row.delivered_at := v_at;
    v_applied := true;
  ELSIF v_status = 'bounced' AND v_row.bounced_at IS NULL THEN
    v_row.bounced_at := v_at;
    v_applied := true;
    v_new_bounce := true;
  ELSIF v_status = 'opened' AND v_row.opened_at IS NULL THEN
    v_row.opened_at := v_at;
    v_applied := true;
  ELSIF v_status = 'complained' AND v_row.complained_at IS NULL THEN
    v_row.complained_at := v_at;
    v_applied := true;
    v_new_complaint := true;
  ELSIF v_status = 'delivery_delayed' AND v_row.delayed_at IS NULL THEN
    v_row.delayed_at := v_at;
    v_applied := true;
  END IF;

  IF v_status = 'bounced'
     AND p_bounce_reason IS NOT NULL
     AND btrim(p_bounce_reason) <> ''
     AND (v_row.bounce_reason IS NULL OR btrim(v_row.bounce_reason) = '') THEN
    v_row.bounce_reason := left(btrim(p_bounce_reason), 500);
  END IF;

  v_rank := CASE v_status
    WHEN 'sent' THEN 1
    WHEN 'delivery_delayed' THEN 2
    WHEN 'delivered' THEN 3
    WHEN 'opened' THEN 4
    WHEN 'bounced' THEN 10
    WHEN 'complained' THEN 11
    ELSE 0
  END;
  v_cur := CASE v_row.status
    WHEN 'sent' THEN 1
    WHEN 'delivery_delayed' THEN 2
    WHEN 'delivered' THEN 3
    WHEN 'opened' THEN 4
    WHEN 'bounced' THEN 10
    WHEN 'complained' THEN 11
    ELSE 0
  END;
  IF v_applied AND (
    v_rank >= 10
    OR (v_row.status NOT IN ('bounced', 'complained') AND v_rank >= v_cur)
  ) THEN
    IF v_row.status IS DISTINCT FROM v_status THEN
      v_row.status := v_status;
      v_row.status_at := v_at;
    END IF;
  END IF;

  UPDATE public.email_events SET
    subject = v_row.subject,
    to_addresses = v_row.to_addresses,
    sent_at = v_row.sent_at,
    status = v_row.status,
    status_at = v_row.status_at,
    delivered_at = v_row.delivered_at,
    bounced_at = v_row.bounced_at,
    bounce_reason = v_row.bounce_reason,
    opened_at = v_row.opened_at,
    complained_at = v_row.complained_at,
    delayed_at = v_row.delayed_at,
    updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  IF v_new_bounce OR v_new_complaint THEN
    v_link_type := CASE
      WHEN v_row.invoice_id IS NOT NULL THEN 'invoice'
      WHEN v_row.estimate_id IS NOT NULL THEN 'estimate'
      WHEN v_row.job_id IS NOT NULL THEN 'job'
      ELSE NULL
    END;
    v_link_id := COALESCE(v_row.invoice_id, v_row.estimate_id, v_row.job_id);
    v_message := left(
      CASE WHEN v_new_bounce THEN 'Email bounced' ELSE 'Email complaint' END
      || ': '
      || COALESCE(NULLIF(btrim(COALESCE(v_row.subject, '')), ''), 'message')
      || ' to '
      || COALESCE(NULLIF(array_to_string(v_row.to_addresses, ', '), ''), 'unknown')
      || CASE
           WHEN v_new_bounce AND v_row.bounce_reason IS NOT NULL AND btrim(v_row.bounce_reason) <> ''
           THEN ' — ' || v_row.bounce_reason
           ELSE ''
         END,
      500
    );
    INSERT INTO public.notifications (recipient_role, recipient_sub_id, message, link_type, link_id)
    VALUES ('admin', NULL, v_message, v_link_type, v_link_id);
  END IF;

  RETURN jsonb_build_object(
    'ignored', false,
    'id', v_row.id,
    'status', v_row.status,
    'newly_bounced', v_new_bounce,
    'newly_complained', v_new_complaint,
    'kind', v_row.kind,
    'invoice_id', v_row.invoice_id,
    'estimate_id', v_row.estimate_id,
    'job_id', v_row.job_id,
    'subject', v_row.subject,
    'message', v_message
  );
END
$fn$;

REVOKE ALL ON FUNCTION public.record_outgoing_email(text, text, uuid, uuid, uuid, text[], text[], text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_outgoing_email(text, text, uuid, uuid, uuid, text[], text[], text, timestamptz) TO service_role;

REVOKE ALL ON FUNCTION public.apply_resend_event(text, text, timestamptz, text[], text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_resend_event(text, text, timestamptz, text[], text, text) TO service_role;
