-- Local check only. Do not run this against the Sumak Ops project.
-- Signs in as sub A the way PostgREST does (JWT sub claim + role authenticated)
-- and fails if that account can read a price, a margin, another sub's pay,
-- a customer, or an office row.

\set ON_ERROR_STOP on

SELECT set_config('request.jwt.claim.sub', 'aaaa2222-2222-4222-8222-222222222222', false);
SELECT set_config('request.jwt.claim.role', 'authenticated', false);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"aaaa2222-2222-4222-8222-222222222222","role":"authenticated"}',
  false
);

SET ROLE authenticated;

-- These are the reads the app, or a modified client, would send:
--   GET /jobs?select=client_price
--   GET /sub_jobs?select=client_price
--   GET /invoice_items?select=total,cost,margin_pct
--   GET /customers?select=email
--   GET /sub_payments?select=amount
DO $api$
DECLARE
  n int;
  pay numeric;
  customer_label text;
  visible text;
BEGIN
  IF auth.uid()::text <> 'aaaa2222-2222-4222-8222-222222222222' THEN
    RAISE EXCEPTION 'JWT did not stick: %', auth.uid();
  END IF;
  IF public.current_subcontractor_id()::text <> 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' THEN
    RAISE EXCEPTION 'current_subcontractor_id is %', public.current_subcontractor_id();
  END IF;

  SELECT count(*) INTO n FROM public.jobs;
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub read % job rows from jobs, including client_price', n;
  END IF;

  SELECT count(*) INTO n FROM public.jobs WHERE client_price IS NOT NULL OR client_price IS NULL;
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub read client_price from jobs';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'sub_jobs'
      AND column_name IN ('client_price', 'margin', 'margin_pct', 'cost')
  ) THEN
    RAISE EXCEPTION 'sub_jobs exposes a price column';
  END IF;

  BEGIN
    EXECUTE 'SELECT client_price FROM public.sub_jobs LIMIT 1';
    RAISE EXCEPTION 'sub_jobs accepted a client_price select';
  EXCEPTION WHEN undefined_column THEN
    NULL;
  END;

  SELECT count(*), min(sub_pay), min(customer_name)
    INTO n, pay, customer_label
  FROM public.sub_jobs;
  IF n <> 1 OR pay <> 40 OR customer_label <> 'Private Client' THEN
    RAISE EXCEPTION 'own sub_jobs row was % / % / %', n, pay, customer_label;
  END IF;

  SELECT count(*) INTO n FROM public.sub_jobs WHERE sub_pay = 77 OR job_number = 'SMK-B';
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub saw the other sub pay';
  END IF;

  SELECT string_agg(office_table || '=' || row_count::text, ', ')
    INTO visible
  FROM (
    SELECT 'customers' AS office_table, count(*) AS row_count FROM public.customers
    UNION ALL SELECT 'properties', count(*) FROM public.properties
    UNION ALL SELECT 'estimates', count(*) FROM public.estimates
    UNION ALL SELECT 'estimate_items', count(*) FROM public.estimate_items
    UNION ALL SELECT 'invoices', count(*) FROM public.invoices
    UNION ALL SELECT 'invoice_items', count(*) FROM public.invoice_items
    UNION ALL SELECT 'recurring_services', count(*) FROM public.recurring_services
    UNION ALL SELECT 'services', count(*) FROM public.services
    UNION ALL SELECT 'sub_payments', count(*) FROM public.sub_payments
    UNION ALL SELECT 'sub_payment_jobs', count(*) FROM public.sub_payment_jobs
    UNION ALL SELECT 'cost_requests', count(*) FROM public.cost_requests
    UNION ALL SELECT 'activity_log', count(*) FROM public.activity_log
  ) leaked
  WHERE row_count <> 0;
  IF visible IS NOT NULL THEN
    RAISE EXCEPTION 'sub read office rows: %', visible;
  END IF;

  SELECT count(*) INTO n FROM public.invoice_items WHERE margin_pct > 0 OR cost > 0 OR total > 0;
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub read invoice margin, cost, or total';
  END IF;

  SELECT count(*) INTO n FROM public.customers WHERE email = 'secret@customer.test';
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub read the customer email';
  END IF;

  SELECT count(*) INTO n FROM public.subcontractors;
  IF n <> 1 THEN
    RAISE EXCEPTION 'sub saw % subcontractor rows', n;
  END IF;

  SELECT count(*) INTO n FROM public.subcontractors WHERE email = 'b@example.com';
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub saw the other subcontractor';
  END IF;

  SELECT count(*) INTO n FROM public.job_photos;
  IF n <> 1 THEN
    RAISE EXCEPTION 'sub saw % photo rows', n;
  END IF;

  SELECT count(*) INTO n FROM public.job_photos WHERE job_id = '22222222-2222-4222-8222-222222222222';
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub saw the other job photo';
  END IF;

  SELECT count(*) INTO n FROM storage.objects WHERE bucket_id = 'job-photos';
  IF n <> 1 THEN
    RAISE EXCEPTION 'sub saw % storage objects', n;
  END IF;

  SELECT count(*) INTO n
  FROM storage.objects AS stored
  WHERE stored.name LIKE '22222222-2222-4222-8222-222222222222/%';
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub saw the other job file';
  END IF;

  SELECT count(*) INTO n FROM public.notifications;
  IF n <> 1 THEN
    RAISE EXCEPTION 'sub saw % notifications', n;
  END IF;

  SELECT count(*) INTO n FROM public.notifications WHERE message = 'Office only' OR message = 'Hello B';
  IF n <> 0 THEN
    RAISE EXCEPTION 'sub saw an office or other-sub notification';
  END IF;

  SELECT count(*) INTO n FROM public.sub_cost_requests;
  IF n <> 1 THEN
    RAISE EXCEPTION 'sub saw % quote requests', n;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'sub_cost_requests'
      AND column_name = 'office_price'
  ) THEN
    RAISE EXCEPTION 'sub_cost_requests exposes office_price';
  END IF;

  UPDATE public.jobs
  SET client_price = 999, sub_pay = 1, status = 'Completed'
  WHERE id = '11111111-1111-4111-8111-111111111111';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN
    RAISE EXCEPTION 'direct job update changed % rows', n;
  END IF;
