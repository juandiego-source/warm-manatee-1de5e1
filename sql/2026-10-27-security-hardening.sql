-- Sumak Ops security hardening. Project nrnnpprcshkgroghhbro.
-- Paste this whole file in the Supabase SQL editor as postgres. It is safe to run again.
-- Do not put a service role key, JWT, or other secret in this file.
--
-- After it succeeds, the owner still has to:
--   1. Create the Vault secret the push trigger reads (dashboard key, not this file):
--        select vault.create_secret('<service role key from the dashboard>', 'service_role_key');
--      cron_secret may already exist. The trigger sends it as x-cron-secret when it is present.
--   2. Deploy send-push, smooth-handler, and stripe-webhook. Leave send-push JWT
--      verification on when service_role_key is in Vault. Set the function secret
--      CRON_SECRET to the same value as vault cron_secret.
--   3. Set STRIPE_EXPECTED_LIVEMODE (or STRIPE_LIVEMODE) to true or false, or leave
--      it unset and keep STRIPE_SECRET_KEY so the webhook can tell live from test.
--   4. Turn off public signup in Authentication settings.
--   5. Rotate the service role / JWT secret in the dashboard, then update the Vault
--      secret service_role_key to the new key. Redeploy functions so they pick up
--      the new SUPABASE_SERVICE_ROLE_KEY.

-- ---------------------------------------------------------------------------
-- admin_jobs is an admin-only view of jobs. security_invoker makes the
-- caller's row security apply. Admins already have SELECT on jobs and the
-- jobs_admin_all policy. A sub's jobs policy returns no rows, and the view
-- still requires is_admin(), so a sub still sees nothing.
-- A view cannot be truncated. If Postgres rejects TRUNCATE, revoke the writes
-- it does allow.
-- ---------------------------------------------------------------------------
ALTER VIEW public.admin_jobs SET (security_invoker = true);

DO $admin_jobs_priv$
BEGIN
  REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.admin_jobs FROM PUBLIC, anon, authenticated;
EXCEPTION
  WHEN OTHERS THEN
    IF SQLSTATE = '0LP01' THEN
      REVOKE INSERT, UPDATE, DELETE ON TABLE public.admin_jobs FROM PUBLIC, anon, authenticated;
    ELSE
      RAISE;
    END IF;
END
$admin_jobs_priv$;

REVOKE ALL ON TABLE public.admin_jobs FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.admin_jobs TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- sub_jobs and sub_cost_requests stay security_invoker = false on purpose.
-- They are owned by postgres, so today the owner's bypass of row security is
-- what lets a sub see their own rows. The underlying jobs, cost_requests, and
-- customers policies are admin-only (is_admin()). Turning security_invoker on
-- would make those views return no rows for a sub.
-- Granting a sub SELECT on jobs so the view could run as the caller would
-- also expose jobs.client_price. jobs has client_price and sub_pay, and no
-- separate margin column. Row security cannot hide a column. Leave the two
-- views as they are so a sub still cannot read client price, margin, or an
-- extended cost.
-- sub_payment_jobs is a table, not a view, so security_invoker does not apply.
-- Its only policy is sub_payment_jobs_admin_all (is_admin()). A sub cannot
-- read it. Its amount is a payout slice, not the client price. Leave it.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Extra table privileges. anon and authenticated do not need TRUNCATE,
-- TRIGGER, or REFERENCES. Views reject some of those privilege names; skip
-- that relation and continue.
-- ---------------------------------------------------------------------------
DO $revoke_extra$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'v', 'm')
  LOOP
    BEGIN
      EXECUTE format(
        'REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE %I.%I FROM anon, authenticated',
        r.nspname, r.relname
      );
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLSTATE <> '0LP01' THEN
          RAISE;
        END IF;
    END;
  END LOOP;
END
$revoke_extra$;

-- ---------------------------------------------------------------------------
-- Cron jobs run as the database owner, not as anon or authenticated.
-- generate-recurring-jobs calls process_recurring_services().
-- attention-summary calls send_attention_summary().
-- Nobody signed in, and nobody anonymous, should be able to run them.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.send_attention_summary() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.process_recurring_services() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.send_attention_summary() TO service_role;
GRANT EXECUTE ON FUNCTION public.process_recurring_services() TO service_role;

