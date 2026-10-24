-- Local check only. Do not run this against the Sumak Ops project.
-- Proves delivery status is idempotent, a bounce notifies the office once,
-- and a sub or the anon role cannot read email_events.

\set ON_ERROR_STOP on

DO $flow$
DECLARE
  inv uuid := 'e1e1e1e1-e1e1-41e1-81e1-e1e1e1e1e1e1';
  est uuid := 'e3e3e3e3-e3e3-43e3-83e3-e3e3e3e3e3e3';
  result jsonb;
  n int;
  delivered_at timestamptz;
  opened_at timestamptz;
  sent_to text;
  status text;
  kind text;
BEGIN
  PERFORM public.record_outgoing_email(
    're_flow',
    'invoice',
    inv,
    NULL,
    NULL,
    ARRAY['billing@customer.test'],
    ARRAY['cc@customer.test'],
    'Invoice INV-9 from Sumak Lawncare',
    '2026-10-22 17:00:00+00'
  );

  SELECT i.sent_to INTO sent_to FROM public.invoices i WHERE i.id = inv;
  IF sent_to::json->'to'->>0 <> 'billing@customer.test' THEN
    RAISE EXCEPTION 'invoice sent_to was %', sent_to;
  END IF;
  IF sent_to::json->'cc'->>0 <> 'cc@customer.test' THEN
    RAISE EXCEPTION 'invoice cc was %', sent_to;
  END IF;
  IF (SELECT sent_at FROM public.invoices WHERE id = inv) <> '2026-10-22 17:00:00+00' THEN
    RAISE EXCEPTION 'invoice sent_at was not the send time';
  END IF;

  result := public.apply_resend_event(
    're_flow', 'email.delivered', '2026-10-22 17:01:00+00',
    ARRAY['billing@customer.test'], 'Invoice INV-9 from Sumak Lawncare', NULL
  );
  IF result->>'status' <> 'delivered' THEN
    RAISE EXCEPTION 'expected delivered, got %', result;
  END IF;

  result := public.apply_resend_event(
    're_flow', 'email.opened', '2026-10-22 17:04:00+00',
    NULL, NULL, NULL
  );
  IF result->>'status' <> 'opened' OR result->>'newly_bounced' <> 'false' THEN
    RAISE EXCEPTION 'expected opened, got %', result;
  END IF;

  SELECT e.delivered_at, e.opened_at INTO delivered_at, opened_at
    FROM public.email_events e WHERE e.resend_id = 're_flow';

  PERFORM public.apply_resend_event(
    're_flow', 'email.delivered', '2026-10-22 19:00:00+00',
    NULL, NULL, NULL
  );
  IF (SELECT e.delivered_at FROM public.email_events e WHERE e.resend_id = 're_flow') <> delivered_at THEN
    RAISE EXCEPTION 'a second delivery moved delivered_at';
  END IF;
  IF (SELECT e.status FROM public.email_events e WHERE e.resend_id = 're_flow') <> 'opened' THEN
    RAISE EXCEPTION 'a late delivery rewound an open';
  END IF;

  result := public.apply_resend_event(
    're_flow', 'email.bounced', '2026-10-22 17:06:00+00',
    ARRAY['billing@customer.test'], 'Invoice INV-9 from Sumak Lawncare',
    'Permanent · mailbox does not exist'
  );
  IF result->>'newly_bounced' <> 'true' OR result->>'status' <> 'bounced' THEN
    RAISE EXCEPTION 'expected a new bounce, got %', result;
  END IF;
  IF result->>'invoice_id' <> inv::text THEN
    RAISE EXCEPTION 'bounce was not linked to the invoice: %', result;
  END IF;

  result := public.apply_resend_event(
    're_flow', 'email.bounced', '2026-10-22 17:09:00+00',
    NULL, NULL, 'Permanent · mailbox does not exist'
  );
  IF result->>'newly_bounced' <> 'false' THEN
    RAISE EXCEPTION 'bounce retry looked new: %', result;
  END IF;
  IF (SELECT e.bounced_at FROM public.email_events e WHERE e.resend_id = 're_flow') <> '2026-10-22 17:06:00+00' THEN
    RAISE EXCEPTION 'bounce retry moved bounced_at';
  END IF;

  SELECT count(*) INTO n
    FROM public.notifications
   WHERE link_type = 'invoice' AND link_id = inv AND message LIKE 'Email bounced:%mailbox does not exist%';
  IF n <> 1 THEN
    RAISE EXCEPTION 'expected 1 bounce notification, got %', n;
  END IF;

  PERFORM public.apply_resend_event(
    're_flow', 'email.opened', '2026-10-22 20:00:00+00', NULL, NULL, NULL
  );
  SELECT e.status, e.opened_at INTO status, opened_at
    FROM public.email_events e WHERE e.resend_id = 're_flow';
  IF status <> 'bounced' THEN
    RAISE EXCEPTION 'an open cleared the bounce (% )', status;
  END IF;
  IF opened_at <> '2026-10-22 17:04:00+00' THEN
    RAISE EXCEPTION 'a second open moved opened_at';
  END IF;

  result := public.apply_resend_event('re_unknown', 'email.clicked', now(), NULL, NULL, NULL);
  IF result->>'ignored' <> 'true' THEN
    RAISE EXCEPTION 'unknown event was stored: %', result;
  END IF;
  IF EXISTS (SELECT 1 FROM public.email_events WHERE resend_id = 're_unknown') THEN
    RAISE EXCEPTION 'unknown event inserted a row';
  END IF;

  PERFORM public.apply_resend_event(
    're_race', 'email.delivered', '2026-10-22 18:01:00+00',
    ARRAY['billing@customer.test'], NULL, NULL
  );
  PERFORM public.record_outgoing_email(
    're_race', 'invoice', inv, NULL, NULL,
    ARRAY['billing@customer.test'], ARRAY['cc@customer.test'],
    'Invoice INV-9 from Sumak Lawncare', '2026-10-22 18:00:00+00'
  );
  SELECT e.status, e.kind, e.delivered_at INTO status, kind, delivered_at
    FROM public.email_events e WHERE e.resend_id = 're_race';
  IF status <> 'delivered' OR kind <> 'invoice' OR delivered_at <> '2026-10-22 18:01:00+00' THEN
    RAISE EXCEPTION 'send after webhook wiped delivery: % % %', status, kind, delivered_at;
  END IF;
  IF (SELECT e.invoice_id FROM public.email_events e WHERE e.resend_id = 're_race') <> inv THEN
    RAISE EXCEPTION 'send after webhook did not link the invoice';
  END IF;

  PERFORM public.apply_resend_event(
    're_race', 'email.delivery_delayed', '2026-10-22 18:02:00+00', NULL, NULL, NULL
  );
  IF (SELECT e.status FROM public.email_events e WHERE e.resend_id = 're_race') <> 'delivered' THEN
    RAISE EXCEPTION 'a delay rewound a delivery';
  END IF;
  IF (SELECT e.delayed_at FROM public.email_events e WHERE e.resend_id = 're_race') IS NULL THEN
    RAISE EXCEPTION 'delay timestamp was not saved';
  END IF;

  PERFORM public.record_outgoing_email(
    're_complaint', 'estimate', NULL, est, NULL,
    ARRAY['judy@customer.test'], ARRAY[]::text[],
    'Estimate EST-9 from Sumak Lawncare', now()
  );
  result := public.apply_resend_event(
    're_complaint', 'email.complained', now(), NULL, NULL, NULL
  );
  IF result->>'newly_complained' <> 'true' OR result->>'estimate_id' <> est::text THEN
    RAISE EXCEPTION 'complaint was not recorded: %', result;
  END IF;
  SELECT count(*) INTO n
    FROM public.notifications
   WHERE link_type = 'estimate' AND link_id = est AND message LIKE 'Email complaint:%';
  IF n <> 1 THEN
    RAISE EXCEPTION 'expected 1 complaint notification, got %', n;
  END IF;
  PERFORM public.apply_resend_event('re_complaint', 'email.complained', now(), NULL, NULL, NULL);
  SELECT count(*) INTO n
    FROM public.notifications
   WHERE link_type = 'estimate' AND link_id = est AND message LIKE 'Email complaint:%';
  IF n <> 1 THEN
    RAISE EXCEPTION 'complaint retry added a notification, count %', n;
  END IF;