END
$api$;

RESET ROLE;

DO $price$
DECLARE
  price numeric;
BEGIN
  SELECT client_price INTO price
  FROM public.jobs
  WHERE id = '11111111-1111-4111-8111-111111111111';
  IF price <> 125 THEN
    RAISE EXCEPTION 'client_price changed to %', price;
  END IF;
END
$price$;

-- Same JWT, through the status function. It must not be able to set a price.
SELECT set_config('request.jwt.claim.sub', 'aaaa2222-2222-4222-8222-222222222222', false);
SET ROLE authenticated;

DO $rpc$
DECLARE
  result jsonb;
  price numeric;
  other jsonb;
BEGIN
  result := public.sub_set_job_status('11111111-1111-4111-8111-111111111111', 'In Progress');
  IF result->>'status' <> 'In Progress' THEN
    RAISE EXCEPTION 'own status did not change: %', result;
  END IF;

  BEGIN
    other := public.sub_set_job_status('22222222-2222-4222-8222-222222222222', 'Completed');
    RAISE EXCEPTION 'sub changed someone else''s job: %', other;
  EXCEPTION WHEN others THEN
    IF SQLERRM = 'sub changed someone else''s job: ' || COALESCE(other::text, '') THEN
      RAISE;
    END IF;
    IF SQLERRM <> 'Job not found' THEN
      RAISE EXCEPTION 'unexpected rpc error: %', SQLERRM;
    END IF;
  END;
END
$rpc$;

RESET ROLE;

DO $price2$
DECLARE
  price numeric;
  job_status text;
BEGIN
  SELECT j.client_price, j.status INTO price, job_status
  FROM public.jobs j
  WHERE j.id = '11111111-1111-4111-8111-111111111111';
  IF price <> 125 OR job_status <> 'In Progress' THEN
    RAISE EXCEPTION 'after rpc price=% status=%', price, job_status;
  END IF;
END
$price2$;

-- Trigger still blocks a price write if a sub update policy is added later.
BEGIN;
-- UPDATE cannot see a row that SELECT policies hide, so this temporary
-- policy opens the row. It is rolled back. The real policies do not.
CREATE POLICY jobs_sub_temp_update
  ON public.jobs
  FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);
SELECT set_config('request.jwt.claim.sub', 'aaaa2222-2222-4222-8222-222222222222', true);
SET LOCAL ROLE authenticated;
UPDATE public.jobs
SET client_price = 999,
    sub_pay = 1,
    payment_status = 'Paid',
    status = 'Completed',
    title = 'hacked'
WHERE id = '11111111-1111-4111-8111-111111111111';
UPDATE public.jobs
SET status = 'Completed',
    subcontractor_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
WHERE id = '22222222-2222-4222-8222-222222222222';
RESET ROLE;
DO $trig$
DECLARE
  price numeric;
  pay numeric;
  paid text;
  job_status text;
  job_title text;
  other_status text;
  other_sub uuid;
BEGIN
  SELECT j.client_price, j.sub_pay, j.payment_status, j.status, j.title
    INTO price, pay, paid, job_status, job_title
  FROM public.jobs j
  WHERE j.id = '11111111-1111-4111-8111-111111111111';
  IF price <> 125 OR pay <> 40 OR paid <> 'Unpaid' OR job_title <> 'Own visit' THEN
    RAISE EXCEPTION 'trigger let office fields change: % % % %', price, pay, paid, job_title;
  END IF;
  IF job_status <> 'Completed' THEN
    RAISE EXCEPTION 'allowed status change did not stick: %', job_status;
  END IF;
  SELECT j.status, j.subcontractor_id INTO other_status, other_sub
  FROM public.jobs j
  WHERE j.id = '22222222-2222-4222-8222-222222222222';
  IF other_status <> 'Pending' OR other_sub::text <> 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' THEN
    RAISE EXCEPTION 'other job changed: % %', other_status, other_sub;
  END IF;