-- ---------------------------------------------------------------------------
-- These helpers are used after a session exists. The staff app does not call
-- them with the anon role. Signup is auth.signUp, then claim_subcontractor_invite
-- runs in afterLogin once the session exists. The triggers handle_new_user
-- (on auth.users) and link_invited_subcontractor (on profiles) are not in
-- this list and keep the grants signup needs.
-- get_public_quote, mark_quote_viewed, and respond_to_quote stay callable
-- by anon. The public quote page and the Netlify quote function use them
-- before anyone signs in.
-- REVOKE FROM PUBLIC matters: revoking anon alone leaves the public grant.
-- ---------------------------------------------------------------------------
DO $revoke_anon_helpers$
DECLARE
  fn regprocedure;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.is_admin()'::regprocedure,
    'public.current_subcontractor_id()'::regprocedure,
    'public.my_sub_id()'::regprocedure,
    'public.job_assigned_to_me(uuid)'::regprocedure,
    'public.subcontractor_id_from_invite(uuid)'::regprocedure,
    'public.claim_subcontractor_invite()'::regprocedure,
    'public.sub_accept_job(uuid)'::regprocedure,
    'public.sub_save_site_report(uuid, jsonb)'::regprocedure,
    'public.sub_set_job_status(uuid, text)'::regprocedure,
    'public.sub_submit_cost(uuid, numeric, text)'::regprocedure
  ]
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', fn);
  END LOOP;
END
$revoke_anon_helpers$;