END
$flow$;

DO $admin$
DECLARE
  n int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', 'aaaa1111-1111-4111-8111-111111111111', true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"aaaa1111-1111-4111-8111-111111111111","role":"authenticated"}',
    true
  );
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM public.email_events;
  IF n < 1 THEN
    RAISE EXCEPTION 'admin saw % email events', n;
  END IF;
  BEGIN
    INSERT INTO public.email_events (resend_id, kind, to_addresses, status)
    VALUES ('re_admin_insert', 'job', ARRAY['a@example.com'], 'sent');
    RAISE EXCEPTION 'admin inserted an email event';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
END
$admin$;

DO $sub$
DECLARE
  n int;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', 'aaaa2222-2222-4222-8222-222222222222', true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claims',
    '{"sub":"aaaa2222-2222-4222-8222-222222222222","role":"authenticated"}',
    true
  );
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM public.email_events;
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub saw % email events', n;
  END IF;
  BEGIN
    INSERT INTO public.email_events (resend_id, kind, to_addresses, status)
    VALUES ('re_sub_insert', 'job', ARRAY['a@example.com'], 'sent');
    RAISE EXCEPTION 'sub inserted an email event';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
  BEGIN
    PERFORM public.record_outgoing_email(
      're_sub_rpc', 'job', NULL, NULL, NULL,
      ARRAY['a@example.com'], ARRAY[]::text[], 'nope', now()
    );
    RAISE EXCEPTION 'sub recorded an email';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
  BEGIN
    PERFORM public.apply_resend_event('re_sub_rpc', 'email.bounced', now(), NULL, NULL, 'nope');
    RAISE EXCEPTION 'sub applied a webhook';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
END
$sub$;

DO $anon$
BEGIN
  EXECUTE 'SET LOCAL ROLE anon';
  BEGIN
    PERFORM count(*) FROM public.email_events;
    RAISE EXCEPTION 'anon read email_events';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
END
$anon$;

DO $service$
BEGIN
  EXECUTE 'SET LOCAL ROLE service_role';
  PERFORM public.record_outgoing_email(
    're_service_role', 'recap', NULL, NULL, NULL,
    ARRAY['office@sumaklawncare.com'], ARRAY[]::text[], 'recap', now()
  );
END
$service$;

DO $service_row$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.email_events WHERE resend_id = 're_service_role' AND kind = 'recap') THEN
    RAISE EXCEPTION 'service role send was not saved';
  END IF;
END
$service_row$;
