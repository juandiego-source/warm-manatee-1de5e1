-- Local check only. Do not run this against the Sumak Ops project.
-- Proves a sub can post on their own job, cannot read or post on another
-- sub's job, and cannot read the cron dispatch table.

\set ON_ERROR_STOP on

-- Other sub's message, written as the table owner before we sign in.
INSERT INTO public.job_messages (job_id, author_id, body)
VALUES (
  '22222222-2222-4222-8222-222222222222',
  'aaaa3333-3333-4333-8333-333333333333',
  'private to sub b'
);

DO $owner$
DECLARE
  n int;
  boise_hour int;
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'job_messages'
      AND column_name IN ('client_price', 'margin', 'margin_pct', 'cost', 'office_price', 'sub_pay')
  ) THEN
    RAISE EXCEPTION 'job_messages has a price column';
  END IF;

  IF has_function_privilege('authenticated', 'public.sumak_dispatch_if_boise_hour(integer, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated can run the cron dispatcher';
  END IF;
  IF has_function_privilege('anon', 'public.sumak_dispatch_if_boise_hour(integer, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon can run the cron dispatcher';
  END IF;

  boise_hour := EXTRACT(HOUR FROM timezone('America/Boise', clock_timestamp()))::int;
  PERFORM public.sumak_dispatch_if_boise_hour((boise_hour + 5) % 24, 'reminder');
  -- Matching hour with no vault secret must skip, not raise.
  PERFORM public.sumak_dispatch_if_boise_hour(boise_hour, 'recap');

  SELECT count(*) INTO n FROM public.job_messages WHERE body = 'private to sub b';
  IF n < 1 THEN
    RAISE EXCEPTION 'owner fixture missing';
  END IF;
END
$owner$;

SELECT set_config('request.jwt.claim.sub', 'aaaa2222-2222-4222-8222-222222222222', false);
SELECT set_config('request.jwt.claim.role', 'authenticated', false);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"aaaa2222-2222-4222-8222-222222222222","role":"authenticated"}',
  false
);
SET ROLE authenticated;

DO $sub$
DECLARE
  n int;
  author uuid;
  message_id uuid;
BEGIN
  SELECT count(*) INTO n FROM public.job_messages;
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub saw % messages, including another sub', n;
  END IF;

  INSERT INTO public.job_messages (job_id, author_id, body)
  VALUES (
    '11111111-1111-4111-8111-111111111111',
    'aaaa1111-1111-4111-8111-111111111111',
    'On my way'
  )
  RETURNING id, author_id INTO message_id, author;

  IF author::text <> 'aaaa2222-2222-4222-8222-222222222222' THEN
    RAISE EXCEPTION 'message author was not rewritten to the signed-in sub: %', author;
  END IF;

  BEGIN
    INSERT INTO public.job_messages (job_id, author_id, body)
    VALUES (
      '22222222-2222-4222-8222-222222222222',
      'aaaa2222-2222-4222-8222-222222222222',
      'should not post'
    );
    RAISE EXCEPTION 'sub posted on another sub job';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    NULL;
  END;

  SELECT count(*) INTO n FROM public.job_messages WHERE body = 'should not post' OR body = 'private to sub b';
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub can see a message that is not theirs';
  END IF;

  SELECT count(*) INTO n FROM public.job_messages WHERE id = message_id AND body = 'On my way';
  IF n <> 1 THEN
    RAISE EXCEPTION 'sub cannot read their own message';
  END IF;

  BEGIN
    PERFORM 1 FROM public.comms_dispatches;
    RAISE EXCEPTION 'sub read comms_dispatches';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$sub$;

RESET ROLE;

-- Empty message is rejected.
DO $empty$
BEGIN
  INSERT INTO public.job_messages (job_id, author_id, body)
  VALUES ('11111111-1111-4111-8111-111111111111', 'aaaa1111-1111-4111-8111-111111111111', '   ');
  RAISE EXCEPTION 'blank message was stored';
EXCEPTION WHEN check_violation THEN
  NULL;
END
$empty$;

SELECT 'SUB_COMMS_OK' AS result;