GRANT EXECUTE ON FUNCTION public.get_public_quote(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_quote_viewed(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.respond_to_quote(text, text, text, jsonb) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- A signed-in user may register a push device only for their own user id,
-- their own profile role, and their own subcontractor id. An admin's role
-- is admin, so an admin may register an admin device. They may not register
-- a sub device, and a sub may not register an admin device.
-- Admins can still read and delete every device (DELETE does not use
-- WITH CHECK). Both policies are permissive, so both checks have to agree.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS push_subscriptions_admin_all ON public.push_subscriptions;
DROP POLICY IF EXISTS push_subscriptions_own ON public.push_subscriptions;

CREATE POLICY push_subscriptions_admin_all
  ON public.push_subscriptions
  FOR ALL
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (
    user_id = auth.uid()
    AND recipient_role = (SELECT role FROM public.profiles WHERE id = auth.uid())
    AND recipient_sub_id IS NOT DISTINCT FROM (SELECT subcontractor_id FROM public.profiles WHERE id = auth.uid())
  );

CREATE POLICY push_subscriptions_own
  ON public.push_subscriptions
  FOR ALL
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (
    user_id = auth.uid()
    AND recipient_role = (SELECT role FROM public.profiles WHERE id = auth.uid())
    AND recipient_sub_id IS NOT DISTINCT FROM (SELECT subcontractor_id FROM public.profiles WHERE id = auth.uid())
  );

-- ---------------------------------------------------------------------------
-- Public quote abuse limit. One opened-notification and one response
-- notification per token per 10 minutes, counted separately so a view does
-- not swallow an accept. Calls are also counted. The table is not granted
-- to the API. quote_rate_allow is security definer and is not granted to
-- anon or authenticated; the quote functions call it as the owner.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.quote_action_buckets (
  token_hash text NOT NULL,
  action text NOT NULL,
  window_start timestamptz NOT NULL,
  hits integer NOT NULL DEFAULT 0,
  PRIMARY KEY (token_hash, action, window_start)
);

ALTER TABLE public.quote_action_buckets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.quote_action_buckets FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.quote_rate_allow(p_token text, p_action text, p_limit integer)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_hash text;
  v_window timestamptz;
  v_hits integer;
  v_global integer;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[A-Za-z0-9_-]{8,128}$' THEN
    RETURN false;
  END IF;
  IF p_action NOT IN ('view', 'respond') OR p_limit IS NULL OR p_limit < 1 THEN
    RETURN false;
  END IF;
  v_hash := md5(p_token);
  v_window := to_timestamp(floor(extract(epoch FROM clock_timestamp()) / 600) * 600);
  DELETE FROM public.quote_action_buckets
  WHERE window_start < clock_timestamp() - interval '2 days';
  SELECT coalesce(sum(hits), 0) INTO v_global
  FROM public.quote_action_buckets
  WHERE action = p_action
    AND window_start = v_window;
  IF v_global >= 240 THEN
    RETURN false;
  END IF;
  INSERT INTO public.quote_action_buckets (token_hash, action, window_start, hits)
  VALUES (v_hash, p_action, v_window, 1)
  ON CONFLICT (token_hash, action, window_start)
  DO UPDATE SET hits = public.quote_action_buckets.hits + 1
  RETURNING hits INTO v_hits;
  RETURN v_hits <= p_limit;
END
$fn$;

REVOKE ALL ON FUNCTION public.quote_rate_allow(text, text, integer) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.mark_quote_viewed(p_token text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  IF NOT public.quote_rate_allow(p_token, 'view', 30) THEN
    RETURN;
  END IF;
  UPDATE public.estimates
  SET viewed_at = COALESCE(viewed_at, now()),
      view_count = COALESCE(view_count, 0) + 1
  WHERE public_token = p_token
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN;
  END IF;

  -- First view only, and at most one opened-notification per token per 10 minutes.
  INSERT INTO public.notifications (recipient_role, message, link_type, link_id)
  SELECT 'admin',
         left('Client opened estimate ' || e.estimate_number, 500),
         'estimate',
         e.id
  FROM public.estimates e
  WHERE e.id = v_id
    AND e.view_count = 1
    AND NOT EXISTS (
      SELECT 1
      FROM public.notifications n
      WHERE n.link_type = 'estimate'
        AND n.link_id = e.id
        AND n.message LIKE 'Client opened estimate %'
        AND n.created_at > now() - interval '10 minutes'
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.respond_to_quote(p_token text, p_response text, p_note text, p_selected jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_est public.estimates%ROWTYPE;
  v_note text;
BEGIN
  IF NOT public.quote_rate_allow(p_token, 'respond', 8) THEN
    RETURN jsonb_build_object('error', 'rate_limited');
  END IF;
  IF p_note IS NOT NULL AND length(p_note) > 2000 THEN
    RETURN jsonb_build_object('error', 'too_large');
  END IF;
  IF p_selected IS NOT NULL AND length(p_selected::text) > 8000 THEN
    RETURN jsonb_build_object('error', 'too_large');
  END IF;

  SELECT * INTO v_est
  FROM public.estimates
  WHERE public_token = p_token
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'not_found');
  END IF;

  IF v_est.client_response IS NOT NULL THEN
    RETURN jsonb_build_object('error', 'already_responded', 'response', v_est.client_response);
  END IF;

  IF p_response NOT IN ('Accepted', 'Declined', 'Changes Requested') THEN
    RETURN jsonb_build_object('error', 'invalid_response');
  END IF;

  v_note := NULLIF(left(p_note, 2000), '');

  UPDATE public.estimates
  SET client_response = p_response,
      client_response_at = now(),
      client_note = v_note,
      client_selected_items = p_selected,
      status = CASE WHEN p_response = 'Accepted' THEN 'Approved' ELSE status END
  WHERE id = v_est.id;

  -- A view notification does not count as a response notification.
  IF NOT EXISTS (
    SELECT 1
    FROM public.notifications n
    WHERE n.link_type = 'estimate'
      AND n.link_id = v_est.id
      AND n.message LIKE 'Client %'
      AND n.message NOT LIKE 'Client opened%'
      AND n.created_at > now() - interval '10 minutes'
  ) THEN
    INSERT INTO public.notifications (recipient_role, message, link_type, link_id)
    VALUES (
      'admin',
      left(
        'Client ' || p_response || ': estimate ' || coalesce(v_est.estimate_number, 'estimate')
          || coalesce(' — "' || left(v_note, 180) || '"', ''),
        500
      ),
      'estimate',
      v_est.id
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'response', p_response);
END
$fn$;

GRANT EXECUTE ON FUNCTION public.mark_quote_viewed(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.respond_to_quote(text, text, text, jsonb) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Push trigger. Do not embed a service role JWT in this function.
-- It reads Vault secrets service_role_key and cron_secret. The service role
-- key is sent as Authorization: Bearer so the gateway JWT check can stay on.
-- cron_secret is sent as x-cron-secret, the same header job-comms uses.
-- A missing Vault or a failed HTTP call must not roll back the notification.
-- search_path is pinned. The function is security definer so signed-in users
-- are not granted Vault.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_send_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions, vault, pg_temp
AS $fn$
DECLARE
  v_key text;
  v_cron text;
  v_headers jsonb;
BEGIN
  v_key := NULL;
  v_cron := NULL;
  BEGIN
    SELECT
      max(decrypted_secret) FILTER (WHERE name = 'service_role_key'),
      max(decrypted_secret) FILTER (WHERE name = 'cron_secret')
    INTO v_key, v_cron
    FROM vault.decrypted_secrets
    WHERE name IN ('service_role_key', 'cron_secret');
  EXCEPTION
    WHEN OTHERS THEN
      -- A missing Vault, or no permission to read it, must not undo the
      -- notification insert and must not print the secret.
      v_key := NULL;
      v_cron := NULL;
  END;
  v_key := NULLIF(btrim(coalesce(v_key, '')), '');
  v_cron := NULLIF(btrim(coalesce(v_cron, '')), '');
  IF v_key IS NULL AND v_cron IS NULL THEN
    RAISE NOTICE 'send-push skipped: vault has neither service_role_key nor cron_secret';
    RETURN NEW;
  END IF;
  v_headers := jsonb_strip_nulls(jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', CASE WHEN v_key IS NULL THEN NULL ELSE 'Bearer ' || v_key END,
    'x-cron-secret', v_cron
  ));
  BEGIN
    PERFORM net.http_post(
      url := 'https://nrnnpprcshkgroghhbro.supabase.co/functions/v1/send-push',
      headers := v_headers,
      body := jsonb_build_object('record', to_jsonb(NEW)),
      timeout_milliseconds := 10000
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'send-push was not called';
  END;
  RETURN NEW;
END
$fn$;

REVOKE ALL ON FUNCTION public.trigger_send_push() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trigger_send_push() TO authenticated, service_role;

-- trigger_send_sms posts to /functions/v1/send-sms with a placeholder key.
-- There is no send-sms function and no trigger or cron job calls it.
-- Drop it only when nothing still depends on it.
DO $drop_sms$
DECLARE
  r record;
BEGIN
  IF to_regprocedure('public.trigger_send_sms()') IS NULL THEN
    RETURN;
  END IF;
  FOR r IN
    SELECT n.nspname, c.relname, t.tgname
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_proc p ON p.oid = t.tgfoid
    WHERE p.proname = 'trigger_send_sms'
      AND NOT t.tgisinternal
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', r.tgname, r.nspname, r.relname);
  END LOOP;
  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_proc p ON p.oid = t.tgfoid
    WHERE p.proname = 'trigger_send_sms'
      AND NOT t.tgisinternal
  ) THEN
    RAISE NOTICE 'trigger_send_sms is still used by a trigger; not dropped';
    RETURN;
  END IF;
  DROP FUNCTION public.trigger_send_sms();
END
$drop_sms$;

-- ---------------------------------------------------------------------------
-- Card payments. The balance part, excluding the card fee, must equal the
-- invoice's current unpaid total in cents. Livemode must match the mode the
-- webhook derived from STRIPE_EXPECTED_LIVEMODE, STRIPE_LIVEMODE, or the
-- secret key prefix. A repeat of the same payment intent still succeeds.
-- The 6-argument form is removed so it cannot be called by mistake.
-- The same replacement is in sql/2026-10-27-stripe-card-payments.sql.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.apply_stripe_invoice_payment(uuid, text, numeric, numeric, text, date);

CREATE OR REPLACE FUNCTION public.apply_stripe_invoice_payment(
  p_invoice_id uuid,
  p_payment_intent_id text,
  p_fee numeric,
  p_fee_percent numeric,
  p_session_id text,
  p_paid_on date,
  p_balance_cents integer,
  p_livemode boolean,
  p_expected_livemode boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.invoices%ROWTYPE;
  v_pi text;
  v_fee numeric;
  v_percent numeric;
  v_session text;
  v_paid_on date;
  v_message text;
  v_due_cents integer;
BEGIN
  IF p_livemode IS NULL OR p_expected_livemode IS NULL OR p_livemode IS DISTINCT FROM p_expected_livemode THEN
    RETURN jsonb_build_object('ok', false, 'error', 'livemode');
  END IF;
  IF p_invoice_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invoice required');
  END IF;
  v_pi := btrim(COALESCE(p_payment_intent_id, ''));
  IF v_pi !~ '^pi_[A-Za-z0-9]+$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment intent required');
  END IF;
  IF p_fee IS NULL OR p_fee < 0 OR p_fee > 100000 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fee required');
  END IF;
  v_fee := round(p_fee, 2);
  IF p_fee_percent IS NOT NULL AND (p_fee_percent < 0 OR p_fee_percent > 25) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fee percent');
  END IF;
  v_percent := CASE WHEN p_fee_percent IS NULL THEN NULL ELSE round(p_fee_percent, 2) END;
  v_session := NULLIF(btrim(COALESCE(p_session_id, '')), '');
  IF v_session IS NOT NULL AND v_session !~ '^cs_(test|live)_[A-Za-z0-9]+$' THEN
    v_session := NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.invoices
  WHERE id = p_invoice_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF v_row.status = 'Paid' AND v_row.payment_reference IS NOT DISTINCT FROM v_pi THEN
    UPDATE public.invoices
       SET card_fee = COALESCE(card_fee, v_fee),
           card_fee_percent = COALESCE(card_fee_percent, v_percent),
           stripe_checkout_session_id = COALESCE(stripe_checkout_session_id, v_session)
     WHERE id = p_invoice_id;
    RETURN jsonb_build_object('ok', true, 'already', true, 'invoice_id', p_invoice_id);
  END IF;

  IF v_row.status = 'Paid' THEN
    RETURN jsonb_build_object('ok', true, 'ignored', true, 'reason', 'already_paid', 'invoice_id', p_invoice_id);
  END IF;

  IF v_row.status NOT IN ('Unpaid', 'Overdue') THEN
    RETURN jsonb_build_object('ok', true, 'ignored', true, 'reason', 'status', 'invoice_id', p_invoice_id);
  END IF;

  -- The card fee is extra. The balance part must equal what the invoice
  -- still shows as unpaid, in cents. A partial or stale checkout is rejected.
  v_due_cents := round(coalesce(v_row.total, 0) * 100)::integer;
  IF p_balance_cents IS NULL OR p_balance_cents IS DISTINCT FROM v_due_cents THEN
    RETURN jsonb_build_object('ok', false, 'error', 'amount_mismatch', 'invoice_id', p_invoice_id);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.invoices other
    WHERE other.payment_reference = v_pi
      AND other.payment_method = 'Card (Stripe)'
      AND other.id <> p_invoice_id
  ) THEN
    RETURN jsonb_build_object('ok', true, 'ignored', true, 'reason', 'duplicate_payment');
  END IF;

  v_paid_on := COALESCE(p_paid_on, (timezone('America/Boise', now()))::date);

  UPDATE public.invoices
     SET status = 'Paid',
         payment_method = 'Card (Stripe)',
         payment_reference = v_pi,
         card_fee = v_fee,
         card_fee_percent = COALESCE(v_percent, card_fee_percent),
         paid_on = v_paid_on,
         paid_at = COALESCE(paid_at, now()),
         stripe_checkout_session_id = COALESCE(v_session, stripe_checkout_session_id)
   WHERE id = p_invoice_id
     AND status IN ('Unpaid', 'Overdue');

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'ignored', true, 'reason', 'status', 'invoice_id', p_invoice_id);
  END IF;

  v_message := left(
    'Invoice ' || COALESCE(v_row.invoice_number, 'invoice')
      || ' paid by card'
      || ' · card fee $' || to_char(v_fee, 'FM999990.00'),
    500
  );
  INSERT INTO public.notifications (recipient_role, recipient_sub_id, message, link_type, link_id)
  VALUES ('admin', NULL, v_message, 'invoice', p_invoice_id);

  RETURN jsonb_build_object(
    'ok', true,
    'already', false,
    'ignored', false,
    'invoice_id', p_invoice_id,
    'payment_reference', v_pi,
    'card_fee', v_fee
  );
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', true, 'ignored', true, 'reason', 'duplicate_payment');
END
$fn$;

REVOKE ALL ON FUNCTION public.apply_stripe_invoice_payment(uuid, text, numeric, numeric, text, date, integer, boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_stripe_invoice_payment(uuid, text, numeric, numeric, text, date, integer, boolean, boolean) TO service_role;

COMMENT ON FUNCTION public.apply_stripe_invoice_payment(uuid, text, numeric, numeric, text, date, integer, boolean, boolean) IS
  'Marks one invoice paid from a verified Stripe webhook. The balance part, excluding the card fee, must equal the invoice total in cents, and livemode must match the expected mode. Idempotent for the same payment intent. Service role only.';
