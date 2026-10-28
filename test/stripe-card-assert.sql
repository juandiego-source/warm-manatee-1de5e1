-- Local check only. Do not run this against the Sumak Ops project.
-- Proves a card webhook marks the invoice once, records the fee, and
-- does not let a subcontractor or the anon role call the function.

DO $flow$
DECLARE
  open_id uuid := '11111111-1111-4111-8111-111111111111';
  late_id uuid := '22222222-2222-4222-8222-222222222222';
  check_id uuid := '33333333-3333-4333-8333-333333333333';
  result jsonb;
  n int;
  row public.invoices%ROWTYPE;
BEGIN
  INSERT INTO public.invoices (id, invoice_number, status, subtotal, total)
  VALUES
    (open_id, 'INV-STRIPE-1', 'Unpaid', 100, 100),
    (late_id, 'INV-STRIPE-2', 'Overdue', 40, 40),
    (check_id, 'INV-STRIPE-3', 'Paid', 15, 15);

  UPDATE public.invoices
     SET payment_method = 'Check', payment_reference = '1002', paid_on = DATE '2026-10-01', paid_at = '2026-10-01 12:00:00+00'
   WHERE id = check_id;

  result := public.apply_stripe_invoice_payment(open_id, 'pi_cardOnce', 3.00, 3, 'cs_test_once', NULL, 10000, true, false);
  IF result->>'error' <> 'livemode' OR (SELECT status FROM public.invoices WHERE id = open_id) <> 'Unpaid' THEN
    RAISE EXCEPTION 'livemode mismatch was accepted: %', result;
  END IF;

  result := public.apply_stripe_invoice_payment(open_id, 'pi_cardOnce', 3.00, 3, 'cs_test_once', NULL, 50, false, false);
  IF result->>'error' <> 'amount_mismatch' OR (SELECT status FROM public.invoices WHERE id = open_id) <> 'Unpaid' THEN
    RAISE EXCEPTION 'amount mismatch was accepted: %', result;
  END IF;

  result := public.apply_stripe_invoice_payment(open_id, 'pi_cardOnce', 3.00, 3, 'cs_test_once', NULL, 10000, false, false);
  IF result->>'ok' <> 'true' OR result->>'already' <> 'false' THEN
    RAISE EXCEPTION 'first card payment was %', result;
  END IF;

  SELECT * INTO row FROM public.invoices WHERE id = open_id;
  IF row.status <> 'Paid' THEN
    RAISE EXCEPTION 'status is %', row.status;
  END IF;
  IF row.payment_method <> 'Card (Stripe)' THEN
    RAISE EXCEPTION 'method is %', row.payment_method;
  END IF;
  IF row.payment_reference <> 'pi_cardOnce' THEN
    RAISE EXCEPTION 'reference is %', row.payment_reference;
  END IF;
  IF row.card_fee <> 3.00 THEN
    RAISE EXCEPTION 'fee is %', row.card_fee;
  END IF;
  IF row.card_fee_percent <> 3 THEN
    RAISE EXCEPTION 'percent is %', row.card_fee_percent;
  END IF;
  IF row.paid_on IS NULL OR row.paid_at IS NULL THEN
    RAISE EXCEPTION 'paid date was not set';
  END IF;
  IF row.total <> 100 THEN
    RAISE EXCEPTION 'invoice total changed to %', row.total;
  END IF;
  IF row.stripe_checkout_session_id <> 'cs_test_once' THEN
    RAISE EXCEPTION 'session was %', row.stripe_checkout_session_id;
  END IF;

  SELECT count(*) INTO n FROM public.notifications WHERE link_id = open_id AND recipient_role = 'admin';
  IF n <> 1 THEN
    RAISE EXCEPTION 'office notification count is %', n;
  END IF;
  IF EXISTS (SELECT 1 FROM public.notifications WHERE link_id = open_id AND message LIKE '%checkout.stripe.com%') THEN
    RAISE EXCEPTION 'notification included the checkout url';
  END IF;

  result := public.apply_stripe_invoice_payment(open_id, 'pi_cardOnce', 3.00, 3, 'cs_test_once', NULL, 10000, false, false);
  IF result->>'already' <> 'true' THEN
    RAISE EXCEPTION 'repeat was not idempotent: %', result;
  END IF;
  SELECT count(*) INTO n FROM public.notifications WHERE link_id = open_id;
  IF n <> 1 THEN
    RAISE EXCEPTION 'repeat wrote another notification (% )', n;
  END IF;

  result := public.apply_stripe_invoice_payment(open_id, 'pi_otherCard', 3.00, 3, NULL, NULL, 10000, false, false);
  IF result->>'reason' <> 'already_paid' THEN
    RAISE EXCEPTION 'a second card did not stay ignored: %', result;
  END IF;
  IF (SELECT payment_reference FROM public.invoices WHERE id = open_id) <> 'pi_cardOnce' THEN
    RAISE EXCEPTION 'reference was overwritten';
  END IF;

  result := public.apply_stripe_invoice_payment(late_id, 'pi_cardOnce', 1.20, 3, NULL, NULL, 4000, false, false);
  IF result->>'reason' <> 'duplicate_payment' THEN
    RAISE EXCEPTION 'same payment intent was applied twice: %', result;
  END IF;
  IF (SELECT status FROM public.invoices WHERE id = late_id) <> 'Overdue' THEN
    RAISE EXCEPTION 'the second invoice changed';
  END IF;

  result := public.apply_stripe_invoice_payment(late_id, 'pi_overdueCard', 1.20, 3, 'cs_live_late', DATE '2026-10-27', 4000, false, false);
  IF result->>'already' <> 'false' THEN
    RAISE EXCEPTION 'overdue invoice was not marked paid: %', result;
  END IF;
  SELECT * INTO row FROM public.invoices WHERE id = late_id;
  IF row.status <> 'Paid' OR row.payment_method <> 'Card (Stripe)' OR row.card_fee <> 1.20 OR row.paid_on <> DATE '2026-10-27' THEN
    RAISE EXCEPTION 'overdue payment saved wrong: % % % %', row.status, row.payment_method, row.card_fee, row.paid_on;
  END IF;

  result := public.apply_stripe_invoice_payment(check_id, 'pi_afterCheck', 0.45, 3, NULL, NULL, 1500, false, false);
  IF result->>'reason' <> 'already_paid' THEN
    RAISE EXCEPTION 'a check payment was replaced: %', result;
  END IF;
  IF (SELECT payment_method FROM public.invoices WHERE id = check_id) <> 'Check' THEN
    RAISE EXCEPTION 'check method changed';
  END IF;

  IF has_function_privilege('anon', 'public.apply_stripe_invoice_payment(uuid,text,numeric,numeric,text,date,integer,boolean,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon can mark an invoice paid';
  END IF;
  IF has_function_privilege('authenticated', 'public.apply_stripe_invoice_payment(uuid,text,numeric,numeric,text,date,integer,boolean,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'a signed-in user can mark an invoice paid';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.apply_stripe_invoice_payment(uuid,text,numeric,numeric,text,date,integer,boolean,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service role cannot record the webhook';
  END IF;
END
$flow$;

DO $denied$
BEGIN
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.apply_stripe_invoice_payment(
      '11111111-1111-4111-8111-111111111111',
      'pi_notallowed',
      1, 3, NULL, NULL, 10000, false, false
    );
    RAISE EXCEPTION 'authenticated applied a card payment';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
END
$denied$;