END
$trig$;
ROLLBACK;

-- Anon cannot read the office tables or the sub view.
SET ROLE anon;
DO $anon$
DECLARE
  n int;
BEGIN
  BEGIN
    SELECT count(*) INTO n FROM public.jobs;
    IF n <> 0 THEN
      RAISE EXCEPTION 'anon read % jobs', n;
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    SELECT count(*) INTO n FROM public.sub_jobs;
    IF n <> 0 THEN
      RAISE EXCEPTION 'anon read % sub_jobs', n;
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    SELECT count(*) INTO n FROM public.invoice_items;
    IF n <> 0 THEN
      RAISE EXCEPTION 'anon read % invoice items', n;
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$anon$;
RESET ROLE;

-- Invite link fills a free subcontractor id and refuses a bad or taken id.
INSERT INTO public.profiles (id, email, role)
VALUES ('aaaa4444-4444-4444-8444-444444444444', 'new@example.com', NULL);

INSERT INTO public.profiles (id, email, role)
VALUES ('aaaa5555-5555-4555-8555-555555555555', 'bad@example.com', NULL);

INSERT INTO public.profiles (id, email, role)
VALUES ('aaaa6666-6666-4666-8666-666666666666', 'taken@example.com', NULL);

DO $invite$
DECLARE
  linked uuid;
  got_role text;
  bad uuid;
  taken uuid;
BEGIN
  SELECT p.subcontractor_id, p.role INTO linked, got_role
  FROM public.profiles p
  WHERE p.id = 'aaaa4444-4444-4444-8444-444444444444';
  IF linked::text <> 'cccccccc-cccc-cccc-cccc-cccccccccccc' OR got_role <> 'sub' THEN
    RAISE EXCEPTION 'invite did not link: % %', linked, got_role;
  END IF;

  SELECT subcontractor_id INTO bad
  FROM public.profiles
  WHERE id = 'aaaa5555-5555-4555-8555-555555555555';
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'bad invite uuid linked %', bad;
  END IF;

  SELECT subcontractor_id INTO taken
  FROM public.profiles
  WHERE id = 'aaaa6666-6666-4666-8666-666666666666';
  IF taken IS NOT NULL THEN
    RAISE EXCEPTION 'taken subcontractor was linked again: %', taken;
  END IF;
END
$invite$;

-- A sub cannot point their own profile at another subcontractor, even if a
-- later policy lets them update the row. The privilege trigger puts it back.
BEGIN;
CREATE POLICY profiles_temp_update
  ON public.profiles
  FOR UPDATE
  TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());
SELECT set_config('request.jwt.claim.sub', 'aaaa2222-2222-4222-8222-222222222222', true);
SET LOCAL ROLE authenticated;
UPDATE public.profiles
SET role = 'admin',
    subcontractor_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
WHERE id = 'aaaa2222-2222-4222-8222-222222222222';
RESET ROLE;
DO $profile_mid$
DECLARE
  got_role text;
  got_sub uuid;
BEGIN
  SELECT p.role, p.subcontractor_id INTO got_role, got_sub
  FROM public.profiles p
  WHERE p.id = 'aaaa2222-2222-4222-8222-222222222222';
  IF got_role <> 'sub' OR got_sub::text <> 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' THEN
    RAISE EXCEPTION 'profile privilege moved: % %', got_role, got_sub;
  END IF;
END
$profile_mid$;
ROLLBACK;

-- A forged subcontractor id on signup is ignored. Only the invite metadata counts.
SELECT set_config('request.jwt.claim.sub', 'aaaa7777-7777-4777-8777-777777777777', false);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"aaaa7777-7777-4777-8777-777777777777","role":"authenticated"}',
  false
);
SET ROLE authenticated;
INSERT INTO public.profiles (id, email, role, subcontractor_id)
VALUES (
  'aaaa7777-7777-4777-8777-777777777777',
  'forged@example.com',
  'sub',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
);
RESET ROLE;
DO $forged$
DECLARE
  got_role text;
  got_sub uuid;
BEGIN
  SELECT p.role, p.subcontractor_id INTO got_role, got_sub
  FROM public.profiles p
  WHERE p.id = 'aaaa7777-7777-4777-8777-777777777777';
  IF got_role <> 'sub' OR got_sub IS NOT NULL THEN
    RAISE EXCEPTION 'forged signup stuck: % %', got_role, got_sub;
  END IF;
END
$forged$;

DO $bucket$
DECLARE
  is_public boolean;
BEGIN
  SELECT public INTO is_public FROM storage.buckets WHERE id = 'job-photos';
  IF is_public IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'job-photos bucket is still public';
  END IF;
END
$bucket$;

SELECT 'SUB_ACCESS_OK' AS result;
