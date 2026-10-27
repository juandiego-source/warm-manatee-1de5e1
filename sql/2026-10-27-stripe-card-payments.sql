-- Sumak Ops — card payments through Stripe Checkout
-- Project: nrnnpprcshkgroghhbro
--
-- Paste this whole file into the Supabase SQL Editor as role postgres.
-- Safe to run again. It does not mark any existing invoice paid, and it
-- does not email anyone.
--
-- Adds empty columns to invoices, allows the payment method
-- 'Card (Stripe)', and adds apply_stripe_invoice_payment. Only the
-- stripe-webhook Edge Function (service role) may call that function.
-- A repeated webhook for the same payment intent does not send a second
-- office notification and does not change a payment that was already saved.
-- A card payment does not overwrite an invoice that was already marked
-- paid another way.
--
-- The Stripe secret key is not in this file. Set it as an Edge Function
-- secret, then deploy. The pull request has the webhook URL and events.
--
--   supabase secrets set STRIPE_SECRET_KEY=sk_test_... STRIPE_WEBHOOK_SECRET=whsec_... --project-ref nrnnpprcshkgroghhbro
--   supabase secrets set STRIPE_CARD_FEE_PERCENT=3 --project-ref nrnnpprcshkgroghhbro
--   supabase functions deploy stripe-checkout --project-ref nrnnpprcshkgroghhbro
--   supabase functions deploy stripe-webhook --project-ref nrnnpprcshkgroghhbro --no-verify-jwt
--
-- Webhook endpoint:
--   https://nrnnpprcshkgroghhbro.supabase.co/functions/v1/stripe-webhook
-- Events: checkout.session.completed, checkout.session.async_payment_succeeded

ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS stripe_checkout_session_id text,
  ADD COLUMN IF NOT EXISTS stripe_checkout_url text,
  ADD COLUMN IF NOT EXISTS card_fee numeric(12,2),
  ADD COLUMN IF NOT EXISTS card_fee_percent numeric(5,2);

ALTER TABLE public.invoices
  DROP CONSTRAINT IF EXISTS invoices_payment_method_check;

ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_payment_method_check
  CHECK (
    payment_method IS NULL
    OR payment_method IN (
      'Check',
      'Venmo',
      'Zelle',
      'Cash',
      'ACH/bank deposit',
      'Card',
      'Card (Stripe)',
      'Other'
    )
  );

ALTER TABLE public.invoices
  DROP CONSTRAINT IF EXISTS invoices_card_fee_check;

ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_card_fee_check
  CHECK (card_fee IS NULL OR (card_fee >= 0 AND card_fee <= 100000));

ALTER TABLE public.invoices
  DROP CONSTRAINT IF EXISTS invoices_card_fee_percent_check;

ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_card_fee_percent_check
  CHECK (card_fee_percent IS NULL OR (card_fee_percent >= 0 AND card_fee_percent <= 25));

ALTER TABLE public.invoices
  DROP CONSTRAINT IF EXISTS invoices_stripe_checkout_url_check;

ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_stripe_checkout_url_check
  CHECK (
    stripe_checkout_url IS NULL
    OR stripe_checkout_url ~ '^https://checkout\.stripe\.com/[^[:space:]]+$'
  );

COMMENT ON COLUMN public.invoices.stripe_checkout_session_id IS
  'Stripe Checkout Session id (cs_test_ or cs_live_). Null until the office creates a card link.';
COMMENT ON COLUMN public.invoices.stripe_checkout_url IS
  'Stripe-hosted checkout URL. The card is entered on Stripe, not in Sumak Ops.';
COMMENT ON COLUMN public.invoices.card_fee IS
  'Card processing fee charged on top of the invoice total. Null until a card payment is recorded.';
COMMENT ON COLUMN public.invoices.card_fee_percent IS
  'Percent used for the current card link. The fee is not added to the invoice total.';

CREATE UNIQUE INDEX IF NOT EXISTS invoices_card_payment_intent_uidx
  ON public.invoices (payment_reference)
  WHERE payment_method = 'Card (Stripe)' AND payment_reference IS NOT NULL;

CREATE OR REPLACE FUNCTION public.apply_stripe_invoice_payment(
  p_invoice_id uuid,
  p_payment_intent_id text,
  p_fee numeric,
  p_fee_percent numeric,
  p_session_id text,
  p_paid_on date
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
BEGIN
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

REVOKE ALL ON FUNCTION public.apply_stripe_invoice_payment(uuid, text, numeric, numeric, text, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_stripe_invoice_payment(uuid, text, numeric, numeric, text, date) TO service_role;

COMMENT ON FUNCTION public.apply_stripe_invoice_payment(uuid, text, numeric, numeric, text, date) IS
  'Marks one invoice paid from a verified Stripe webhook. Idempotent for the same payment intent. Service role only.';

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'invoices'
  AND column_name IN (
    'stripe_checkout_session_id',
    'stripe_checkout_url',
    'card_fee',
    'card_fee_percent',
    'payment_method',
    'payment_reference',
    'paid_on'
  )
ORDER BY column_name;
